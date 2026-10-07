package main

import (
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type soundWSClient struct {
	conn    net.Conn
	send    chan []byte
	done    chan struct{}
	closeOnce sync.Once
	writeMu sync.Mutex
}

var soundWSHub = struct {
	mu      sync.Mutex
	clients map[*soundWSClient]struct{}
}{clients: make(map[*soundWSClient]struct{})}

func soundWS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || !headerHasToken(r.Header.Get("Connection"), "upgrade") || !strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "websocket") {
		http.Error(w, "websocket upgrade required", http.StatusUpgradeRequired)
		return
	}
	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	if key == "" || len(key) > 128 {
		http.Error(w, "bad websocket key", http.StatusBadRequest)
		return
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "websocket unavailable", http.StatusNotImplemented)
		return
	}
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return
	}
	hash := sha1.Sum([]byte(key + websocketGUID))
	accept := base64.StdEncoding.EncodeToString(hash[:])
	if _, err = fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept); err != nil {
		conn.Close()
		return
	}
	if err = rw.Flush(); err != nil {
		conn.Close()
		return
	}

	client := &soundWSClient{conn: conn, send: make(chan []byte, 8), done: make(chan struct{})}
	soundWSHub.mu.Lock()
	soundWSHub.clients[client] = struct{}{}
	soundWSHub.mu.Unlock()
	defer removeSoundWSClient(client)

	go soundWSWriter(client)
	client.enqueue(map[string]interface{}{"type": "catalog.ready", "at": time.Now().UTC()})
	soundWSReader(client)
}

func headerHasToken(value, token string) bool {
	for _, part := range strings.Split(value, ",") {
		if strings.EqualFold(strings.TrimSpace(part), token) {
			return true
		}
	}
	return false
}

func (c *soundWSClient) enqueue(value interface{}) {
	payload, err := json.Marshal(value)
	if err != nil {
		return
	}
	c.enqueuePayload(payload)
}

func (c *soundWSClient) enqueuePayload(payload []byte) {
	select {
	case <-c.done:
	case c.send <- payload:
	default:
		removeSoundWSClient(c)
	}
}

func (c *soundWSClient) writeFrame(opcode byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	var header [10]byte
	header[0] = 0x80 | (opcode & 0x0f)
	length := len(payload)
	headerLen := 2
	switch {
	case length < 126:
		header[1] = byte(length)
	case length <= 65535:
		header[1] = 126
		binary.BigEndian.PutUint16(header[2:4], uint16(length))
		headerLen = 4
	default:
		header[1] = 127
		binary.BigEndian.PutUint64(header[2:10], uint64(length))
		headerLen = 10
	}
	if _, err := c.conn.Write(header[:headerLen]); err != nil {
		return err
	}
	_, err := c.conn.Write(payload)
	return err
}

func soundWSWriter(c *soundWSClient) {
	for {
		select {
		case <-c.done:
			return
		case payload := <-c.send:
			if err := c.writeFrame(0x1, payload); err != nil {
				removeSoundWSClient(c)
				return
			}
		}
	}
}

func soundWSReader(c *soundWSClient) {
	for {
		opcode, payload, err := readWSFrame(c.conn)
		if err != nil {
			return
		}
		switch opcode {
		case 0x8:
			_ = c.writeFrame(0x8, nil)
			return
		case 0x9:
			if err := c.writeFrame(0xa, payload); err != nil {
				return
			}
		}
	}
}

func readWSFrame(conn net.Conn) (byte, []byte, error) {
	var head [2]byte
	if _, err := io.ReadFull(conn, head[:]); err != nil {
		return 0, nil, err
	}
	opcode := head[0] & 0x0f
	masked := head[1]&0x80 != 0
	length := uint64(head[1] & 0x7f)
	if length == 126 {
		var short [2]byte
		if _, err := io.ReadFull(conn, short[:]); err != nil {
			return 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(short[:]))
	} else if length == 127 {
		var long [8]byte
		if _, err := io.ReadFull(conn, long[:]); err != nil {
			return 0, nil, err
		}
		length = binary.BigEndian.Uint64(long[:])
	}
	if length > 1<<20 {
		return 0, nil, fmt.Errorf("websocket frame too large")
	}
	if !masked {
		return 0, nil, fmt.Errorf("client frame is not masked")
	}
	var mask [4]byte
	if _, err := io.ReadFull(conn, mask[:]); err != nil {
		return 0, nil, err
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(conn, payload); err != nil {
		return 0, nil, err
	}
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	return opcode, payload, nil
}

func removeSoundWSClient(c *soundWSClient) {
	soundWSHub.mu.Lock()
	delete(soundWSHub.clients, c)
	soundWSHub.mu.Unlock()
	c.closeOnce.Do(func() { close(c.done); _ = c.conn.Close() })
}

func broadcastSoundEvent(value interface{}) {
	payload, err := json.Marshal(value)
	if err != nil {
		return
	}
	soundWSHub.mu.Lock()
	clients := make([]*soundWSClient, 0, len(soundWSHub.clients))
	for client := range soundWSHub.clients {
		clients = append(clients, client)
	}
	soundWSHub.mu.Unlock()
	for _, client := range clients {
		client.enqueuePayload(payload)
	}
}
