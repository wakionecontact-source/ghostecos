import asyncio
import json
import os
from types import SimpleNamespace as NS

import ai
import music
import tool_registry


PUBLIC_ID = "e3fb6b7e1785200456c678dd"
PENDING_ID = "25aec5dd7c02c2a636fe8286"


async def test_music_core():
    rows = await music.search_catalog("", kind="music", limit=50)
    assert rows
    assert all((x["track"].get("Kind") or "") == "music" for x in rows)
    assert all(x["track"].get("ModerationStatus") == "published" for x in rows)
    track = await music.get_track(PUBLIC_ID)
    assert track and track["ID"] == PUBLIC_ID
    assert track.get("stream_url", "").startswith("https://")
    assert music.resolve_public_audio_path(PUBLIC_ID)
    assert await music.get_track(PENDING_ID) is None
    assert music.resolve_public_audio_path(PENDING_ID) is None
    related = await music.related_tracks(PUBLIC_ID, 8)
    assert isinstance(related, list)


async def test_advanced_audio_search():
    original_catalog = music.catalog
    fake_rows = [
        {
            "ID":"s1","Slug":"rain-hit","Title":"Rain Hit","Artist":"FX Lab",
            "AuthorName":"FX Lab","Kind":"sound","Duration":2.4,"Bitrate":"192k",
            "Plays":50,"Tags":["rain","impact"],"Genres":["foley"],"Genre":"foley",
            "Language":"","SourceType":"original","License":"cc0",
            "DownloadAllowed":True,"AuthorVerified":True,"Visibility":"public",
            "ModerationStatus":"published",
        },
        {
            "ID":"l1","Slug":"rain-loop","Title":"Rain Ambience Loop","Artist":"Nature",
            "AuthorName":"Nature","Kind":"loop","Duration":30,"Bitrate":"128k",
            "Plays":5,"Tags":["rain","ambient"],"Genres":["nature"],"Genre":"nature",
            "Language":"","SourceType":"original","License":"cc_by",
            "DownloadAllowed":True,"AuthorVerified":False,"Visibility":"public",
            "ModerationStatus":"published",
        },
        {
            "ID":"m1","Slug":"rain-song","Title":"Rain Song","Artist":"Band",
            "Kind":"music","Duration":210,"Bitrate":"320k","Plays":100,
            "Tags":["rain"],"Genres":["pop"],"Genre":"pop","SourceType":"original",
            "License":"all_rights_reserved","DownloadAllowed":False,
            "AuthorVerified":True,"Visibility":"public","ModerationStatus":"published",
        },
        {
            "ID":"u1","Slug":"hidden-rain","Title":"Hidden Rain","Artist":"Private FX",
            "Kind":"sound","Duration":4,"Bitrate":"192k","Plays":0,
            "Tags":["rain"],"Genres":["foley"],"Genre":"foley","SourceType":"original",
            "License":"cc0","DownloadAllowed":True,"AuthorVerified":False,
            "Visibility":"unlisted","ModerationStatus":"published",
        },
    ]
    async def fake_catalog(limit=500):
        return fake_rows[:limit]
    fake_rows[0].update({"Size": 2 * 1024 * 1024, "PublishedAt": "2026-09-20T12:00:00Z"})
    fake_rows[1].update({"Size": 5 * 1024 * 1024, "PublishedAt": "2026-08-20T12:00:00Z", "Album": "Nature Pack"})
    fake_rows[2].update({"Size": 8 * 1024 * 1024, "PublishedAt": "2026-07-20T12:00:00Z", "Album": "Rain LP"})
    fake_rows[3].update({"Size": 1 * 1024 * 1024, "PublishedAt": "2026-09-25T12:00:00Z"})
    music.catalog = fake_catalog
    try:
        sounds = await music.search_catalog(
            "rain", kind="sound", max_duration=5, min_bitrate_kbps=160,
            downloadable=True, verified=True,
        )
        assert [x["track"]["ID"] for x in sounds] == ["s1"]
        broad = await music.search_catalog("rain impact", match_mode="any", limit=20)
        assert {x["track"]["ID"] for x in broad} == {"s1","l1","m1"}
        tagged = await music.search_catalog("", tags=["rain","ambient"], tag_mode="all")
        assert [x["track"]["ID"] for x in tagged] == ["l1"]
        page = await music.search_catalog_page(query="rain", limit=1, offset=1, match_mode="any")
        assert page["total"] == 3 and page["has_more"] is True
        assert page["next_offset"] == 2 and len(page["matches"]) == 1
        assert page["facets"]["kinds"] == {"loop": 1, "music": 1, "sound": 1}
        assert page["facets"]["tags"].get("rain") == 3
        assert page["facets"]["artists"].get("FX Lab") == 1
        assert page["facets"]["albums"].get("Nature Pack") == 1
        assert page["facets"]["source_types"].get("original") == 3
        assert page["summary"]["matches"] == 3
        assert page["summary"]["downloadable"] == 2
        assert page["summary"]["verified"] == 2

        exact_title = await music.search_catalog("", title="Rain Hit")
        assert [x["track"]["ID"] for x in exact_title] == ["s1"]
        size_filtered = await music.search_catalog("", min_size_kb=4000, max_size_kb=6000)
        assert [x["track"]["ID"] for x in size_filtered] == ["l1"]
        date_filtered = await music.search_catalog("", published_after="2026-09-01T00:00:00Z")
        assert [x["track"]["ID"] for x in date_filtered] == ["s1"]
        relaxed = await music.search_catalog_page(
            query="rain impossibleword", limit=10, match_mode="all"
        )
        assert relaxed["relaxed_match"] is True
        assert relaxed["match_mode_used"] == "any"
        assert len(relaxed["matches"]) == 3

        # unlisted is directly readable by exact identifier but must never
        # leak into ordinary catalog discovery.
        direct_hidden = await music.get_track("u1")
        assert direct_hidden and direct_hidden["ID"] == "u1"
        hidden_search = await music.search_catalog("hidden rain", match_mode="any", limit=20)
        assert all(x["track"]["ID"] != "u1" for x in hidden_search)

        compact = music.compact_agent_search_payload({
            "catalog": broad,
            "catalog_meta": {
                "total": 3, "offset": 0, "limit": 3, "has_more": False,
                "next_offset": None, "match_mode_used": "any",
                "relaxed_match": False, "facets": page["facets"],
            },
        }, max_items=12)
        encoded = json.dumps(compact, ensure_ascii=False)
        assert len(encoded) < 6000
        assert len(compact["catalog"]) == 3
        assert all("id" in item and "title" in item for item in compact["catalog"])
        assert all("Description" not in item and "Lyrics" not in item for item in compact["catalog"])
    finally:
        music.catalog = original_catalog


