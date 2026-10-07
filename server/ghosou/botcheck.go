package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/goregular"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

const (
	botChallengeTTL  = 5 * time.Minute
	botCapabilityTTL = 15 * time.Minute
	botMaxEntries    = 20000
	botCodeLength    = 5
)

const botCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

type botPendingChallenge struct {
	purpose  string
	digest   string
	expires  time.Time
	attempts int
}

type botCapability struct {
	V   int    `json:"v"`
	Aud string `json:"aud"`
	JTI string `json:"jti"`
	IAT int64  `json:"iat"`
	Exp int64  `json:"exp"`
}

var botState = struct {
	sync.Mutex
	pending map[string]botPendingChallenge
	used    map[string]time.Time
	rate    map[string][]time.Time
}{
	pending: make(map[string]botPendingChallenge),
	used:    make(map[string]time.Time),
	rate:    make(map[string][]time.Time),
}

func ghosouBotRequired() bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("GHOSOU_BOT_CHECK_REQUIRED")))
	return v != "0" && v != "false" && v != "no" && v != "off"
}

func ghosouBotSecret(name string) (string, bool) {
	v := strings.TrimSpace(os.Getenv(name))
	return v, len(v) >= 32
}

func botRandomID() string {
	var raw [18]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return hex.EncodeToString([]byte(time.Now().String()))
	}
	return base64.RawURLEncoding.EncodeToString(raw[:])
}

func botRandomCode() string {
	var raw [botCodeLength]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "A2B3C"
	}
	for i := range raw {
		raw[i] = botCodeAlphabet[int(raw[i])%len(botCodeAlphabet)]
	}
	return string(raw[:])
}

func botCleanupLocked(now time.Time) {
	for id, item := range botState.pending {
		if !item.expires.After(now) {
			delete(botState.pending, id)
		}
	}
	for id, expires := range botState.used {
		if !expires.After(now) {
			delete(botState.used, id)
		}
	}
	for key, hits := range botState.rate {
		kept := hits[:0]
		for _, at := range hits {
			if now.Sub(at) < 10*time.Minute {
				kept = append(kept, at)
			}
		}
		if len(kept) == 0 {
			delete(botState.rate, key)
		} else {
			botState.rate[key] = kept
		}
	}
}

func botRateOK(r *http.Request, action string) bool {
	key := "bot:" + action + ":" + requestIP(r)
	now := time.Now()
	botState.Lock()
	defer botState.Unlock()
	botCleanupLocked(now)
	hits := botState.rate[key]
	if len(hits) >= 30 {
		return false
	}
	botState.rate[key] = append(hits, now)
	for len(botState.pending) > botMaxEntries {
		for id := range botState.pending {
			delete(botState.pending, id)
			break
		}
	}
	return true
}

func botCodeDigest(id, solution, secret string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(id + ":" + strings.ToUpper(strings.TrimSpace(solution))))
	return hex.EncodeToString(mac.Sum(nil))
}

func botRandInt(max int) int {
	if max <= 1 {
		return 0
	}
	var raw [4]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return 0
	}
	value := uint32(raw[0])<<24 | uint32(raw[1])<<16 | uint32(raw[2])<<8 | uint32(raw[3])
	return int(value % uint32(max))
}

func botLine(img *image.RGBA, x0, y0, x1, y1, width int, c color.Color) {
	dx, sx := x1-x0, 1
	if dx < 0 {
		dx, sx = -dx, -1
	}
	dy, sy := -absInt(y1-y0), 1
	if y0 > y1 {
		sy = -1
	}
	err := dx + dy
	for {
		for ox := -width / 2; ox <= width/2; ox++ {
			for oy := -width / 2; oy <= width/2; oy++ {
				x, y := x0+ox, y0+oy
				if x >= 0 && y >= 0 && x < img.Bounds().Dx() && y < img.Bounds().Dy() {
					img.Set(x, y, c)
				}
			}
		}
		if x0 == x1 && y0 == y1 {
			return
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x0 += sx
		}
		if e2 <= dx {
			err += dx
			y0 += sy
		}
	}
}

