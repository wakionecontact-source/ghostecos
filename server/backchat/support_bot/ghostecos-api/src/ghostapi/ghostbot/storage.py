"""Small, server-backed JSON key/value storage for GhostChat bots."""

from __future__ import annotations

import json
import socket
from collections.abc import Mapping
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .errors import BotAPIError, BotNetworkError, BotProtocolError


MAX_STORAGE_KEY_CHARS = 128
MAX_STORAGE_VALUE_BYTES = 65_536
_MAX_RESPONSE_BYTES = MAX_STORAGE_VALUE_BYTES + 4_096
_MISSING = object()


def _http_api_base(base_url: str) -> str:
    parsed = urlsplit(base_url.strip())
    scheme = {"http": "http", "https": "https", "ws": "http", "wss": "https"}.get(
        parsed.scheme.lower()
    )
    if scheme is None or not parsed.netloc:
        raise ValueError("base_url must be an absolute http(s) or ws(s) URL")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("base_url must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("base_url must not contain a query or fragment")

    path = parsed.path.rstrip("/")
    if path.endswith("/api/bots/ws"):
        path = path[:-3]
    elif not path.endswith("/api/bots"):
        path += "/api/bots"
    return urlunsplit((scheme, parsed.netloc, path, "", ""))


def _validate_key(key: str) -> str:
    if not isinstance(key, str):
        raise TypeError("storage key must be a string")
    if (
        not key
        or len(key) > MAX_STORAGE_KEY_CHARS
        or not key[0].isalnum()
        or any(not (char.isascii() and (char.isalnum() or char in "_.:-")) for char in key)
    ):
        raise ValueError(
            "storage key must be 1-128 ASCII letters, digits, dots, underscores, colons, or hyphens"
        )
    return key


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a bot bearer token to a redirect target.
        return None


class BotStorage:
    """Per-bot persistent JSON key/value storage.

    Values are stored on the GhostChat server and are not end-to-end encrypted.
    Do not use this store for passwords, API credentials, or other secrets.
    """

    __slots__ = ("_api_base", "_token", "_timeout")

    def __init__(self, base_url: str, token: str, *, timeout: float = 10.0) -> None:
        self._api_base = _http_api_base(base_url)
        self._token = token
        self._timeout = timeout

    def _request(self, method: str, key: str, payload: Any = _MISSING) -> Mapping[str, Any]:
        clean_key = _validate_key(key)
        parsed = urlsplit(self._api_base)
        hostname = (parsed.hostname or "").lower()
        if parsed.scheme != "https" and hostname not in {
            "localhost",
            "127.0.0.1",
            "::1",
        }:
            raise BotNetworkError(
                "Bot storage refuses to send the bot token over non-TLS HTTP"
            )

        body = None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bot {self._token}",
        }
        if payload is not _MISSING:
            try:
                body = json.dumps(
                    payload,
                    ensure_ascii=False,
                    allow_nan=False,
                    separators=(",", ":"),
                ).encode("utf-8")
            except (TypeError, ValueError, RecursionError) as exc:
                raise ValueError("storage values must be valid JSON values") from exc
            if len(body) > MAX_STORAGE_VALUE_BYTES:
                raise ValueError(
                    f"storage value must not exceed {MAX_STORAGE_VALUE_BYTES} UTF-8 bytes"
                )
            headers["Content-Type"] = "application/json"

        request = Request(
            f"{self._api_base}/storage/{quote(clean_key, safe='')}",
            data=body,
            headers=headers,
            method=method,
        )
        opener = build_opener(_NoRedirectHandler())
        try:
            with opener.open(request, timeout=self._timeout) as response:
                raw = response.read(_MAX_RESPONSE_BYTES + 1)
        except HTTPError as exc:
            try:
                error_body = exc.read(4_096)
            finally:
                exc.close()
            message = "Bot storage request was rejected"
            try:
                parsed_error = json.loads(error_body.decode("utf-8"))
                detail = parsed_error.get("detail") if isinstance(parsed_error, dict) else None
                if isinstance(detail, str) and detail.strip():
                    message = detail.strip()[:500]
            except (UnicodeDecodeError, json.JSONDecodeError):
                pass
            raise BotAPIError(exc.code, message) from None
        except (URLError, TimeoutError, socket.timeout, OSError) as exc:
            raise BotNetworkError("Bot storage request failed") from exc

        if len(raw) > _MAX_RESPONSE_BYTES:
            raise BotProtocolError("Bot storage response is too large")
        try:
            response_data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BotProtocolError("Bot storage returned invalid JSON") from exc
        if not isinstance(response_data, Mapping):
            raise BotProtocolError("Bot storage response must be a JSON object")
        return response_data

    def get(self, key: str, default: Any = None) -> Any:
        """Return a stored JSON value, or ``default`` when the key is absent."""

        result = self._request("GET", key)
        exists = result.get("exists")
        if not isinstance(exists, bool):
            raise BotProtocolError("Bot storage response is missing its exists flag")
        if not exists:
            return default
        if "value" not in result:
            raise BotProtocolError("Bot storage response is missing its value")
        return result["value"]

    def set(self, key: str, value: Any) -> None:
        """Persist a JSON-compatible value under this bot's namespace."""

        result = self._request("PUT", key, value)
        if result.get("status") != "ok":
            raise BotProtocolError("Bot storage did not confirm the write")

    def delete(self, key: str) -> bool:
        """Delete a key and report whether it existed."""

        result = self._request("DELETE", key)
        deleted = result.get("deleted")
        if not isinstance(deleted, bool):
            raise BotProtocolError("Bot storage response is missing its deleted flag")
        return deleted