def test_ghosou_request_detector():
    cases = [
        ("найди звук дождя", True),
        ("подбери музыку для фона", True),
        ("пришли какой-нибудь луп", True),
        ("хочу послушать подкаст про ИИ", True),
        ("что такое музыка", False),
        ("найди трек на YouTube", False),
        ("поищи песню в Spotify", False),
        ("какой жанр у этого трека?", False),
    ]
    for text, want in cases:
        got = ai.user_explicitly_requests_ghosou_search(text)
        assert got == want, (text, got, want)


def test_registry():
    names = {x["function"]["name"] for x in ai.TOOLS}
    for name in (
        "ghosou_search", "ghosou_get_track", "ghosou_related",
        "ghosou_send_audio", "ghosou_check_metadata",
    ):
        assert name in names, name
        payload = json.loads(tool_registry.instructions_for(name, ai.TOOLS))
        assert payload["ready"] is True
        assert payload["tool_name"] == name


async def test_forced_ghosou_search_after_plain_text():
    original = {name: getattr(ai, name) for name in (
        "get_client", "_request_with_single_retry", "user_has_premium",
        "get_current_chat", "load_history", "save_history", "list_files",
        "read_memory", "is_model_available",
    )}
    original_search = music.search_catalog_page
    steps=[]
    saved=[]

    class Client:
        def __init__(self): self.chat=NS(completions=NS(create=self.create))
        def create(self,**kwargs):
            steps.append(kwargs)
            idx=len(steps)
            if idx==1:
                return NS(choices=[NS(
                    message=NS(content="Вот звук дождя: попробуй Rain FX",tool_calls=[]),
                    finish_reason="stop",
                )],usage=None)
            if idx==2:
                call=("get_tool_instructions",{"tool_name":"ghosou_search"})
            elif idx==3:
                visible={t["function"]["name"] for t in kwargs.get("tools",[])}
                assert "ghosou_search" in visible
                call=("ghosou_search",{"query":"дождь","kind":"sound","scope":"catalog","limit":5})
            elif idx==4:
                return NS(choices=[NS(
                    message=NS(content="В GhoSou нашёл звук «Rain Hit».",tool_calls=[]),
                    finish_reason="stop",
                )],usage=None)
            else:
                raise AssertionError(f"unexpected call {idx}")
            name,args=call
            return NS(choices=[NS(
                message=NS(content="",tool_calls=[NS(
                    id=f"f{idx}",function=NS(name=name,arguments=json.dumps(args,ensure_ascii=False))
                )]),finish_reason="tool_calls"
            )],usage=None)

    async def request(factory,**kwargs):
        result=factory()
        return await result if asyncio.iscoroutine(result) else result
    async def no_premium(uid): return False
    async def fake_search(**kwargs):
        assert kwargs.get("kind")=="sound"
        return {
            "matches":[{"track":{"ID":"s1","Slug":"rain-hit","Title":"Rain Hit","Kind":"sound","Duration":2.4,"ModerationStatus":"published"},"score":20,"reasons":["text:match"]}],
            "total":1,"offset":0,"limit":5,"has_more":False,"next_offset":None,
            "match_mode_used":"all","relaxed_match":False,"facets":{},"summary":{},"kinds":{"sound":1},
        }

    try:
        client=Client()
        ai.get_client=lambda provider:client
        ai._request_with_single_retry=request
        ai.user_has_premium=no_premium
        ai.get_current_chat=lambda uid:"forced-ghosou"
        ai.load_history=lambda *args:[]
        ai.save_history=lambda *args:saved.append(args[2])
        ai.list_files=lambda *args:[]
        ai.read_memory=lambda *args:""
        ai.is_model_available=lambda key:True
        music.search_catalog_page=fake_search
        answer=await ai.ask_ai(
            7654001,"найди звук дождя","groq:gpt-oss-20b","Ты тестовый агент.",12,
            chat_id_override="forced-ghosou",
        )
        assert "Rain Hit" in answer
        assert len(steps)==4
        assert not any(
            m.get("content")=="Вот звук дождя: попробуй Rain FX"
            for history in saved for m in history if m.get("role")=="assistant"
        ),"plain-text hallucination must not become final history"
    finally:
        music.search_catalog_page=original_search
        for name,value in original.items(): setattr(ai,name,value)


