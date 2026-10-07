"""Provider HTTP transports for GhoGem.

Each entry below records the API contract used by the application: exact base
URL/path, authentication, provider headers, and any request-field translation.
Only APIs whose official documentation defines an OpenAI Chat Completions
contract use the shared JSON/SSE transport. CVRON and VisionSter have separate
documented request/response adapters.
"""

from __future__ import annotations

import json
import mimetypes
import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

import httpx


@dataclass(frozen=True)
class ProviderSpec:
    provider: str
    base_url: str
    path: str
    auth: str
    docs_url: str
    extra_headers: tuple[tuple[str, str], ...] = ()
    max_tokens_field: str = "max_tokens"
    drop_request_fields: frozenset[str] = frozenset()
    drop_message_fields: frozenset[str] = frozenset()
    strategy: str = "chat_completions"


PROVIDER_SPECS: dict[str, ProviderSpec] = {
    "groq": ProviderSpec(
        "groq", "https://api.groq.com", "/openai/v1/chat/completions", "bearer",
        "https://console.groq.com/docs/openai",
        max_tokens_field="max_completion_tokens",
        drop_request_fields=frozenset({"logprobs", "logit_bias", "top_logprobs", "frequency_penalty", "presence_penalty"}),
        drop_message_fields=frozenset({"name"}),
    ),
    "mistral": ProviderSpec(
        "mistral", "https://api.mistral.ai", "/v1/chat/completions", "bearer",
        "https://docs.mistral.ai/studio/conversations/chat-completion",
    ),
    "openrouter": ProviderSpec(
        "openrouter", "https://openrouter.ai", "/api/v1/chat/completions", "bearer",
        "https://openrouter.ai/docs/api/api-reference/chat/create-a-chat-completion",
        extra_headers=(("HTTP-Referer", "https://ghostecos.duckdns.org"), ("X-Title", "GhostGem")),
    ),
    "sambanova": ProviderSpec(
        "sambanova", "https://api.sambanova.ai", "/v1/chat/completions", "bearer",
        "https://docs.sambanova.ai/docs/api-reference/chat-completions/create-chat-based-completion",
    ),
    "pollinations": ProviderSpec(
        "pollinations", "https://gen.pollinations.ai", "/v1/chat/completions", "bearer_required",
        "https://github.com/pollinations/pollinations/blob/main/gen.pollinations.ai/src/docs/apidocs-recipes.md",
    ),
    "bazaarlink": ProviderSpec(
        "bazaarlink", "https://api.bazaarlink.ai", "/v1/chat/completions", "bearer",
        "https://bazaarlink.ai/en/docs",
    ),
    "zveno": ProviderSpec(
        "zveno", "https://api.zveno.ai", "/v1/chat/completions", "bearer",
        "https://zveno.ai/docs/api-reference/chat-completions",
    ),
    "vireonix": ProviderSpec(
        "vireonix", "https://vireonix.ai", "/v1/chat/completions", "none",
        "https://vireonix.ai/docs",
    ),
    "persorai": ProviderSpec(
        "persorai", "https://persorai.com", "/v1/chat/completions", "bearer_any",
        "https://persorai.com/",
    ),
    "freeai": ProviderSpec(
        "freeai", "https://api.free.ai", "/v1/chat/", "bearer",
        "https://free.ai/api/",
    ),
    "cvron": ProviderSpec(
        "cvron", "https://cvron.alwaysdata.net", "/cvronai/multi-llm.php", "none",
        "https://cvron.alwaysdata.net/",
        strategy="cvron",
    ),
    "visionster": ProviderSpec(
        "visionster", "https://www.ahm7xmakki.com", "/api/imgchat", "none",
        "https://www.ahm7xmakki.com/imgchat",
        strategy="visionster",
    ),
}


class ProviderError(RuntimeError):
    """HTTP/protocol error with a status code compatible with GhoGem handlers."""

    def __init__(self, provider: str, message: str, *, status_code: int | None = None):
        super().__init__(f"{provider} API{f' {status_code}' if status_code else ''}: {message}")
        self.provider = provider
        self.status_code = status_code


class AttrMap(dict):
    """Small OpenAI-response-shaped mapping with attribute access."""

    def __getattr__(self, key: str) -> Any:
        try:
            return self[key]
        except KeyError as exc:
            raise AttributeError(key) from exc

    def model_dump(self, *, exclude_none: bool = False) -> dict[str, Any]:
        return _to_plain(self, exclude_none=exclude_none)


