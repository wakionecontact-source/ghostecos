import ai

def row(url, title="x"):
    return {"href": url, "title": title, "body": "body", "_search_type": "web"}

rows = [
    row("https://example.com/post", "Python guide"),
    row("https://docs.python.org/3/library/asyncio.html", "asyncio docs"),
    row("https://www.cdc.gov/example", "official"),
    row("https://stackoverflow.com/questions/1", "community"),
    row("https://arxiv.org/abs/1234.5", "paper"),
]

preferred = ai._apply_search_filters_and_trust(
    rows, query="python asyncio",
    include_domains=[], exclude_domains=[], trusted_domains=[],
    trust_mode="prefer_trusted", source_category="docs",
)
assert ai._row_host(preferred[0]) == "docs.python.org", preferred

strict = ai._apply_search_filters_and_trust(
    rows, query="paper",
    include_domains=[], exclude_domains=[], trusted_domains=[],
    trust_mode="trusted_only", source_category="science",
)
assert [ai._row_host(x) for x in strict] == ["arxiv.org"], strict

whitelist = ai._apply_search_filters_and_trust(
    rows, query="anything",
    include_domains=["stackoverflow.com"], exclude_domains=[], trusted_domains=[],
    trust_mode="any", source_category="auto",
)
assert [ai._row_host(x) for x in whitelist] == ["stackoverflow.com"], whitelist

blacklist = ai._apply_search_filters_and_trust(
    rows, query="anything",
    include_domains=[], exclude_domains=["example.com"], trusted_domains=[],
    trust_mode="any", source_category="auto",
)
assert "example.com" not in [ai._row_host(x) for x in blacklist]

explicit = ai._apply_search_filters_and_trust(
    rows, query="anything",
    include_domains=[], exclude_domains=[], trusted_domains=["example.com"],
    trust_mode="trusted_only", source_category="auto",
)
assert [ai._row_host(x) for x in explicit] == ["example.com"], explicit

fp1 = ai._search_filter_fingerprint(
    include_domains=[], exclude_domains=[], trusted_domains=[],
    trust_mode="any", source_category="auto", safe_search="moderate",
)
fp2 = ai._search_filter_fingerprint(
    include_domains=["docs.python.org"], exclude_domains=[], trusted_domains=[],
    trust_mode="trusted_only", source_category="docs", safe_search="strict",
)
assert ai._search_cache_filename("python", 8, "web", None, "us-en", fp1) != ai._search_cache_filename("python", 8, "web", None, "us-en", fp2)
print("PASS web trust/domain filters and cache isolation")
