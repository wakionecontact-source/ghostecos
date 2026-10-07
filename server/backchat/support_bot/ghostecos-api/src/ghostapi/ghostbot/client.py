"""Synchronous WebSocket client for GhostChat's bot event/action API."""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Mapping
from urllib.parse import urlsplit, urlunsplit
from uuid import uuid4

from websockets.exceptions import (
    ConnectionClosed,
    InvalidHandshake,
)
from websockets.sync.client import ClientConnection, connect

from .crypto import BotTestCrypto, BotTestCryptoError
from .errors import BotAPIError, BotNetworkError, BotProtocolError, GhostBotError
from .markup import InlineKeyboard, ReplyKeyboard
from .storage import BotStorage


DEFAULT_BASE_URL = "https://ghostecos.duckdns.org"
Handler = Callable[["BotEvent"], object]


@dataclass(frozen=True, slots=True)
class BotEvent:
    """One event received from GhostChat."""

    name: str
    data: Mapping[str, Any]
    event_id: str | int | None = None


def _websocket_url(base_url: str, ws_path: str | None) -> str:
    parsed = urlsplit(base_url.strip())
    schemes = {"http": "ws", "https": "wss", "ws": "ws", "wss": "wss"}
    scheme = schemes.get(parsed.scheme.lower())
    if scheme is None or not parsed.netloc:
        raise ValueError("base_url must be an absolute http(s) or ws(s) URL")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("base_url must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("base_url must not contain a query or fragment")

    if ws_path is not None:
        if not ws_path.startswith("/") or ws_path.startswith("//"):
            raise ValueError("ws_path must be an absolute path on the base host")
        path = ws_path
    else:
        path = parsed.path.rstrip("/")
        if path.endswith("/api/bots/ws"):
            pass
        elif path.endswith("/api/bots"):
            path += "/ws"
        else:
            path += "/api/bots/ws"

    return urlunsplit((scheme, parsed.netloc, path, "", ""))


def _object_from_frame(raw: str | bytes) -> Mapping[str, Any]:
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise BotProtocolError("GhostChat sent a non-UTF-8 frame") from exc

    try:
        frame = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BotProtocolError("GhostChat sent invalid JSON") from exc
    if not isinstance(frame, Mapping):
        raise BotProtocolError("GhostChat event frame must be a JSON object")
    return frame


def _event_from_frame(raw: str | bytes) -> BotEvent:
    frame = _object_from_frame(raw)
    if frame.get("type") != "event":
        raise BotProtocolError("Expected an event frame from GhostChat")

    name = frame.get("event")
    data = frame.get("data", {})
    event_id = frame.get("event_id")
    if not isinstance(name, str) or not name.strip():
        raise BotProtocolError("GhostChat event is missing its event name")
    if not isinstance(data, Mapping):
        raise BotProtocolError("GhostChat event data must be a JSON object")
    if event_id is not None and not isinstance(event_id, (str, int)):
        raise BotProtocolError("GhostChat event_id must be a string or integer")

    return BotEvent(name=name.strip(), data=data, event_id=event_id)


def _handshake_error(exc: InvalidHandshake) -> BotAPIError:
    response = getattr(exc, "response", None)
    status = getattr(response, "status_code", getattr(exc, "status_code", None))
    body = getattr(response, "body", b"")
    if isinstance(body, bytes):
        body = body.decode("utf-8", errors="replace")
    message = str(body).strip() or "WebSocket connection was rejected"
    return BotAPIError(status if isinstance(status, int) else None, message)


class Bot:
    """Connect to GhostChat over WebSocket and exchange events and actions.

    The bot token is sent directly in the WebSocket handshake as
    ``Authorization: Bot <token>``. No JWT or polling loop is used.
    """

    def __init__(
        self,
        token: str,
        *,
        base_url: str = DEFAULT_BASE_URL,
        ws_path: str | None = None,
        connect_timeout: float = 10.0,
        heartbeat_interval: float = 20.0,
        heartbeat_timeout: float = 40.0,
        max_frame_size: int = 1_048_576,
    ) -> None:
        token = token.strip()
        if not token:
            raise ValueError("Bot token must not be empty")
        if connect_timeout <= 0:
            raise ValueError("connect_timeout must be greater than zero")
        if heartbeat_interval <= 0:
            raise ValueError("heartbeat_interval must be greater than zero")
        if heartbeat_timeout <= 0:
            raise ValueError("heartbeat_timeout must be greater than zero")
        if max_frame_size <= 0:
            raise ValueError("max_frame_size must be greater than zero")

        self.websocket_url = _websocket_url(base_url, ws_path)
        self._token = token
        self.storage: BotStorage = BotStorage(
            base_url, token, timeout=connect_timeout
        )
        self._connect_timeout = connect_timeout
        self._heartbeat_interval = heartbeat_interval
        self._heartbeat_timeout = heartbeat_timeout
        self._max_frame_size = max_frame_size
        self._handlers: dict[str, list[Handler]] = {}
        self._test_crypto = BotTestCrypto()
        self._event_context = threading.local()
        self._connection: ClientConnection | None = None
        self._connection_lock = threading.Lock()
        self._run_lock = threading.Lock()
        self._stop_event = threading.Event()

    @property
    def test_chat_fingerprint(self) -> str:
        """Fingerprint to compare with the GhostBots test window."""

        return self._test_crypto.public_key_fingerprint

    def on(self, name: str, handler: Handler | None = None):
        """Register a callback for an event name; ``*`` receives all events."""

        normalized = name.strip()
        if not normalized:
            raise ValueError("event name must not be empty")

        def register(callback: Handler) -> Handler:
            if not callable(callback):
                raise TypeError("event handler must be callable")
            self._handlers.setdefault(normalized, []).append(callback)
            return callback

        return register if handler is None else register(handler)

    def on_status(self, handler: Handler | None = None):
        """Register a callback for the ``bot.status`` event."""

        return self.on("bot.status", handler)

    def _dispatch(self, event: BotEvent) -> None:
        handlers = [
            *self._handlers.get(event.name, ()),
            *self._handlers.get("*", ()),
        ]
        for handler in handlers:
            handler(event)

    def _prepare_event(self, event: BotEvent) -> BotEvent:
        data = dict(event.data)
        if event.name == "test.session.open":
            session_id = data.get("test_session_id")
            client_public_key = data.get("client_public_key")
            if not isinstance(session_id, str) or not isinstance(
                client_public_key, str
            ):
                raise BotProtocolError("Test-chat session is missing key material")
            try:
                self._test_crypto.open_session(session_id, client_public_key)
            except BotTestCryptoError as exc:
                raise BotProtocolError("Could not open encrypted test chat") from exc
        elif event.name == "test.session.close":
            session_id = data.get("test_session_id")
            if isinstance(session_id, str):
                self._test_crypto.close_session(session_id)
        elif event.name == "message.received" and "test_session_id" in data:
            session_id = data.get("test_session_id")
            if not isinstance(session_id, str):
                raise BotProtocolError("Test message is missing its session ID")
            try:
                data["text"] = self._test_crypto.decrypt(
                    session_id,
                    data.get("encrypted_text"),
                )
            except BotTestCryptoError as exc:
                raise BotProtocolError("Could not decrypt bot test message") from exc
            data.pop("encrypted_text", None)
        return BotEvent(name=event.name, data=data, event_id=event.event_id)

    def _dispatch_with_context(self, event: BotEvent) -> None:
        session_id = event.data.get("test_session_id")
        sender = event.data.get("from_username")
        previous_session = getattr(self._event_context, "test_session_id", None)
        previous_sender = getattr(self._event_context, "test_sender", None)
        if isinstance(session_id, str) and isinstance(sender, str):
            self._event_context.test_session_id = session_id
            self._event_context.test_sender = sender
        try:
            self._dispatch(event)
        finally:
            if previous_session is None:
                self._event_context.__dict__.pop("test_session_id", None)
            else:
                self._event_context.test_session_id = previous_session
            if previous_sender is None:
                self._event_context.__dict__.pop("test_sender", None)
            else:
                self._event_context.test_sender = previous_sender

    def _send_frame(
        self,
        connection: ClientConnection,
        frame: Mapping[str, Any],
    ) -> None:
        encoded = json.dumps(frame, ensure_ascii=False, separators=(",", ":"))
        with self._connection_lock:
            if self._connection is not connection:
                raise BotNetworkError("Bot WebSocket is no longer connected")
            try:
                connection.send(encoded)
            except (ConnectionClosed, OSError) as exc:
                raise BotNetworkError("Could not send data to GhostChat") from exc

    def _handle_frame(
        self,
        connection: ClientConnection,
        raw: str | bytes,
        pending_pings: dict[str, float],
    ) -> BotEvent | None:
        frame = _object_from_frame(raw)
        frame_type = frame.get("type")
        if frame_type == "ping":
            ping_id = frame.get("ping_id")
            if not isinstance(ping_id, str) or not ping_id:
                raise BotProtocolError("GhostChat ping is missing ping_id")
            self._send_frame(
                connection,
                {"type": "pong", "ping_id": ping_id},
            )
            return None
        if frame_type == "pong":
            ping_id = frame.get("ping_id")
            if not isinstance(ping_id, str) or not ping_id:
                raise BotProtocolError("GhostChat pong is missing ping_id")
            pending_pings.pop(ping_id, None)
            return None
        return _event_from_frame(raw)

    def send_action(
        self,
        name: str,
        data: Mapping[str, Any] | None = None,
        **payload: Any,
    ) -> str:
        """Send a named action and return its local correlation ID."""

        if not isinstance(name, str):
            raise TypeError("action name must be a string")
        if data is not None and not isinstance(data, Mapping):
            raise TypeError("action data must be a mapping")
        action = name.strip()
        if not action:
            raise ValueError("action name must not be empty")
        body = dict(data or {})
        body.update(payload)
        action_id = uuid4().hex
        frame = {
            "type": "action",
            "action_id": action_id,
            "action": action,
            "data": body,
        }
        with self._connection_lock:
            connection = self._connection
            if connection is None:
                raise GhostBotError("Bot is not connected; call run() first")
        self._send_frame(connection, frame)
        return action_id

    def go_offline(self) -> str:
        """Manually mark the bot offline and stop this WebSocket session.

        Online status is server-derived from a live connection and healthy
        heartbeats; the client can't force itself online with an action.
        """

        action_id = self.send_action("bot.status.set", status="offline")
        self.stop()
        return action_id

    def send_message(
        self,
        to_username: str | None = None,
        text: str | None = None,
        *,
        user_id: int | None = None,
        reply_markup: InlineKeyboard | ReplyKeyboard | None = None,
    ) -> str:
        """Send a message to exactly one username or numeric GhostChat user ID.

        Reply-keyboard taps are delivered to the bot as ordinary
        ``message.received`` events containing the button's ``send_text``.
        Inline-keyboard taps arrive as ``button.callback`` events.
        """

        if (to_username is None) == (user_id is None):
            raise ValueError("provide exactly one of to_username or user_id")
        if to_username is not None and not isinstance(to_username, str):
            raise TypeError("to_username must be a string")
        if user_id is not None and (type(user_id) is not int or user_id <= 0):
            raise ValueError("user_id must be a positive integer")
        if not isinstance(text, str):
            raise TypeError("text must be a string")
        if to_username is not None:
            to_username = to_username.strip().lstrip("@")
        if to_username == "":
            raise ValueError("to_username must not be empty")
        if not text.strip() or len(text) > 4000:
            raise ValueError("text must contain between 1 and 4000 characters")
        markup_data: dict[str, object] | None = None
        if reply_markup is not None:
            if not isinstance(reply_markup, (InlineKeyboard, ReplyKeyboard)):
                raise TypeError("reply_markup must be an InlineKeyboard or ReplyKeyboard")
            markup_data = reply_markup.to_dict()
            if len(json.dumps(markup_data, ensure_ascii=False).encode("utf-8")) > 16_384:
                raise ValueError("reply_markup must not exceed 16384 UTF-8 bytes")
        test_session_id = getattr(self._event_context, "test_session_id", None)
        test_sender = getattr(self._event_context, "test_sender", None)
        if test_session_id and user_id is not None:
            raise GhostBotError(
                "Use the test-chat username target for encrypted owner test-chat replies"
            )
        if test_session_id and to_username == test_sender:
            if markup_data is not None:
                raise GhostBotError(
                    "Keyboards are not supported in encrypted owner test chats yet"
                )
            try:
                encrypted_text = self._test_crypto.encrypt(test_session_id, text)
            except BotTestCryptoError as exc:
                raise GhostBotError("Could not encrypt bot test reply") from exc
            return self.send_action(
                "message.send",
                test_session_id=test_session_id,
                encrypted_text=encrypted_text,
            )
        data: dict[str, object] = {"text": text}
        if user_id is not None:
            data["to_user_id"] = user_id
        else:
            data["to_username"] = to_username
        if markup_data is not None:
            data["reply_markup"] = markup_data
        return self.send_action("message.send", data)

    def stop(self) -> None:
        """Ask a running ``run()`` loop to disconnect and return."""

        self._stop_event.set()

    def _connect(self) -> ClientConnection:
        return connect(
            self.websocket_url,
            additional_headers={"Authorization": f"Bot {self._token}"},
            open_timeout=self._connect_timeout,
            # Presence uses JSON ping/pong in run(), tied to the bot loop;
            # transport-level keepalive isn't used as a presence signal.
            ping_interval=None,
            ping_timeout=None,
            max_size=self._max_frame_size,
            compression=None,
        )

    def _stopped(self, external_stop: threading.Event | None) -> bool:
        return self._stop_event.is_set() or bool(
            external_stop is not None and external_stop.is_set()
        )

    def _wait_before_reconnect(
        self,
        delay: float,
        external_stop: threading.Event | None,
    ) -> bool:
        deadline = time.monotonic() + delay
        while not self._stopped(external_stop):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return True
            self._stop_event.wait(min(remaining, 0.1))
        return False

    def run(
        self,
        *,
        reconnect: bool = True,
        reconnect_delay: float = 1.0,
        stop_event: threading.Event | None = None,
    ) -> None:
        """Connect, dispatch events, and reconnect after network failures."""

        if reconnect_delay <= 0:
            raise ValueError("reconnect_delay must be greater than zero")
        if not self._run_lock.acquire(blocking=False):
            raise GhostBotError("run() is already active for this Bot")

        self._stop_event.clear()
        delay = reconnect_delay
        try:
            while not self._stopped(stop_event):
                connected_at: float | None = None
                try:
                    with self._connect() as connection:
                        with self._connection_lock:
                            self._connection = connection
                        self._send_frame(
                            connection,
                            {
                                "type": "hello",
                                "key_exchange": "x25519",
                                "version": 1,
                                "public_key": self._test_crypto.public_key,
                            },
                        )
                        connected_at = time.monotonic()
                        self._dispatch(BotEvent("connection.open", {}))
                        pending_pings: dict[str, float] = {}
                        next_ping_at = time.monotonic()

                        while not self._stopped(stop_event):
                            now = time.monotonic()
                            if any(
                                now - sent_at >= self._heartbeat_timeout
                                for sent_at in pending_pings.values()
                            ):
                                raise BotNetworkError(
                                    "GhostChat didn't answer the bot heartbeat"
                                )
                            if now >= next_ping_at:
                                ping_id = uuid4().hex
                                pending_pings[ping_id] = now
                                self._send_frame(
                                    connection,
                                    {"type": "ping", "ping_id": ping_id},
                                )
                                next_ping_at = now + self._heartbeat_interval

                            wait_for = min(0.5, max(0.01, next_ping_at - time.monotonic()))
                            if pending_pings:
                                nearest_deadline = min(
                                    sent_at + self._heartbeat_timeout
                                    for sent_at in pending_pings.values()
                                )
                                wait_for = min(
                                    wait_for,
                                    max(0.01, nearest_deadline - time.monotonic()),
                                )
                            try:
                                raw = connection.recv(timeout=wait_for)
                            except TimeoutError:
                                continue
                            event = self._handle_frame(connection, raw, pending_pings)
                            if event is not None:
                                self._dispatch_with_context(self._prepare_event(event))
                except InvalidHandshake as exc:
                    if getattr(exc, "response", None) is not None or getattr(
                        exc, "status_code", None
                    ) is not None:
                        raise _handshake_error(exc) from exc
                    raise BotProtocolError(
                        "GhostChat rejected the WebSocket handshake"
                    ) from exc
                except (BotNetworkError, ConnectionClosed, OSError, TimeoutError) as exc:
                    if self._stopped(stop_event):
                        break
                    if not reconnect:
                        if isinstance(exc, BotNetworkError):
                            raise
                        raise BotNetworkError("Connection to GhostChat was lost") from exc
                    if (
                        connected_at is not None
                        and time.monotonic() - connected_at >= 30.0
                    ):
                        delay = reconnect_delay
                    if not self._wait_before_reconnect(delay, stop_event):
                        break
                    delay = min(delay * 2, 30.0)
                finally:
                    with self._connection_lock:
                        self._connection = None
        finally:
            self._stop_event.set()
            self._run_lock.release()


__all__ = [
    "DEFAULT_BASE_URL",
    "Bot",
    "BotAPIError",
    "BotEvent",
    "BotNetworkError",
    "BotProtocolError",
    "GhostBotError",
]
