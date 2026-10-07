import asyncio
import ai
import public_url_reader as reader
import tool_registry

async def test_fake_source():
    old_target=reader.target
    old_fetch=reader.fetch
    try:
        def fake_target(url):
            return url, "example.test", 443, "93.184.216.34"
        async def fake_fetch(clean,host,port,address):
            body=(
                b'<!doctype html><html><head><script>'
                b'window.__SHOULD_NOT_EXECUTE__=1;</script></head>'
                b'<body data-x="1">' + b'A'*70000 + b'</body></html>'
            )
            return 200, {"content-type":"text/html; charset=utf-8"}, body
        reader.target=fake_target
        reader.fetch=fake_fetch
        out=await reader._read_source("https://example.test/", 2000)
        assert "window.__SHOULD_NOT_EXECUTE__=1" in out
        assert len(out) < 4000
        assert "обрезан до 2000" in out
        print("PASS raw source preserved + truncation")
    finally:
        reader.target=old_target
        reader.fetch=old_fetch

def test_filters():
    rows=[
        {"title":"Python docs","href":"https://docs.python.org/3/","body":"Python documentation"},
        {"title":"Random blog","href":"https://random.example/post","body":"Python documentation"},
        {"title":"MDN","href":"https://developer.mozilla.org/en-US/","body":"Web docs"},
    ]
    out=ai._apply_search_filters_and_trust(
        rows,query="Python documentation",
        include_domains=[],exclude_domains=["random.example"],
        trusted_domains=[],trust_mode="prefer_trusted",source_category="docs",
    )
    assert len(out)==2
    assert all("random.example" not in str(x) for x in out)
    assert out[0].get("_trusted_source") is True
    strict=ai._apply_search_filters_and_trust(
        rows,query="Python documentation",
        include_domains=[],exclude_domains=[],
        trusted_domains=["docs.python.org"],trust_mode="trusted_only",source_category="official",
    )
    assert len(strict)==1 and "docs.python.org" in strict[0]["href"]
    f1=ai._search_filter_fingerprint(
        include_domains=["a.com"],exclude_domains=[],trusted_domains=[],
        trust_mode="any",source_category="auto",safe_search="moderate")
    f2=ai._search_filter_fingerprint(
        include_domains=["b.com"],exclude_domains=[],trusted_domains=[],
        trust_mode="any",source_category="auto",safe_search="moderate")
    assert ai._search_cache_filename("x",filter_fingerprint=f1) != ai._search_cache_filename("x",filter_fingerprint=f2)
    print("PASS web trust/domain filters + cache isolation")

def test_no_raw_fallback():
    raw='--- BEGIN UNTRUSTED PAGE SOURCE ---\n<html>SECRET_SOURCE</html>'
    out=ai._fallback_from_tools([("get_page_source",raw)])
    assert "SECRET_SOURCE" not in out
    assert "<html>" not in out
    print("PASS page source never leaks through fallback")

async def main():
    await test_fake_source()
    test_filters()
    test_no_raw_fallback()
    idx=tool_registry.tool_index(ai.TOOLS)
    assert "get_page_source" in idx
    start,done=ai._tool_status_phrases("get_page_source",{"url":"https://example.com"}, "ok")
    assert "код" in start.lower() and "код" in done.lower()
    print("PASS source tool registration/status")

asyncio.run(main())
