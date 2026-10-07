import asyncio
from urllib.parse import urlparse
import public_url_reader as p
import ai, tool_registry, json

assert p._https_variant("http://example.com/path?q=1#frag") == "https://example.com/path?q=1"
assert p._https_variant("https://example.com/path?q=1") == "https://example.com/path?q=1"

try:
    p._reject_sensitive_http_query(urlparse("http://example.com/path?token=SECRET"))
except ValueError:
    pass
else:
    raise AssertionError("HTTP token must be blocked")

p._reject_sensitive_http_query(urlparse("https://example.com/path?token=SECRET"))

calls=[]
original=p._read_page
async def fake_read(url,max_chars,*,http_fallback=False):
    calls.append((url,http_fallback))
    if url.startswith("https://"):
        raise ValueError("TLS unavailable")
    return "Точная ссылка: http://example.com/path\nHTTP: 200\nOK"

async def main():
    p._read_page=fake_read
    try:
        out=await p.open_public_url("http://example.com/path")
        assert calls == [
            ("https://example.com/path",False),
            ("http://example.com/path",True),
        ], calls
        assert "http://example.com/path" in out
    finally:
        p._read_page=original

asyncio.run(main())

start,done=ai._tool_status_phrases(
    "open_url",
    {"url":"http://example.com/path?q=1"},
    "Точная ссылка: https://example.com/path?q=1\nHTTP: 200\nOK",
)
assert "http://example.com/path?q=1" in start
assert "https://example.com/path?q=1" in done

instructions=json.loads(tool_registry.instructions_for("open_url",ai.TOOLS))
assert "ВСЕГДА предпочитай HTTPS" in instructions["rules"]
prompt=ai.build_modular_system_prompt(
    prompt="открой http://example.com",
    model_key=next(iter(ai.AVAILABLE_MODELS)),
    timezone_name="Europe/Moscow",
    is_premium=False,
)
assert "Всегда предпочитай HTTPS" in prompt
print("PASS: HTTPS-first + HTTP privacy mode + full actual URL")
