import asyncio
import public_url_reader as r
import ai, tool_registry

def expect_block(url, needle=None):
    try:
        r.target(url)
    except Exception as exc:
        text=str(exc)
        if needle:
            assert needle.lower() in text.lower(), (url,text)
        return
    raise AssertionError(f"URL was not blocked: {url}")

async def main():
    expect_block("http://127.0.0.1/", "внутрен")
    expect_block("http://localhost/", "внутрен")
    expect_block("https://user:pass@example.com/", "логина")
    expect_block("http://example.com/?access_token=secret", "чувств")
    blocked_port=await r.get_page_source("https://example.com:444/", 2000)
    assert blocked_port.startswith("❌") and "80/443" in blocked_port, blocked_port
    print("PASS SSRF/credential/sensitive-http/port guards")

    out=await r.get_page_source("https://example.com/", 5000)
    assert not out.startswith("❌"), out
    assert "BEGIN UNTRUSTED PAGE SOURCE" in out
    assert "<html" in out.lower() or "<!doctype" in out.lower(), out[:500]
    assert "Example Domain" in out
    print("PASS real HTTPS raw source")

    tool_index=tool_registry.tool_index(ai.TOOLS)
    assert "get_page_source" in tool_index
    schema=tool_index["get_page_source"]["function"]["parameters"]
    assert schema["properties"]["max_chars"]["maximum"]==60000
    assert "get_page_source" in tool_registry.INSTRUCTIONS
    print("PASS tool registry/schema")

asyncio.run(main())