def _to_attr(value: Any) -> Any:
    if isinstance(value, dict):
        return AttrMap({key: _to_attr(item) for key, item in value.items()})
    if isinstance(value, list):
        return [_to_attr(item) for item in value]
    return value


def _to_plain(value: Any, *, exclude_none: bool = False) -> Any:
    if isinstance(value, dict):
        return {
            key: _to_plain(item, exclude_none=exclude_none)
            for key, item in value.items()
            if not (exclude_none and item is None)
        }
    if isinstance(value, list):
        return [_to_plain(item, exclude_none=exclude_none) for item in value]
    return value


def _proxychains_active() -> bool:
    if "proxychains" in os.environ.get("LD_PRELOAD", "").lower():
        return True
    try:
        with open("/proc/self/maps", encoding="utf-8") as maps:
            return "libproxychains" in maps.read().lower()
    except OSError:
        return False


class ProviderEventStream:
    """Async iterator over OpenAI-style SSE JSON data frames."""

    def __init__(self, provider: str, response: httpx.Response):
        self.provider = provider
        self.response = response
        self._closed = False

    def __aiter__(self):
        return self._iterate()

    async def _iterate(self):
        event_data: list[str] = []
        try:
            async for line in self.response.aiter_lines():
                if line == "":
                    event = self._decode_event(event_data)
                    event_data.clear()
                    if event is _DONE:
                        return
                    if event is not None:
                        yield event
                    continue
                if line.startswith(":"):
                    continue
                if line.startswith("data:"):
                    event_data.append(line[5:].lstrip())
            event = self._decode_event(event_data)
            if event is not _DONE and event is not None:
                yield event
        finally:
            await self.close()

    def _decode_event(self, lines: list[str]):
        if not lines:
            return None
        raw = "\n".join(lines).strip()
        if raw == "[DONE]":
            return _DONE
        try:
            data = json.loads(raw)
        except (TypeError, ValueError) as exc:
            raise ProviderError(self.provider, "invalid SSE JSON frame") from exc
        if isinstance(data, dict) and data.get("error"):
            error = data["error"]
            message = error.get("message") if isinstance(error, dict) else str(error)
            raise ProviderError(self.provider, str(message or "stream returned an error"))
        if not isinstance(data, dict):
            raise ProviderError(self.provider, "unexpected SSE frame")
        return _to_attr(data)

    async def close(self) -> None:
        if not self._closed:
            self._closed = True
            await self.response.aclose()


_DONE = object()


class BufferedEventStream:
    """Provide one normalized chunk for documented non-streaming adapters."""

    def __init__(self, payload: dict[str, Any]):
        self.payload = _to_attr(payload)

    async def _iterate(self):
        yield self.payload

    def __aiter__(self):
        return self._iterate()

    async def close(self) -> None:
        return None


class _Namespace:
    def __init__(self, **values):
        self.__dict__.update(values)


