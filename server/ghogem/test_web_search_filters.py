import ai

rows = [
    {
        "title": "Python asyncio docs",
        "href": "https://docs.python.org/3/library/asyncio.html",
        "body": "Official Python documentation for asyncio",
        "_search_type": "web",
    },
    {
        "title": "Random SEO mirror",
        "href": "https://example-seo.invalid/python-asyncio",
        "body": "python asyncio docs copied article",
        "_search_type": "web",
    },
    {
        "title": "Stack Overflow discussion",
        "href": "https://stackoverflow.com/questions/123/example",
        "body": "Community answer",
        "_search_type": "web",
    },
]

assert ai._normalize_domain_list([
    "https://www.Docs.Python.org/3/", "docs.python.org", "bad domain!"
]) == ["docs.python.org"]

filtered = ai._apply_search_filters_and_trust(
    rows,
    query="python asyncio docs",
    include_domains=["docs.python.org"],
    exclude_domains=[],
    trusted_domains=[],
    trust_mode="any",
    source_category="auto",
)
assert len(filtered) == 1
assert ai._row_host(filtered[0]) == "docs.python.org"

excluded = ai._apply_search_filters_and_trust(
    rows,
    query="python asyncio",
    include_domains=[],
    exclude_domains=["stackoverflow.com"],
    trusted_domains=[],
    trust_mode="any",
    source_category="auto",
)
assert all(ai._row_host(r) != "stackoverflow.com" for r in excluded)

preferred = ai._apply_search_filters_and_trust(
    rows,
    query="python asyncio",
    include_domains=[],
    exclude_domains=[],
    trusted_domains=["stackoverflow.com"],
    trust_mode="prefer_trusted",
    source_category="auto",
)
assert ai._row_host(preferred[0]) == "docs.python.org" or preferred[0].get("_trusted_source")
# Explicit trusted domain must itself be marked.
so = next(r for r in preferred if ai._row_host(r) == "stackoverflow.com")
assert so["_trusted_source"] is True

strict = ai._apply_search_filters_and_trust(
    rows,
    query="python asyncio",
    include_domains=[],
    exclude_domains=[],
    trusted_domains=["docs.python.org"],
    trust_mode="trusted_only",
    source_category="docs",
)
assert strict
assert all(r.get("_trusted_source") for r in strict)
assert all(ai._row_host(r) != "example-seo.invalid" for r in strict)

base = ai._search_cache_filename("x", 8, "web", None, "us-en", "A")
other = ai._search_cache_filename("x", 8, "web", None, "us-en", "B")
assert base != other

tool = next(
    t for t in ai.TOOLS if (t.get("function") or {}).get("name") == "web_search"
)
props = tool["function"]["parameters"]["properties"]
for key in (
    "include_domains", "exclude_domains", "trusted_domains",
    "trust_mode", "source_category", "safe_search",
):
    assert key in props, key

print("PASS web search filters/trust/cache/schema")
