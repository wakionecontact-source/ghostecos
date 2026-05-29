"""
GhostChat — обработчики WebSocket-сообщений.

Все типы пакетов, их валидация и логика доставки.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from typing import Any, Optional

import database as db
from ws.manager import manager, _Conn

log = logging.getLogger("gc.ws.handlers")

FREE_EMOJIS = {"❤️","👍","😂","🔥","😮","😢","👏","🎉","💯","😡"}
FREE_MAX_REACTIONS = 1
PREM_MAX_REACTIONS = 3


async def handle_packet(conn: _Conn, raw: str) -> bool:
    """
    Разобрать и обработать один WS-пакет.
    Если пакет зашифрован ({"e":"..."}), расшифровывает сессионным ключом.
    Возвращает False если соединение нужно закрыть.
    """
    try:
        outer = json.loads(raw)
    except Exception:
        return True

    # ── Расшифровать если сессия установлена ──────────────────────────────────
    if "e" in outer and conn.session is not None and conn.session.key is not None:
        from ws.crypto import decrypt_packet
        pkt = decrypt_packet(conn.session.key, outer["e"])
        if pkt is None:
            return True  # Невалидный пакет — игнорируем, не отключаем
    else:
        pkt = outer

    t = pkt.get("type", "")

    # ── Обмен ключами (всегда без шифрования, до auth) ────────────────────────
    if t == "key_exchange":
        return await _handle_key_exchange(conn, pkt)

    # ── Аутентификация ────────────────────────────────────────────────────────
    if t == "auth":
        return await _handle_auth(conn, pkt)

    # После auth_fail или до auth — игнорируем всё
    if not conn.authed:
        await manager.send(conn, {"type": "auth_fail", "reason": "not_authenticated"})
        return False

    manager.update_ping(conn)

    # ── Ping/Pong ─────────────────────────────────────────────────────────────
    if t == "ping":
        return await _handle_ping(conn, pkt)

    # ── Личные сообщения ──────────────────────────────────────────────────────
    elif t == "relay_message":
        await _handle_relay_message(conn, pkt)
    elif t in ("relay_ack", "ack"):   # "ack" — legacy alias
        await _handle_relay_ack(conn, pkt)
    elif t == "relay_seen":
        await _handle_relay_seen(conn, pkt)
    elif t == "relay_delete":
        await _handle_relay_delete(conn, pkt)
    elif t == "relay_edit":
        await _handle_relay_edit(conn, pkt)

    # ── Каналы ───────────────────────────────────────────────────────────────
    elif t == "channel_message":
        await _handle_channel_message(conn, pkt)

    # ── Файлы ────────────────────────────────────────────────────────────────
    elif t == "file_ack":
        await _handle_file_ack(conn, pkt)

    # ── Реакции ──────────────────────────────────────────────────────────────
    elif t == "react":
        await _handle_react(conn, pkt)

    # ── Поддержка ────────────────────────────────────────────────────────────
    elif t == "support_message":
        await _handle_support_message(conn, pkt)
    elif t == "support_reply":
        await _handle_support_reply(conn, pkt)

    # ── Многоустройственная авторизация ───────────────────────────────────────
    elif t == "login_approve":
        await _handle_login_approve(conn, pkt)
    elif t == "login_deny":
        await _handle_login_deny(conn, pkt)
    elif t == "login_block":
        await _handle_login_block(conn, pkt)
    elif t == "code_submit":
        await _handle_code_submit(conn, pkt)

    # ── Статус peer-а ─────────────────────────────────────────────────────────
    elif t == "peer_status_req":
        await _handle_peer_status_req(conn, pkt)

    elif t == "app_ready":
        await _handle_app_ready(conn, pkt)

    elif t == "set_background":
        await _handle_set_background(conn, pkt)

    elif t == "sync_request":
        await _handle_sync_request(conn, pkt)

    return True


# ── Auth ──────────────────────────────────────────────────────────────────────

async def _handle_auth(conn: _Conn, pkt: dict) -> bool:
    from security import decode_token_soft
    token     = pkt.get("token", "")
    device_id = pkt.get("device_id", "")
    app_ver   = pkt.get("app_version", "")

    payload = decode_token_soft(token)
    if not payload:
        await manager.send(conn, {"type": "auth_fail", "reason": "invalid_token"})
        return False

    username = payload.get("sub", "")
    if not username:
        await manager.send(conn, {"type": "auth_fail", "reason": "invalid_token"})
        return False

    # ── Revocation check ─────────────────────────────────────────────────────
    jti = payload.get("jti", "")
    iat = payload.get("iat", 0)
    if jti and await db.is_jti_revoked(jti):
        await manager.send(conn, {"type": "auth_fail", "reason": "token_revoked"})
        return False

    # Проверить что юзер существует
    user = await db.fetchone(
        "SELECT username, is_premium, screen_block, token_min_iat FROM users WHERE username = ?",
        (username,)
    )
    if not user:
        await manager.send(conn, {"type": "auth_fail", "reason": "user_not_found"})
        return False

    # Проверить token_min_iat (массовый logout)
    if iat and iat < (user.get("token_min_iat") or 0):
        await manager.send(conn, {"type": "auth_fail", "reason": "token_invalidated"})
        return False

    # Проверить устройство
    if device_id:
        dev = await db.fetchone(
            "SELECT blocked, permissions FROM device_registry "
            "WHERE username = ? AND device_id = ?",
            (username, device_id)
        )
        if dev and dev["blocked"]:
            await manager.send(conn, {"type": "auth_fail", "reason": "device_blocked"})
            return False

    was_offline = await manager.authenticate(
        conn, username, device_id, app_ver, bool(user["is_premium"])
    )

    # Подтвердить авторизацию
    import config as cfg
    await manager.send(conn, {
        "type":    "auth_ok",
        "username": username,
        "is_premium": bool(user["is_premium"]),
    })

    # Доставить офлайн-сообщения
    await _deliver_offline(conn, username)

    # Уведомить контакты о появлении онлайн
    if was_offline:
        await _notify_contacts_status(username, True)

    return True


async def _handle_key_exchange(conn: _Conn, pkt: dict) -> bool:
    """
    Клиент отправил свой эфемерный X25519 pub-ключ.
    Выводим общий сессионный ключ → все дальнейшие пакеты шифруются AES-256-GCM.
    """
    client_pub_b64 = pkt.get("pub", "")
    if not client_pub_b64 or conn.session is None:
        return True  # Нет сессии — просто игнорируем

    try:
        conn.session.derive(client_pub_b64)
    except Exception as e:
        log.debug(f"key_exchange error: {e}")
        return True  # Невалидный ключ — не отключаем

    # Подтвердить — ответ будет уже зашифрован
    await manager.send(conn, {"type": "key_exchange_ok"})
    return True


async def _deliver_offline(conn: _Conn, username: str):
    """Доставить накопленные офлайн-сообщения и события."""
    msgs = await db.fetchall(
        "SELECT * FROM messages WHERE to_username = ? AND delivered = 0",
        (username,)
    )
    for m in msgs:
        pkt = {
            "type":             "relay_message",
            "from":             m["from_username"],
            "to":               username,
            "enc_body":         m["enc_body"],
            "msg_id":           m["msg_id"],
            "sent_at":          m["sent_at"],
            "forwarded_from":   m["forwarded_from"],
            "reply_to_msg_id":  m["reply_to_msg_id"],
        }
        ok = await manager.send(conn, pkt)
        if ok:
            # Немедленно удаляем после доставки — метаданные (from/to) не задерживаются в БД
            await db.execute("DELETE FROM messages WHERE msg_id = ?", (m["msg_id"],))

    # Офлайн-события (удаление/редактирование)
    events = await db.fetchall(
        "SELECT * FROM offline_events WHERE to_username = ?", (username,)
    )
    for e in events:
        ev_pkt = {"type": e["type"], "msg_id": e["msg_id"]}
        if e["enc_body"]:
            ev_pkt["enc_body"] = e["enc_body"]
        await manager.send(conn, ev_pkt)

    if events:
        await db.execute(
            "DELETE FROM offline_events WHERE to_username = ?", (username,)
        )


async def _notify_contacts_status(username: str, online: bool):
    """Уведомить контакты об изменении статуса. Метаданные не сохраняются."""
    contacts = await db.fetchall(
        "SELECT user_b AS other FROM contacts WHERE user_a = ? "
        "UNION SELECT user_a AS other FROM contacts WHERE user_b = ?",
        (username, username)
    )
    pkt_type = "peer_online" if online else "peer_offline"
    for c in contacts:
        other = c["other"]
        if manager.is_online(other):
            await manager.send_to_user(other, {"type": pkt_type, "username": username})


# ── Ping ──────────────────────────────────────────────────────────────────────

async def _handle_ping(conn: _Conn, pkt: dict) -> bool:
    import config as cfg
    app_ver = pkt.get("app_version", conn.app_version)
    if app_ver:
        conn.app_version = app_ver

    pong: dict = {"type": "pong"}
    if app_ver and app_ver != cfg.LATEST_VERSION:
        pong["update_available"] = True
        pong["latest_version"]   = cfg.LATEST_VERSION

    # Статус онлайн-пользователей (только если запрошен)
    requested = pkt.get("request_online", [])
    if requested:
        pong["online"] = [u for u in requested if manager.is_online(u)]

    await manager.send(conn, pong)
    return True


# ── Личные сообщения ──────────────────────────────────────────────────────────

async def _handle_relay_message(conn: _Conn, pkt: dict):
    # from берём ТОЛЬКО из аутентифицированной сессии — поле "from" в пакете игнорируется
    # (Sealed Sender: from зашифрован в WS-сессии, сервер видит его только в RAM)
    to       = pkt.get("to", "") or pkt.get("to_username", "")
    enc_body = pkt.get("enc_body", "") or pkt.get("body", "")  # body — fallback для совместимости
    msg_id   = pkt.get("msg_id") or str(uuid.uuid4())
    sent_at  = pkt.get("sent_at") or pkt.get("ts") or db.now_ms()
    fwd_from = pkt.get("forwarded_from", "")
    reply_to = pkt.get("reply_to_msg_id", "")

    if not to or not enc_body:
        return

    # Проверить что адресат существует
    target = await db.fetchone("SELECT username FROM users WHERE username = ?", (to,))
    if not target:
        return

    out_pkt = {
        "type":            "relay_message",
        "from":            conn.username,
        "to":              to,
        "enc_body":        enc_body,
        "msg_id":          msg_id,
        "sent_at":         sent_at,
        "forwarded_from":  fwd_from,
        "reply_to_msg_id": reply_to,
    }

    if manager.is_online(to):
        sent = await manager.send_to_user(to, out_pkt)
        if sent:
            # Онлайн — сохранять не нужно (метаданные маршрутизации в RAM)
            return

    # Офлайн — сохранить зашифрованное тело (контент не читаем сервером)
    try:
        await db.execute(
            "INSERT OR IGNORE INTO messages "
            "(from_username, to_username, enc_body, msg_id, sent_at, forwarded_from, reply_to_msg_id) "
            "VALUES (?,?,?,?,?,?,?)",
            (conn.username, to, enc_body, msg_id, sent_at, fwd_from, reply_to)
        )
    except Exception:
        pass


async def _handle_relay_ack(conn: _Conn, pkt: dict):
    msg_id = pkt.get("msg_id", "")
    if not msg_id:
        return

    # SECURITY (H4): подтвердить доставку может ТОЛЬКО получатель сообщения.
    # Иначе чужой по msg_id подделает квитанцию и спровоцирует удаление сообщения.
    msg = await db.fetchone(
        "SELECT from_username FROM messages WHERE msg_id = ? AND to_username = ?",
        (msg_id, conn.username)
    )
    if msg:
        await db.execute(
            "UPDATE messages SET delivered = 1 WHERE msg_id = ? AND to_username = ?",
            (msg_id, conn.username)
        )
        from_user = msg["from_username"]
        if manager.is_online(from_user):
            await manager.send_to_user(from_user, {"type": "relay_ack", "msg_id": msg_id})


async def _handle_relay_seen(conn: _Conn, pkt: dict):
    msg_ids = pkt.get("msg_ids", [])
    if not msg_ids:
        return

    senders: dict[str, list[str]] = {}
    for mid in msg_ids:
        # SECURITY (H4): «прочитано» может слать только получатель сообщения.
        msg = await db.fetchone(
            "SELECT from_username FROM messages WHERE msg_id = ? AND to_username = ?",
            (mid, conn.username)
        )
        if msg:
            senders.setdefault(msg["from_username"], []).append(mid)

    for sender, ids in senders.items():
        if manager.is_online(sender):
            await manager.send_to_user(sender, {
                "type": "relay_seen", "msg_ids": ids, "by": conn.username
            })


async def _handle_relay_delete(conn: _Conn, pkt: dict):
    msg_id = pkt.get("msg_id", "")
    to     = pkt.get("to", "")
    if not msg_id or not to:
        return

    out = {"type": "relay_delete", "msg_id": msg_id, "by": conn.username}
    if manager.is_online(to):
        await manager.send_to_user(to, out)
    else:
        await db.execute(
            "INSERT INTO offline_events (to_username, type, msg_id, enc_body, created_at) "
            "VALUES (?,?,?,?,?)",
            (to, "relay_delete", msg_id, "", db.now())
        )

    # Пнуть все другие устройства отправителя
    await manager.send_to_user(conn.username, out, exclude_conn=conn)


async def _handle_relay_edit(conn: _Conn, pkt: dict):
    msg_id   = pkt.get("msg_id", "")
    to       = pkt.get("to", "")
    enc_body = pkt.get("enc_body", "")
    if not msg_id or not to or not enc_body:
        return

    out = {"type": "relay_edit", "msg_id": msg_id, "enc_body": enc_body}
    if manager.is_online(to):
        await manager.send_to_user(to, out)
    else:
        await db.execute(
            "INSERT INTO offline_events (to_username, type, msg_id, enc_body, created_at) "
            "VALUES (?,?,?,?,?)",
            (to, "relay_edit", msg_id, enc_body, db.now())
        )

    await manager.send_to_user(conn.username, out, exclude_conn=conn)


# ── Каналы ────────────────────────────────────────────────────────────────────

async def _handle_channel_message(conn: _Conn, pkt: dict):
    channel_id = pkt.get("channel_id", "")
    body       = pkt.get("body", "")
    msg_id     = pkt.get("msg_id") or str(uuid.uuid4())
    sent_at    = pkt.get("sent_at") or db.now_ms()
    reply_to   = pkt.get("reply_to_msg_id", "")
    # reply_body и reply_from НЕ принимаются с клиента — клиент резолвит сам из локального DB
    # Это защищает от утечки plaintext цитат в зашифрованных каналах

    if not channel_id or not body:
        return

    # Проверить членство
    member = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, conn.username)
    )
    if not member:
        return

    # Только admin/owner может постить в channel (не group)
    ch = await db.fetchone("SELECT type FROM channels WHERE id = ?", (channel_id,))
    if ch and ch["type"] == "channel" and member["role"] not in ("admin", "owner"):
        return

    # display_name берём из users (не доверяем клиенту)
    user = await db.fetchone("SELECT display_name FROM users WHERE username = ?", (conn.username,))
    dn   = user["display_name"] if user else conn.username

    # Сохранить — reply_body/reply_from не хранятся
    try:
        await db.execute(
            "INSERT OR IGNORE INTO channel_messages "
            "(channel_id, from_username, display_name, body, msg_id, sent_at, reply_to_msg_id) "
            "VALUES (?,?,?,?,?,?,?)",
            (channel_id, conn.username, dn, body, msg_id, sent_at, reply_to)
        )
    except Exception:
        return

    out = {
        "type":            "channel_message",
        "channel_id":      channel_id,
        "from_username":   conn.username,
        "display_name":    dn,
        "body":            body,
        "msg_id":          msg_id,
        "sent_at":         sent_at,
        "reply_to_msg_id": reply_to,
        # reply_body/reply_from НЕ включаются — клиент резолвит из локальной БД
        "is_premium":      conn.is_premium,
    }

    # Разослать всем онлайн-членам
    members = await db.fetchall(
        "SELECT username FROM channel_members WHERE channel_id = ?", (channel_id,)
    )
    await manager.broadcast(
        [m["username"] for m in members], out, exclude_user=conn.username
    )


# ── Файлы ────────────────────────────────────────────────────────────────────

async def _handle_file_ack(conn: _Conn, pkt: dict):
    file_id = pkt.get("file_id", "")
    if not file_id:
        return
    import os
    row = await db.fetchone("SELECT file_path FROM pending_files WHERE file_id = ?", (file_id,))
    if row:
        try:
            os.remove(row["file_path"])
        except OSError:
            pass
        await db.execute("DELETE FROM pending_files WHERE file_id = ?", (file_id,))


# ── Реакции ───────────────────────────────────────────────────────────────────

async def _handle_react(conn: _Conn, pkt: dict):
    msg_id = pkt.get("msg_id", "")
    emoji  = pkt.get("emoji", "")
    if not msg_id or not emoji:
        return

    # Проверить что emoji разрешён
    if not conn.is_premium and emoji not in FREE_EMOJIS:
        return

    # Проверить лимит реакций на это сообщение от этого пользователя
    max_r = PREM_MAX_REACTIONS if conn.is_premium else FREE_MAX_REACTIONS
    current = await db.fetchall(
        "SELECT emoji FROM reactions WHERE msg_id = ? AND username = ?",
        (msg_id, conn.username)
    )
    my_emojis = {r["emoji"] for r in current}

    if emoji in my_emojis:
        # Убрать реакцию
        await db.execute(
            "DELETE FROM reactions WHERE msg_id = ? AND username = ? AND emoji = ?",
            (msg_id, emoji, conn.username)
        )
    else:
        if len(my_emojis) >= max_r:
            return
        try:
            await db.execute(
                "INSERT INTO reactions (msg_id, username, emoji, created_at) VALUES (?,?,?,?)",
                (msg_id, conn.username, emoji, db.now())
            )
        except Exception:
            return

    # Получить обновлённые реакции и разослать
    rows = await db.fetchall(
        "SELECT emoji, username FROM reactions WHERE msg_id = ?", (msg_id,)
    )
    agg: dict[str, list[str]] = {}
    for r in rows:
        agg.setdefault(r["emoji"], []).append(r["username"])
    reactions = [{"emoji": e, "users": u, "count": len(u)} for e, u in agg.items()]

    out = {"type": "reactions_update", "msg_id": msg_id, "reactions": reactions}

    # Найти участников чата/канала и разослать
    # Попробовать канал
    ch_msg = await db.fetchone(
        "SELECT channel_id FROM channel_messages WHERE msg_id = ?", (msg_id,)
    )
    if ch_msg:
        members = await db.fetchall(
            "SELECT username FROM channel_members WHERE channel_id = ?",
            (ch_msg["channel_id"],)
        )
        await manager.broadcast([m["username"] for m in members], out)
    else:
        # DM — отправить обоим
        dm = await db.fetchone(
            "SELECT from_username, to_username FROM messages WHERE msg_id = ?", (msg_id,)
        )
        if dm:
            await manager.send_to_user(dm["from_username"], out)
            await manager.send_to_user(dm["to_username"], out)


# ── Поддержка ─────────────────────────────────────────────────────────────────

async def _handle_support_message(conn: _Conn, pkt: dict):
    body   = pkt.get("body", "").strip()
    msg_id = pkt.get("msg_id") or str(uuid.uuid4())
    if not body:
        return

    await db.execute(
        "INSERT OR IGNORE INTO support_messages "
        "(from_username, to_username, body, msg_id, sent_at, direction, created_at) "
        "VALUES (?,?,?,?,?,?,?)",
        (conn.username, "support", body, msg_id, db.now_ms(), "in", db.now())
    )

    # Уведомить онлайн-поддержку
    import config as cfg
    if cfg.SUPPORT_PASSWORD and manager.is_online("__support__"):
        await manager.send_to_user("__support__", {
            "type":          "support_incoming",
            "from_username": conn.username,
            "body":          body,
            "msg_id":        msg_id,
        })


async def _handle_support_reply(conn: _Conn, pkt: dict):
    import config as cfg
    # Только поддержка может отвечать
    if not cfg.SUPPORT_PASSWORD:
        return

    to     = pkt.get("to", "")
    body   = pkt.get("body", "").strip()
    msg_id = pkt.get("msg_id") or str(uuid.uuid4())
    if not to or not body:
        return

    await db.execute(
        "INSERT OR IGNORE INTO support_messages "
        "(from_username, to_username, body, msg_id, sent_at, direction, created_at) "
        "VALUES (?,?,?,?,?,?,?)",
        ("support", to, body, msg_id, db.now_ms(), "out", db.now())
    )

    if manager.is_online(to):
        await manager.send_to_user(to, {
            "type":   "support_reply",
            "body":   body,
            "msg_id": msg_id,
        })


# ── Multi-device login ────────────────────────────────────────────────────────

async def _handle_login_approve(conn: _Conn, pkt: dict):
    """Доверенное (аутентифицированное) устройство одобряет вход нового.
    SECURITY (C2/C3): сервер САМ генерирует 6-значный код, хранит только его хэш
    и показывает код ТОЛЬКО этому доверенному устройству. Фаза success наступает
    лишь когда новое устройство введёт верный код (см. /code_verify)."""
    import secrets as _secrets
    import security as _sec
    req_id = pkt.get("request_id", "")
    req = await db.fetchone(
        "SELECT * FROM pending_logins WHERE request_id = ? AND username = ?",
        (req_id, conn.username)
    )
    if not req or req["phase"] != "pending":
        return
    if req["expires_at"] < db.now():
        return

    code = f"{_secrets.randbelow(1_000_000):06d}"
    # Код живёт 3 минуты с момента одобрения; счётчик попыток сбрасывается.
    await db.execute(
        "UPDATE pending_logins SET phase='code_phase', code_hash=?, attempt_count=0, "
        "expires_at=? WHERE request_id=?",
        (_sec.hash_code(code), db.now() + 180, req_id)
    )
    # Показать код ТОЛЬКО доверенному устройству — пользователь введёт его на новом.
    await manager.send_to_user(conn.username, {
        "type":        "login_code_display",
        "request_id":  req_id,
        "code":        code,
        "device_name": req["device_name"],
    })


async def _handle_login_deny(conn: _Conn, pkt: dict):
    req_id = pkt.get("request_id", "")
    req = await db.fetchone(
        "SELECT * FROM pending_logins WHERE request_id = ? AND username = ?",
        (req_id, conn.username)
    )
    if not req:
        return
    await db.execute(
        "UPDATE pending_logins SET phase = 'denied' WHERE request_id = ?", (req_id,)
    )


async def _handle_login_block(conn: _Conn, pkt: dict):
    req_id = pkt.get("request_id", "")
    req = await db.fetchone(
        "SELECT * FROM pending_logins WHERE request_id = ? AND username = ?",
        (req_id, conn.username)
    )
    if not req:
        return
    await db.execute(
        "UPDATE pending_logins SET phase = 'blocked' WHERE request_id = ?", (req_id,)
    )
    # Заблокировать device_id
    await db.execute(
        "UPDATE device_registry SET blocked = 1 "
        "WHERE username = ? AND device_id = ?",
        (conn.username, req["device_id"])
    )


async def _handle_code_submit(conn: _Conn, pkt: dict):
    # DEPRECATED (C2/C3): код больше НЕ присылается доверенным устройством.
    # Сервер сам генерирует код при одобрении (_handle_login_approve), а новое
    # устройство вводит его через POST /api/login_request/{id}/code_verify.
    return


# ── Прочее ───────────────────────────────────────────────────────────────────

async def _handle_peer_status_req(conn: _Conn, pkt: dict):
    usernames = pkt.get("usernames", [])
    if not usernames:
        return
    statuses = {u: manager.is_online(u) for u in usernames[:50]}
    await manager.send(conn, {"type": "peer_statuses", "statuses": statuses})


async def _handle_app_ready(conn: _Conn, pkt: dict):
    """Клиент сигнализирует о готовности — доставить ожидающие файлы."""
    files = await db.fetchall(
        "SELECT * FROM pending_files WHERE to_username = ? AND status = 'uploaded'",
        (conn.username,)
    )
    for f in files:
        await manager.send(conn, {
            "type":      "file_incoming",
            "file_id":   f["file_id"],
            "from":      f["from_username"],
            "filename":  f["filename"],
            "mime_type": f["mime_type"],
            "file_size": f["file_size"],
            "enc_key":   f["enc_key"],
            "msg_id":    f["msg_id"],
        })


async def _handle_set_background(conn: _Conn, pkt: dict):
    peer    = pkt.get("peer", "")
    bg_data = pkt.get("background", "")
    if not peer:
        return
    # Прокинуть на другое устройство (если есть)
    await manager.send_to_user(conn.username, {
        "type":       "set_background",
        "peer":       peer,
        "background": bg_data,
    }, exclude_conn=conn)


async def _handle_sync_request(conn: _Conn, pkt: dict):
    """Синхронизировать список ожидающих логинов."""
    reqs = await db.fetchall(
        "SELECT request_id, device_id, device_name, phase, created_at, expires_at "
        "FROM pending_logins WHERE username = ? AND phase = 'pending'",
        (conn.username,)
    )
    await manager.send(conn, {
        "type":    "sync_summary",
        "pending": reqs,
    })