class ProviderClient:
    """Explicit provider client while retaining GhoGem's response interface."""

    def __init__(self, provider: str, api_key: str = ""):
        self.provider = provider
        self.api_key = api_key.strip()
        self.spec = PROVIDER_SPECS[provider]
        timeout = httpx.Timeout(
            connect=30.0,
            read=35.0 if provider == "sambanova" else 300.0,
            write=300.0,
            pool=300.0,
        )
        client_options: dict[str, Any] = {"timeout": timeout}
        if provider == "pollinations":
            # Pollinations is deliberately proxy-only. Disable environment proxy
            # inheritance so there is no accidental direct/alternate route.
            client_options["trust_env"] = False
            explicit_proxy = os.environ.get("POLLINATIONS_SOCKS_PROXY", "").strip()
            if _proxychains_active():
                pass
            else:
                client_options["proxy"] = explicit_proxy or "socks5://127.0.0.1:1080"
        self._http = httpx.AsyncClient(**client_options)
        self._pollinations_catalog_loaded_at = 0.0
        self._pollinations_models: list[dict[str, Any]] = []
        self.chat = _Namespace(completions=_ChatCompletions(self))
        self.audio = (
            _Namespace(transcriptions=_GroqTranscriptions(self))
            if provider == "groq" else None
        )

    def _headers(self) -> dict[str, str]:
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if self.spec.auth in ("bearer", "bearer_any", "bearer_required"):
            headers["Authorization"] = f"Bearer {self.api_key}"
        headers.update(dict(self.spec.extra_headers))
        return headers

    def _url(self) -> str:
        return self.spec.base_url.rstrip("/") + self.spec.path

    async def _raise_http_error(self, response: httpx.Response) -> None:
        if response.is_success:
            return
        message = "request rejected"
        try:
            payload = response.json()
            if isinstance(payload, dict):
                error = payload.get("error") or payload.get("message")
                if isinstance(error, dict):
                    message = str(error.get("message") or error.get("type") or message)
                elif error:
                    message = str(error)
        except Exception:
            body = (await response.aread()).decode("utf-8", errors="replace")
            if body.strip():
                message = body[:500]
        raise ProviderError(self.provider, message, status_code=response.status_code)

    async def _post_json(self, url: str, payload: dict[str, Any], *, headers=None) -> AttrMap:
        response = await self._http.post(url, json=payload, headers=headers or self._headers())
        await self._raise_http_error(response)
        try:
            data = response.json()
        except ValueError as exc:
            raise ProviderError(self.provider, "response was not JSON") from exc
        if not isinstance(data, dict):
            raise ProviderError(self.provider, "unexpected JSON response")
        return _to_attr(data)

    async def _get_json(self, url: str, *, params=None, headers=None) -> AttrMap:
        response = await self._http.get(url, params=params, headers=headers or self._headers())
        await self._raise_http_error(response)
        try:
            data = response.json()
        except ValueError as exc:
            raise ProviderError(self.provider, "response was not JSON") from exc
        if not isinstance(data, dict):
            raise ProviderError(self.provider, "unexpected JSON response")
        return _to_attr(data)

    async def _pollinations_model_contract(self, model: str) -> dict[str, Any] | None:
        """Resolve model capabilities from Pollinations' documented `/v1/models`.

        Pollinations documents model-specific supported parameters and tool
        capabilities. Cache the public catalogue briefly, using the same
        proxy-only transport as generation requests.
        """
        now = time.monotonic()
        if now - self._pollinations_catalog_loaded_at >= 300:
            try:
                response = await self._http.get(
                    self.spec.base_url.rstrip("/") + "/v1/models",
                    headers=self._headers(),
                )
                await self._raise_http_error(response)
                payload = response.json()
                entries = payload.get("data") if isinstance(payload, dict) else None
                if isinstance(entries, list):
                    self._pollinations_models = [
                        dict(item) for item in entries if isinstance(item, dict)
                    ]
                    self._pollinations_catalog_loaded_at = now
            except Exception:
                # A failed catalogue read must not cause direct routing or
                # prevent the documented chat endpoint from being attempted.
                self._pollinations_catalog_loaded_at = now
                return None

        for entry in self._pollinations_models:
            aliases = entry.get("aliases")
            if entry.get("id") == model or (isinstance(aliases, list) and model in aliases):
                return entry
        if self._pollinations_models:
            raise ProviderError(
                "pollinations",
                f"model {model!r} is not present in the current /v1/models catalogue",
            )
        return None

    async def _apply_pollinations_contract(self, payload: dict[str, Any]) -> dict[str, Any]:
        model = str(payload.get("model") or "")
        entry = await self._pollinations_model_contract(model)
        if entry is None:
            return payload

        capabilities = entry.get("capabilities")
        if isinstance(payload.get("tools"), list) and payload["tools"]:
            if not isinstance(capabilities, list) or "tool_calling" not in capabilities:
                raise ProviderError(
                    "pollinations",
                    f"model {model!r} does not advertise tool_calling",
                )

        supported = entry.get("supported_parameters")
        if isinstance(supported, list):
            allowed = {str(value) for value in supported}
            for name in (
                "temperature", "top_p", "max_tokens", "max_completion_tokens",
                "response_format", "stop", "seed", "n", "frequency_penalty",
                "presence_penalty", "reasoning_effort", "reasoning_format",
                "include_reasoning", "verbosity",
            ):
                if name in payload and name not in allowed:
                    payload.pop(name, None)
        else:
            # Community models intentionally omit supported_parameters in the
            # official catalogue. Avoid guessing their sampling controls.
            for name in (
                "temperature", "top_p", "max_tokens", "max_completion_tokens",
                "response_format", "stop", "seed", "n", "frequency_penalty",
                "presence_penalty", "reasoning_effort", "reasoning_format",
                "include_reasoning", "verbosity",
            ):
                payload.pop(name, None)
        return payload

    async def _create_completion(self, **kwargs):
        if self.spec.strategy == "cvron":
            return await self._create_cvron(kwargs)
        if self.spec.strategy == "visionster":
            return await self._create_visionster(kwargs)

        payload = _build_chat_payload(self.spec, kwargs)
        if self.provider == "pollinations":
            payload = await self._apply_pollinations_contract(payload)
        if not payload.get("messages"):
            raise ProviderError(self.provider, "messages must not be empty")
        if payload.get("stream"):
            request = self._http.build_request(
                "POST", self._url(), json=payload, headers=self._headers()
            )
            response = await self._http.send(request, stream=True)
            await self._raise_http_error(response)
            return ProviderEventStream(self.provider, response)
        return await self._post_json(self._url(), payload)

    async def _create_cvron(self, kwargs: dict[str, Any]):
        model = str(kwargs.get("model") or "").strip()
        prompt = _flatten_messages(kwargs.get("messages") or [])
        if not model or not prompt:
            raise ProviderError(self.provider, "model and prompt are required")
        # CVRON documents a model-specific JSON endpoint with a `prompt` query
        # parameter. It does not document OpenAI tools or SSE.
        response = await self._get_json(
            self._url(), params={"model": model, "prompt": prompt}
        )
        answer = response.get("response")
        if not isinstance(answer, str):
            raise ProviderError(self.provider, "response field missing from CVRON JSON")
        return _normalized_completion(model, answer, stream=bool(kwargs.get("stream")))

    async def _create_visionster(self, kwargs: dict[str, Any]):
        messages = kwargs.get("messages") or []
        prompt, image, image_url, history = _visionster_request(messages)
        if not prompt or not (image or image_url):
            raise ProviderError(self.provider, "VisionSter requires a prompt and image")
        payload: dict[str, Any] = {"userPrompt": prompt}
        if image:
            payload["image"] = image
        else:
            payload["url"] = image_url
        if history:
            payload["messages"] = history
        response = await self._post_json(self._url(), payload)
        answer = response.get("response")
        if not isinstance(answer, str):
            raise ProviderError(self.provider, "response field missing from VisionSter JSON")
        return _normalized_completion("imgchat", answer, stream=bool(kwargs.get("stream")))

    async def close(self) -> None:
        await self._http.aclose()