func absInt(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

func renderBotCaptcha(code string) (string, error) {
	faceFont, err := opentype.Parse(goregular.TTF)
	if err != nil {
		return "", err
	}
	face, err := opentype.NewFace(faceFont, &opentype.FaceOptions{
		Size:    38,
		DPI:     72,
		Hinting: font.HintingFull,
	})
	if err != nil {
		return "", err
	}
	defer face.Close()

	const width, height = 300, 100
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	draw.Draw(img, img.Bounds(), image.NewUniform(color.RGBA{R: 245, G: 242, B: 255, A: 255}), image.Point{}, draw.Src)
	for i := 0; i < 9; i++ {
		c := color.RGBA{R: uint8(90 + botRandInt(100)), G: uint8(90 + botRandInt(100)), B: uint8(90 + botRandInt(100)), A: 255}
		botLine(img, botRandInt(width), botRandInt(height), botRandInt(width), botRandInt(height), 1+botRandInt(3), c)
	}
	for i := 0; i < 180; i++ {
		img.Set(botRandInt(width), botRandInt(height), color.RGBA{R: uint8(120 + botRandInt(90)), G: uint8(120 + botRandInt(90)), B: uint8(120 + botRandInt(90)), A: 255})
	}
	drawer := &font.Drawer{Dst: img, Src: image.NewUniform(color.RGBA{R: 35, G: 20, B: 85, A: 255}), Face: face}
	for i, char := range code {
		drawer.Dot = fixed.P(20+i*52, 62+botRandInt(12)-6)
		drawer.DrawString(string(char))
	}
	var buffer strings.Builder
	encoder := base64.NewEncoder(base64.StdEncoding, &stringWriter{builder: &buffer})
	if err := png.Encode(encoder, img); err != nil {
		_ = encoder.Close()
		return "", err
	}
	if err := encoder.Close(); err != nil {
		return "", err
	}
	return "data:image/png;base64," + buffer.String(), nil
}

type stringWriter struct {
	builder *strings.Builder
}

func (w *stringWriter) Write(p []byte) (int, error) {
	return w.builder.Write(p)
}

func botChallengeAPI(w http.ResponseWriter, r *http.Request) {
	setCORS(w, r)
	if r.Method != http.MethodGet {
		http.Error(w, `{"error":"GET only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !botRateOK(r, "challenge") {
		http.Error(w, `{"error":"too many captcha attempts"}`, http.StatusTooManyRequests)
		return
	}
	purpose := strings.TrimSpace(r.URL.Query().Get("purpose"))
	if purpose == "" {
		purpose = "ghogem"
	}
	if purpose != "ghogem" {
		http.Error(w, `{"error":"invalid captcha purpose"}`, http.StatusBadRequest)
		return
	}
	secret, ok := ghosouBotSecret("GHOSOU_BOT_CHECK_SECRET")
	if !ok {
		http.Error(w, `{"error":"captcha is not configured"}`, http.StatusServiceUnavailable)
		return
	}
	id := botRandomID()
	expires := time.Now().Add(botChallengeTTL)
	code := botRandomCode()
	imageData, err := renderBotCaptcha(code)
	if err != nil {
		http.Error(w, `{"error":"captcha image unavailable"}`, http.StatusServiceUnavailable)
		return
	}
	botState.Lock()
	botCleanupLocked(time.Now())
	botState.pending[id] = botPendingChallenge{
		purpose: "ghogem", digest: botCodeDigest(id, code, secret), expires: expires,
	}
	botState.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"challenge_id": id,
		"purpose":      "ghogem",
		"image":        imageData,
		"length":       botCodeLength,
		"expires_at":   expires.Unix(),
	})
}

func botVerifyAPI(w http.ResponseWriter, r *http.Request) {
	setCORS(w, r)
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	if !botRateOK(r, "verify") {
		http.Error(w, `{"error":"too many captcha attempts"}`, http.StatusTooManyRequests)
		return
	}
	var body struct {
		ChallengeID string `json:"challenge_id"`
		Solution    string `json:"solution"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	if json.NewDecoder(r.Body).Decode(&body) != nil || len(body.ChallengeID) < 1 || len(body.ChallengeID) > 128 || len(body.Solution) < 1 || len(body.Solution) > 32 {
		http.Error(w, `{"error":"invalid captcha response"}`, http.StatusBadRequest)
		return
	}
	secret, ok := ghosouBotSecret("GHOSOU_BOT_CHECK_SECRET")
	if !ok {
		http.Error(w, `{"error":"captcha is not configured"}`, http.StatusServiceUnavailable)
		return
	}
	now := time.Now()
	botState.Lock()
	botCleanupLocked(now)
	item, exists := botState.pending[body.ChallengeID]
	if !exists || item.purpose != "ghogem" || !item.expires.After(now) {
		botState.Unlock()
		http.Error(w, `{"error":"captcha expired or already used"}`, http.StatusBadRequest)
		return
	}
	supplied := botCodeDigest(body.ChallengeID, body.Solution, secret)
	if !hmac.Equal([]byte(item.digest), []byte(supplied)) {
		item.attempts++
		if item.attempts >= 5 {
			delete(botState.pending, body.ChallengeID)
		} else {
			botState.pending[body.ChallengeID] = item
		}
		botState.Unlock()
		http.Error(w, `{"error":"invalid captcha code"}`, http.StatusBadRequest)
		return
	}
	delete(botState.pending, body.ChallengeID)
	botState.Unlock()
	token, tokenExpires, ok := makeGhoGemCapability()
	if !ok {
		http.Error(w, `{"error":"bot capability unavailable"}`, http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"bot_token": token, "purpose": "ghogem", "expires_at": tokenExpires})
}

func makeGhoGemCapability() (string, int64, bool) {
	secret, ok := ghosouBotSecret("GHOSOU_BOT_CAP_SECRET")
	if !ok {
		return "", 0, false
	}
	now := time.Now().Unix()
	expires := now + int64(botCapabilityTTL/time.Second)
	payload := botCapability{V: 1, Aud: "ghogem", JTI: botRandomID(), IAT: now, Exp: expires}
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", 0, false
	}
	encoded := base64.RawURLEncoding.EncodeToString(raw)
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(encoded))
	return encoded + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), expires, true
}

