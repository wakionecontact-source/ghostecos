"""Тесты жалоб + триггер автоперемодерации."""


def _make_post(client, u, text="content"):
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": text})
    return r.json()["post_id"]


def test_report_post_basic(client, reg_user):
    a = reg_user(username="rauthor1")
    b = reg_user(username="rreporter1")
    pid = _make_post(client, a)
    r = client.post(f"/api/soc/post/{pid}/report",
                    headers={"Authorization": f"Bearer {b['token']}"},
                    json={"reason": "spam"})
    assert r.status_code == 200


def test_report_own_post_403(client, reg_user):
    a = reg_user(username="rauthor2")
    pid = _make_post(client, a)
    r = client.post(f"/api/soc/post/{pid}/report",
                    headers={"Authorization": f"Bearer {a['token']}"},
                    json={"reason": "spam"})
    assert r.status_code == 403


def test_report_duplicate_409(client, reg_user):
    a = reg_user(username="rauthor3")
    b = reg_user(username="rreporter3")
    pid = _make_post(client, a)
    r1 = client.post(f"/api/soc/post/{pid}/report",
                     headers={"Authorization": f"Bearer {b['token']}"},
                     json={"reason": "spam"})
    r2 = client.post(f"/api/soc/post/{pid}/report",
                     headers={"Authorization": f"Bearer {b['token']}"},
                     json={"reason": "harassment"})
    assert r1.status_code == 200
    assert r2.status_code == 409


def test_report_invalid_reason_400(client, reg_user):
    a = reg_user(username="rauthor4")
    b = reg_user(username="rreporter4")
    pid = _make_post(client, a)
    r = client.post(f"/api/soc/post/{pid}/report",
                    headers={"Authorization": f"Bearer {b['token']}"},
                    json={"reason": "totally_made_up"})
    assert r.status_code == 400


def test_report_undo(client, reg_user):
    a = reg_user(username="rauthor5")
    b = reg_user(username="rreporter5")
    pid = _make_post(client, a)
    client.post(f"/api/soc/post/{pid}/report",
                headers={"Authorization": f"Bearer {b['token']}"},
                json={"reason": "spam"})
    r = client.delete(f"/api/soc/post/{pid}/report",
                      headers={"Authorization": f"Bearer {b['token']}"})
    assert r.status_code == 200
    # Можно теперь снова пожаловаться
    r = client.post(f"/api/soc/post/{pid}/report",
                    headers={"Authorization": f"Bearer {b['token']}"},
                    json={"reason": "other"})
    assert r.status_code == 200


def test_reports_count_admin_only(client, reg_user):
    a = reg_user(username="rauthor6")
    plain = reg_user(username="rplain6")
    pid = _make_post(client, a)
    r = client.get(f"/api/soc/post/{pid}/reports/count",
                   headers={"Authorization": f"Bearer {plain['token']}"})
    assert r.status_code == 403
    # Админу можно
    admin = reg_user(username="testadmin")
    r = client.get(f"/api/soc/post/{pid}/reports/count",
                   headers={"Authorization": f"Bearer {admin['token']}"})
    assert r.status_code == 200
    assert r.json()["total"] == 0


def test_auto_overwatch_trigger_after_5_reports(client, reg_user):
    """5 жалоб за час должны создать system_reports overwatch."""
    a = reg_user(username="auth_trigger")
    pid = _make_post(client, a)
    # 5 разных репортеров
    for i in range(5):
        u = reg_user(username=f"trigreporter{i}")
        r = client.post(f"/api/soc/post/{pid}/report",
                        headers={"Authorization": f"Bearer {u['token']}"},
                        json={"reason": "spam"})
        assert r.status_code == 200
    # Проверка через админа: ловим counter ≥5
    admin = reg_user(username="testadmin")
    r = client.get(f"/api/soc/post/{pid}/reports/count",
                   headers={"Authorization": f"Bearer {admin['token']}"})
    assert r.json()["total"] == 5
    # И есть открытый overwatch
    r = client.get("/api/soc/mod/overwatch_queue",
                   headers={"Authorization": f"Bearer {admin['token']}"})
    assert r.status_code == 200
    items = r.json()
    has_auto = any(it.get("kind") == "system_reports" and it.get("post_id") == pid for it in items)
    assert has_auto, f"Expected system_reports overwatch for post {pid}, got: {items}"
