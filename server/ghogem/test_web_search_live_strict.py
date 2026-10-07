import asyncio, ai

async def main():
    result = await ai.do_web_search(
        "Python asyncio TaskGroup",
        max_results=4,
        search_type="web",
        region="us-en",
        include_domains=["docs.python.org"],
        trusted_domains=["docs.python.org"],
        trust_mode="trusted_only",
        source_category="docs",
        safe_search="moderate",
    )
    print(result[:5000])
    if result.startswith("❌"):
        raise SystemExit(2)
    if "ничего не найдено" not in result:
        assert "docs.python.org" in result
        assert "приоритетный источник" in result
        assert "example.com" not in result
    print("PASS live strict-domain web search")

asyncio.run(main())
