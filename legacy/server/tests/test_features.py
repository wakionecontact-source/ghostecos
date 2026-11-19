"""Тесты для фич 1+4 (counter жалоб, reward за подтверждение),
5+6 (статус-лента, mood), 9 (incoming reports), 10 (eternal status)."""


def _make_post(client, u, text="content", nsfw=False):
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": text, "is_nsfw": nsfw})
    return r.json()["post_id"]


# ── Feature 5: лента статусов ────────────────────────────────────────────────

def test_status_feed_includes_self(client, reg_user):
    u = reg_user(username="feed_me")
    client.post("/api/soc/status/set",
                headers={"Authorization": f"Bearer {u['token']}"},
                json={"text": "hi"})
    r = client.get("/api/soc/status/feed",
                   headers={"Authorization": f"Bearer {u['token']}"})
    assert r.status_code == 200
    items = r.json()
    me_items = [x for x in items if x["is_me"]]
    assert len(me_items) == 1
    assert me_items[0]["text"] == "hi"


def test_status_feed_includes_followed(client, reg_user):
    a = reg_user(username="feed_a")
    b = reg_user(username="feed_b")
    client.post("/api/soc/status/set",
                headers={"Authorization": f"Bearer {b['token']}"},
                json={"text": "from b"})
    # a follows b
    r = client.post(f"/api/soc/follow/{b['username']}",
                    headers={"Authorization": f"Bearer {a['token']}"})
    assert r.status_code == 200
    r = client.get("/api/soc/status/feed",
                   headers={"Authorization": f"Bearer {a['token']}"})
    items = r.json()
    bs = [x for x in items if x["username"] == "feed_b"]
    assert len(bs) == 1
    assert bs[0]["text"] == "from b"


# ── Feature 6: mood emoji ───────────────────────────────────────────────────

def test_status_with_mood(client, reg_user):
    u = reg_user(username="mood_u")
    r = client.post("/api/soc/status/set",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "great day", "mood": "joy"})
    assert r.status_code == 200
    assert r.json()["mood"] == "joy"
    # GET /my
    r = client.get("/api/soc/status/my",
                   headers={"Authorization": f"Bearer {u['token']}"})
    assert r.json()["mood"] == "joy"


def test_status_unknown_mood_400(client, reg_user):
    u = reg_user(username="badmood_u")
    r = client.post("/api/soc/status/set",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "x", "mood": "unknown"})
    assert r.status_code == 400


# ── Feature 10: eternal status ──────────────────────────────────────────────

def test_eternal_status_requires_soul(client, reg_user):
    u = reg_user(username="eternal_poor")
    r = client.post("/api/soc/status/eternal",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "forever"})
    # 0 Soul на новом аккаунте → 402
    assert r.status_code == 402


def test_eternal_status_priority_over_daily(client, reg_user):
    """Eternal должен перебивать daily в /status/my."""
    u = reg_user(username="eternal_test")
    # Поставим daily
    client.post("/api/soc/status/set",
                headers={"Authorization": f"Bearer {u['token']}"},
                json={"text": "daily"})
    # Даём Soul через прямой SQL (поскольку нет реального покупательского пути в тестах)
    import sqlite3, os
    con = sqlite3.connect(os.environ["SOCIAL_DB_PATH"])
    con.execute("INSERT OR IGNORE INTO soc_wallets (user_id, gost, soul, prem) VALUES "
                "((SELECT id FROM users WHERE username='eternal_test'), 0, 200, 0)")
    con.execute("UPDATE soc_wallets SET soul=200 "
                "WHERE user_id=(SELECT id FROM users WHERE username='eternal_test')")
    con.commit(); con.close()
    # Eternal
    r = client.post("/api/soc/status/eternal",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "FOREVER", "mood": "fire"})
    assert r.status_code == 200, r.text
    assert r.json()["eternal"] is True
    # /my → возвращает eternal
    r = client.get("/api/soc/status/my",
                   headers={"Authorization": f"Bearer {u['token']}"})
    d = r.json()
    assert d["text"] == "FOREVER"
    assert d["eternal"] is True
    assert d["must_set"] is False
    # DELETE eternal — daily должен снова всплыть
    r = client.delete("/api/soc/status/eternal",
                      headers={"Authorization": f"Bearer {u['token']}"})
    assert r.status_code == 200
    r = client.get("/api/soc/status/my",
                   headers={"Authorization": f"Bearer {u['token']}"})
    d = r.json()
    assert d["text"] == "daily"
    assert d["eternal"] is False


# ── Feature 9: incoming reports за Prem ─────────────────────────────────────

def test_incoming_reports_requires_prem(client, reg_user):
    u = reg_user(username="inc_poor")
    r = client.post("/api/soc/me/reports/incoming",
                    headers={"Authorization": f"Bearer {u['token']}"})
    assert r.status_code == 402


def test_incoming_reports_with_prem(client, reg_user):
    a = reg_user(username="inc_author")
    b = reg_user(username="inc_reporter")
    pid = _make_post(client, a)
    client.post(f"/api/soc/post/{pid}/report",
                headers={"Authorization": f"Bearer {b['token']}"},
                json={"reason": "spam"})
    # Даём автору Prem
    import sqlite3, os
    con = sqlite3.connect(os.environ["SOCIAL_DB_PATH"])
    con.execute("INSERT OR IGNORE INTO soc_wallets (user_id, gost, soul, prem) VALUES "
                "((SELECT id FROM users WHERE username='inc_author'), 0, 0, 50)")
    con.execute("UPDATE soc_wallets SET prem=50 "
                "WHERE user_id=(SELECT id FROM users WHERE username='inc_author')")
    con.commit(); con.close()
    # Запрос
    r = client.post("/api/soc/me/reports/incoming",
                    headers={"Authorization": f"Bearer {a['token']}"})
    assert r.status_code == 200
    d = r.json()
    assert d["spent_prem"] == 10
    assert len(d["reports"]) == 1
    assert d["reports"][0]["username"] == "inc_reporter"
    assert d["reports"][0]["reason"] == "spam"


# ── Feature 1: counter жалоб в overwatch_queue ──────────────────────────────

def test_overwatch_queue_has_reports_breakdown(client, reg_user):
    a = reg_user(username="ow_author")
    pid = _make_post(client, a)
    # 5 жалоб разных причин для автотриггера
    for i, reason in enumerate(["spam", "spam", "harassment", "illegal", "spam"]):
        u = reg_user(username=f"ow_rep{i}")
        client.post(f"/api/soc/post/{pid}/report",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"reason": reason})
    admin = reg_user(username="testadmin")
    r = client.get("/api/soc/mod/overwatch_queue",
                   headers={"Authorization": f"Bearer {admin['token']}"})
    items = r.json()
    target = [it for it in items if it["post_id"] == pid]
    assert target, f"Ожидался overwatch для post_id={pid}"
    rb = target[0]["reports_breakdown"]
    assert rb["total"] == 5
    reasons = {x["reason"]: x["count"] for x in rb["by_reason"]}
    assert reasons.get("spam") == 3
    assert reasons.get("harassment") == 1
    assert reasons.get("illegal") == 1