func validGhoGemCapability(token string, consume bool) bool {
	if !ghosouBotRequired() {
		return true
	}
	secret, ok := ghosouBotSecret("GHOSOU_BOT_CAP_SECRET")
	if !ok || len(token) > 2048 || strings.Count(token, ".") != 1 {
		return false
	}
	parts := strings.SplitN(token, ".", 2)
	encoded, supplied := parts[0], parts[1]
	sig, err := base64.RawURLEncoding.DecodeString(supplied)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(encoded))
	if !hmac.Equal(mac.Sum(nil), sig) {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return false
	}
	var payload botCapability
	if json.Unmarshal(decoded, &payload) != nil || payload.V != 1 || payload.Aud != "ghogem" || payload.JTI == "" || payload.Exp <= time.Now().Unix() {
		return false
	}
	if !consume {
		return true
	}
	now := time.Now()
	botState.Lock()
	defer botState.Unlock()
	botCleanupLocked(now)
	if _, exists := botState.used[payload.JTI]; exists {
		return false
	}
	botState.used[payload.JTI] = time.Unix(payload.Exp, 0)
	for len(botState.used) > botMaxEntries {
		for id := range botState.used {
			delete(botState.used, id)
			break
		}
	}
	return true
}

func requireGhoGemBot(w http.ResponseWriter, r *http.Request) bool {
	if validGhoGemCapability(strings.TrimSpace(r.Header.Get("X-GhoGem-Bot-Token")), false) {
		return true
	}
	http.Error(w, `{"error":"GhoGem captcha required"}`, http.StatusForbidden)
	return false
}