class _ChatCompletions:
    def __init__(self, client: ProviderClient):
        self.client = client

    async def create(self, **kwargs):
        return await self.client._create_completion(**kwargs)


class _GroqTranscriptions:
    def __init__(self, client: ProviderClient):
        self.client = client

    async def create(self, *, model: str, file: BinaryIO, language: str | None = None, **kwargs):
        filename = Path(str(getattr(file, "name", "audio.bin"))).name
        mime = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        data: dict[str, str] = {"model": model}
        if language:
            data["language"] = language
        for key in ("prompt", "response_format", "temperature", "timestamp_granularities"):
            if kwargs.get(key) is not None:
                value = kwargs[key]
                data[key] = json.dumps(value) if isinstance(value, (list, dict)) else str(value)
        headers = {"Authorization": f"Bearer {self.client.api_key}"}
        response = await self.client._http.post(
            "https://api.groq.com/openai/v1/audio/transcriptions",
            files={"file": (filename, file, mime)},
            data=data,
            headers=headers,
        )
        await self.client._raise_http_error(response)
        try:
            payload = response.json()
        except ValueError as exc:
            raise ProviderError("groq", "transcription response was not JSON") from exc
        if not isinstance(payload, dict):
            raise ProviderError("groq", "unexpected transcription response")
        return _to_attr(payload)