async def test_agent_send_marker():
    original = {name: getattr(ai, name) for name in (
        "get_client", "_request_with_single_retry", "user_has_premium",
        "get_current_chat", "load_history", "save_history", "list_files",
        "read_memory", "is_model_available",
    )}
    steps = []
    saved = []

    async def no_premium(uid):
        return False

    class Client:
        def __init__(self):
            self.chat = NS(completions=NS(create=self.create))

        def create(self, **kwargs):
            steps.append(kwargs)
            visible = {t["function"]["name"] for t in kwargs.get("tools", [])}
            idx = len(steps)
            if idx == 1:
                assert "ghosou_send_audio" not in visible
                call = ("get_tool_instructions", {"tool_name": "ghosou_send_audio"})
            elif idx == 2:
                assert "ghosou_send_audio" in visible
                call = ("ghosou_send_audio", {"track_id": PUBLIC_ID})
            else:
                return NS(choices=[NS(
                    message=NS(content="Нашёл — отправляю.", tool_calls=[]),
                    finish_reason="stop",
                )])
            name, args = call
            return NS(choices=[NS(
                message=NS(
                    content="",
                    tool_calls=[NS(
                        id=f"t{idx}",
                        function=NS(name=name, arguments=json.dumps(args)),
                    )],
                ),
                finish_reason="tool_calls",
            )])

    async def request(factory, **kwargs):
        result = factory()
        return await result if asyncio.iscoroutine(result) else result

    try:
        client = Client()
        ai.get_client = lambda provider: client
        ai._request_with_single_retry = request
        ai.user_has_premium = no_premium
        ai.get_current_chat = lambda uid: "1111111111111"
        ai.load_history = lambda *args: []
        ai.save_history = lambda *args: saved.append(args[2])
        ai.list_files = lambda *args: []
        ai.read_memory = lambda *args: ""
        ai.is_model_available = lambda key: True

        answer = await ai.ask_ai(
            7654321,
            "Найди этот трек в GhoSou и пришли мне его",
            "groq:gpt-oss-20b",
            "Ты тестовый агент.",
            12,
        )
        assert "Нашёл — отправляю." in answer
        assert f"GHOSOU_AUDIO_TO_SEND:{PUBLIC_ID}" in answer
        assert len(steps) == 3
    finally:
        for name, value in original.items():
            setattr(ai, name, value)


async def main():
    await test_music_core()
    print("PASS music core: public-only search/get/related/audio resolver")
    await test_advanced_audio_search()
    print("PASS advanced search: sounds/loops/filtering/pagination")
    test_ghosou_request_detector()
    print("PASS detector: explicit music/sound discovery requires GhoSou unless external service is named")
    test_registry()
    print("PASS registry: all GhoSou tools have lazy instructions")
    await test_forced_ghosou_search_after_plain_text()
    print("PASS forced search: text-only hallucination is rejected and real GhoSou search is required")
    await test_agent_send_marker()
    print("PASS agent: GhoSou send is handshake-gated and emits Telegram marker")
    print("ALL GHOSOU TOOL TESTS PASS")


asyncio.run(main())
