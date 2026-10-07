"""Реальный веб-поиск без платных ключей.

Изначально пробовали HTML-скрейп html.duckduckgo.com/html/ (как раньше
делали в chatgpt/text.py c Google CSE) — DDG отдаёт капчу "select all
squares containing a duck" на автоматические запросы, обходить капчу
программно не будем. Вместо этого — две официальные бесплатные точки
входа без ключей:
  1. DuckDuckGo Instant Answer API (api.duckduckgo.com) — короткие
     готовые абстракты по известным темам.
  2. Wikipedia search + extracts API — широкое покрытие фактических
     вопросов, официальный API, не блокируется.
Компромисс: это не полный веб-поиск как у Google, а два living-источника
фактов. Для "кратких ответов на вопросы" этого достаточно.
"""

import json
import urllib.parse
import urllib.request

HEADERS = {"User-Agent": "qa_bot/1.0 (educational hobby project; contact wakionecontact@gmail.com)"}


def _get_json(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def ddg_instant_answer(query):
    params = {"q": query, "format": "json", "no_html": "1", "skip_disambig": "1"}
    url = "https://api.duckduckgo.com/?" + urllib.parse.urlencode(params)
    try:
        data = _get_json(url)
    except Exception:
        return []
    snippets = []
    if data.get("AbstractText"):
        snippets.append({"url": data.get("AbstractURL", "duckduckgo.com"), "text": data["AbstractText"]})
    for topic in data.get("RelatedTopics", []):
        if isinstance(topic, dict) and topic.get("Text"):
            snippets.append({"url": topic.get("FirstURL", "duckduckgo.com"), "text": topic["Text"]})
    return snippets


def wikipedia_search(query, num_results=3):
    params = {
        "action": "query",
        "list": "search",
        "srsearch": query,
        "srlimit": str(num_results),
        "format": "json",
        "formatversion": "2",
    }
    url = "https://ru.wikipedia.org/w/api.php?" + urllib.parse.urlencode(params)
    try:
        data = _get_json(url)
    except Exception:
        return []
    return [r["title"] for r in data.get("query", {}).get("search", [])]


def wikipedia_extracts(titles, chars_per_page=1200):
    if not titles:
        return []
    params = {
        "action": "query",
        "prop": "extracts",
        "explaintext": "1",
        "exchars": str(chars_per_page),
        "titles": "|".join(titles),
        "format": "json",
        "formatversion": "2",
    }
    url = "https://ru.wikipedia.org/w/api.php?" + urllib.parse.urlencode(params)
    try:
        data = _get_json(url)
    except Exception:
        return []
    out = []
    for page in data.get("query", {}).get("pages", []):
        extract = page.get("extract", "")
        if extract:
            out.append({
                "url": f"https://ru.wikipedia.org/wiki/{urllib.parse.quote(page['title'])}",
                "text": extract,
            })
    return out


def search_and_extract(query, num_results=3, min_len=100):
    snippets = ddg_instant_answer(query)
    titles = wikipedia_search(query, num_results=num_results)
    snippets.extend(wikipedia_extracts(titles))
    return [s for s in snippets if len(s["text"]) >= min_len]


if __name__ == "__main__":
    import sys

    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    q = " ".join(sys.argv[1:]) or "почему небо голубое"
    print(f"Запрос: {q}")
    results = search_and_extract(q)
    print(f"Найдено сниппетов: {len(results)}")
    for r in results:
        print("---", r["url"])
        print(r["text"][:300])
