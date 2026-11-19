"""Мост со старых путей: страницы уходят на v2, API остаются рабочими."""
import sqlite3

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from ecos_core import legacy_redirect, service_auth_v2, service_sso


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("GE_SSO_DB_PATH", str(tmp_path / "sso.sqlite3"))
    monkeypatch.setenv("GE_SSO_ISSUER", "https://ghostecos.duckdns.org")
    monkeypatch.setattr(service_sso, "_rate_limit", lambda *args, **kwargs: None)
    monkeypatch.setattr(service_auth_v2, "_rate_limit", lambda *args, **kwargs: None)
    database = tmp_path / "identity.sqlite3"
    monkeypatch.setenv("SOCIAL_DB_PATH", str(database))
    connection = sqlite3.connect(database)
    connection.execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, display_name TEXT, "
        "avatar_url TEXT, password_hash TEXT, private_key TEXT, is_admin INTEGER)")
    connection.execute("CREATE TABLE soc_tokens (token TEXT PRIMARY KEY, user_id INTEGER)")
    connection.commit()
    connection.close()
    app = FastAPI()
    service_sso.install(app)
    service_auth_v2.install(app)
    legacy_redirect.install(app)
    with TestClient(app) as http:
        yield http


@pytest.mark.parametrize("page", ["/auth/login.html", "/auth/register.html", "/auth/sso-demo.html"])
def test_legacy_page_redirects_to_v2(client, page):
    response = client.get(page, follow_redirects=False)
    assert response.status_code == 308
    assert response.headers["location"] == "/v2/auth"


def test_legacy_page_keeps_query(client):
    response = client.get("/auth/login.html?return=%2Fv2%2Fchat",
                          follow_redirects=False)
    assert response.headers["location"] == "/v2/auth?return=%2Fv2%2Fchat"


def test_legacy_api_still_answers_and_points_to_successor(client):
    response = client.get("/api/sso/userinfo")
    assert response.status_code == 401
    assert response.headers["deprecation"] == "true"
    assert "successor-version" in response.headers["link"]
    assert "/api/v2/auth/me" in response.headers["link"]


def test_legacy_entrance_keeps_working(client):
    response = client.post("/api/sso/entrance", json={})
    assert response.status_code in {401, 403, 404, 422}
    assert "successor-version" in response.headers.get("link", "")
