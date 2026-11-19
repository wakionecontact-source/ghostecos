"""Общая проверка identity в роутах Social и Chat."""
import pytest
from fastapi import HTTPException


def test_social_chat_and_bots_use_one_validator(client, reg_user):
    from ecos_core.identity import db
    from ecos_core.client import auth_member as core_auth_member
    from social_router import auth_member as social_auth
    from chat_router import auth_member as chat_auth
    from bot_api import auth_member as bot_auth

    assert social_auth is core_auth_member
    assert chat_auth is core_auth_member
    assert bot_auth is core_auth_member

    registered = reg_user(username="core_identity_test")
    user = core_auth_member("Bearer " + registered["token"])
    assert user["username"] == registered["username"]
    from bot_api import _require_app_device
    # Регистрация выдаёт токен устройства и связывает с ним сессию.
    assert user["is_app_device"] is True
    _require_app_device(user)

    # Сессия без устройства по-прежнему не допускается к API только для приложений.
    from ecos_core.sessions import create_session
    with db() as connection:
        unbound = create_session(connection, registered["id"])
    unbound_user = core_auth_member("Bearer " + unbound["session_token"])
    assert unbound_user["is_app_device"] is False
    with pytest.raises(HTTPException) as forbidden:
        _require_app_device(unbound_user)
    assert forbidden.value.status_code == 403

    # В проде таблица уже есть, а в тестовом окружении её создаём явно.
    import device_auth
    with db() as connection:
        device_auth.init_devices_table(connection)

    response = client.post("/api/soc/login", json={
        "username": registered["username"],
        "password": registered["password"],
        "device_id": "isolated-device-1",
        "device_name": "Core identity test",
        "platform": "web",
    })
    assert response.status_code == 200, response.text
    device_token = response.json()["token"]
    device_user = core_auth_member("Bearer " + device_token)
    assert device_user["username"] == registered["username"]
    assert device_user["is_app_device"] is True
    _require_app_device(device_user)

    with pytest.raises(HTTPException) as invalid:
        core_auth_member("Bearer invalid-value")
    assert invalid.value.status_code == 401
    from ecos_core.sessions import device_for_token
    with db() as connection:
        device = device_for_token(connection, device_token, registered["id"])
        assert device is not None
        connection.execute("UPDATE user_devices SET is_blocked=1 WHERE id=?", (device["id"],))
    with pytest.raises(HTTPException) as blocked:
        core_auth_member("Bearer " + device_token)
    assert blocked.value.status_code == 401