def _build_chat_payload(spec: ProviderSpec, kwargs: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "model", "messages", "temperature", "top_p", "max_tokens",
        "max_completion_tokens", "stream", "stream_options", "tools",
        "tool_choice", "response_format", "stop", "seed", "n",
        "parallel_tool_calls", "reasoning_effort", "reasoning_format",
        "include_reasoning", "verbosity", "frequency_penalty", "presence_penalty",
    }
    payload = {
        key: value for key, value in kwargs.items()
        if key in allowed and value is not None and key not in spec.drop_request_fields
    }
    messages = payload.get("messages")
    if isinstance(messages, list):
        clean = []
        for message in messages:
            if not isinstance(message, dict):
                continue
            normalized = dict(message)
            if normalized.get("role") == "developer":
                normalized["role"] = "system"
            clean.append({
                key: value for key, value in normalized.items()
                if key not in spec.drop_message_fields
            })
        payload["messages"] = clean
    if spec.max_tokens_field != "max_tokens" and "max_tokens" in payload and "max_completion_tokens" not in payload:
        payload[spec.max_tokens_field] = payload.pop("max_tokens")
    return payload


def _flatten_messages(messages: list[Any]) -> str:
    parts = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "user").upper()
        content = message.get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = " ".join(
                str(part.get("text") or "")
                for part in content
                if isinstance(part, dict) and part.get("type") == "text"
            )
        else:
            text = str(content or "")
        if text.strip():
            parts.append(f"{role}: {text.strip()}")
    return "\n\n".join(parts)


def _visionster_request(messages: list[Any]):
    prompt = ""
    image = ""
    image_url = ""
    history: list[dict[str, str]] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "user")
        content = message.get("content")
        text = content if isinstance(content, str) else ""
        if isinstance(content, list):
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text":
                    text = f"{text}\n{part.get('text') or ''}".strip()
                elif part.get("type") == "image_url":
                    descriptor = part.get("image_url")
                    url = descriptor.get("url") if isinstance(descriptor, dict) else None
                    if isinstance(url, str) and url.startswith("data:image/"):
                        image = url
                    elif isinstance(url, str) and url.startswith(("https://", "http://")):
                        image_url = url
        if role == "user" and text.strip():
            prompt = text.strip()
        if role in ("user", "assistant") and text.strip():
            history.append({"type": "user" if role == "user" else "ai", "content": text.strip()})
    return prompt, image, image_url, history[-20:]


def _normalized_completion(model: str, text: str, *, stream: bool) -> Any:
    now = int(time.time())
    if stream:
        return BufferedEventStream({
            "id": f"chatcmpl-ghogem-{uuid.uuid4().hex}",
            "object": "chat.completion.chunk",
            "created": now,
            "model": model,
            "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": "stop"}],
        })
    return _to_attr({
        "id": f"chatcmpl-ghogem-{uuid.uuid4().hex}",
        "object": "chat.completion",
        "created": now,
        "model": model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
    })


def create_provider_client(provider: str, api_key: str = "") -> ProviderClient | None:
    provider = str(provider or "").strip().lower()
    spec = PROVIDER_SPECS.get(provider)
    if spec is None:
        return None
    key = str(api_key or "").strip()
    if spec.auth in ("bearer", "bearer_required") and not key:
        return None
    if spec.auth == "bearer_any" and not key:
        key = "any-random-key"
    if provider == "pollinations" and not key.startswith("sk_"):
        return None
    try:
        return ProviderClient(provider, key)
    except Exception as exc:
        if provider != "pollinations":
            raise
        # Keep the other providers online if SOCKS support or the configured
        # proxy is broken. Pollinations remains unavailable rather than falling
        # back to a direct request.
        import logging
        logging.getLogger(__name__).warning(
            "Pollinations client disabled: %s", type(exc).__name__
        )
        return None


async def transcribe_stt_ai(file_path: str, api_key: str = "") -> str:
    """Use STT.ai's documented multipart `/v1/transcribe` endpoint."""
    headers = {"Authorization": f"Bearer {api_key}"} if api_key.strip() else {}
    filename = Path(file_path).name
    mime = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    timeout = httpx.Timeout(connect=30.0, read=300.0, write=300.0, pool=300.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        with open(file_path, "rb") as stream:
            response = await client.post(
                "https://api.stt.ai/v1/transcribe",
                headers=headers,
                files={"file": (filename, stream, mime)},
                data={"model": "large-v3-turbo", "language": "ru", "diarize": "false"},
            )
        if not response.is_success:
            raise ProviderError("sttai", "transcription request failed", status_code=response.status_code)
        payload = response.json()
    text = payload.get("text") if isinstance(payload, dict) else None
    if not isinstance(text, str):
        raise ProviderError("sttai", "text field missing from transcription response")
    return text.strip()
