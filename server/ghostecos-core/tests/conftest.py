"""pytest fixtures для social/chat. Используем временную БД per-test-session.

Запуск: cd server && python -m pytest tests/ -v

В CI/локально нужно:
  pip install pytest httpx fastapi pydantic argon2-cffi pyjwt pillow
  (всё это уже есть в social_requirements.txt)
"""
import os
import sys
import tempfile
import pytest

# Test modules are imported during collection, before session fixtures run.
# Pin every database path now so module-level DB constants cannot point to production.
_TEST_DIR = tempfile.TemporaryDirectory(prefix="ghostecos-pytest-")
_TEST_DB_PATH = os.path.join(_TEST_DIR.name, "test_social.db")
os.environ["SOCIAL_DB_PATH"] = _TEST_DB_PATH
os.environ["GHOSTCHAT_DB_PATH"] = os.path.join(_TEST_DIR.name, "test_chat.db")
os.environ["SOCIAL_MEDIA_DIR"] = os.path.join(_TEST_DIR.name, "media")
os.environ["GC_JWT_SECRET"] = "test_jwt_secret_for_tests_only_64chars_long_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
os.environ["GE_OWNER_USERNAME"] = "testadmin"
os.environ["DISABLE_RATE_LIMIT"] = "1"

# Подкладываем server/social и server/backchat в sys.path, чтобы импортировались модули
_HERE = os.path.dirname(os.path.abspath(__file__))
_SERVER = os.path.dirname(_HERE)
for sub in ("social", "backchat"):
    p = os.path.join(_SERVER, sub)
    if p not in sys.path:
        sys.path.insert(0, p)


@pytest.fixture(scope="session", autouse=True)
def _isolate_dbs():
    """Создать схему в базе, закреплённой до импорта тестовых модулей."""
    db_path = _TEST_DB_PATH
    assert db_path.startswith(_TEST_DIR.name + os.sep)
    from ecos_core import identity
    assert identity.DB == db_path, "Core database was imported before test isolation"

    # Pre-init: users таблица создаётся в backchat/db_remote.py, который social_router
    # НЕ импортирует. В проде она уже есть. Для тестов создаём минимум руками.
    import sqlite3
    con = sqlite3.connect(db_path)
    con.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            display_name TEXT,
            password_hash TEXT,
            argon2_hash TEXT,
            x25519_pub TEXT,
            encrypted_private_key TEXT,
            key_salt TEXT,
            in_ghostchat INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """)
    con.commit()
    con.close()
    yield


@pytest.fixture
def client():
    """FastAPI TestClient на инстансе social_app (включает social_router и chat_router).
    Каждый тест получает свежий клиент; БД переиспользуется в рамках сессии."""
    from fastapi.testclient import TestClient
    import importlib, social_app
    # Перезагружаем модуль чтобы init() БД сработал
    importlib.reload(social_app)
    return TestClient(social_app.app)


@pytest.fixture
def reg_user(client):
    """Фабрика регистрации тестовых юзеров. Возвращает {token, username, display_name}."""
    _counter = {"n": 0}

    def _make(username=None, password="testpass123", display_name=None, age=True):
        _counter["n"] += 1
        un = (username or f"testuser{_counter['n']}").lower()
        dn = display_name or f"Test {_counter['n']}"
        r = client.post(
            "/api/soc/register",
            json={
                "username": un, "display_name": dn,
                "password": password, "age_18_confirm": age,
            },
        )
        # Если юзер уже есть (предыдущий тест в той же сессии) — логинимся
        if r.status_code == 409:
            r = client.post("/api/soc/login", json={"username": un, "password": password})
            if r.status_code != 200:
                raise AssertionError(f"login fallback failed: {r.status_code} {r.text}")
            d = r.json()
            return {"token": d["token"], "username": un, "display_name": d.get("display_name", dn),
                    "password": password, "id": d.get("id")}
        if r.status_code != 200:
            raise AssertionError(f"register failed: {r.status_code} {r.text}")
        d = r.json()
        return {
            "token": d["token"], "username": un, "display_name": dn,
            "password": password, "id": d.get("id"),
        }
    return _make


def _auth(token):
    return {"Authorization": f"Bearer {token}"}

@pytest.fixture(scope="session", autouse=True)
def _route_service_auth_to_core(_isolate_dbs):
    """Exercise product-service auth through the signed Core API in tests."""
    import httpx
    from fastapi.testclient import TestClient
    import ecos_core.client as core_client
    from ecos_core_app import app as core_app

    secret = "test-only-ghostecos-internal-key-0123456789abcdef"
    os.environ["GE_SERVICE_NAME"] = "ghostsocial"
    os.environ["GE_INTERNAL_KEY_GHOSTSOCIAL"] = secret
    os.environ["GE_CORE_URL"] = "http://core.test"
    core_server = TestClient(core_app)

    def forward(request):
        response = core_server.request(
            request.method, request.url.raw_path.decode("ascii"),
            content=request.content, headers=dict(request.headers),
        )
        return httpx.Response(
            response.status_code, headers=dict(response.headers),
            content=response.content, request=request,
        )

    service_client = httpx.Client(transport=httpx.MockTransport(forward))
    core_client._HTTP = service_client
    yield
    service_client.close()
    core_server.close()
