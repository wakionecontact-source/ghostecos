"""Firebase Cloud Messaging — отправка push на устройства.
Generic notification (без plaintext) — Google НЕ видит контент.
"""
import os
import logging
from typing import List

log = logging.getLogger('gc.fcm')

_initialized = False
_messaging = None
_SA_PATH = "/opt/ghostchat/firebase-service-account.json"


def _init():
    global _initialized, _messaging
    if _initialized:
        return _messaging is not None
    _initialized = True
    if not os.path.exists(_SA_PATH):
        log.warning("FCM service-account отсутствует: %s", _SA_PATH)
        return False
    try:
        import firebase_admin
        from firebase_admin import credentials, messaging
        if not firebase_admin._apps:
            cred = credentials.Certificate(_SA_PATH)
            firebase_admin.initialize_app(cred)
        _messaging = messaging
        log.info("FCM Admin SDK инициализирован")
        return True
    except Exception as e:
        log.error("FCM init fail: %s", e)
        return False


def send_wake_push(tokens: List[str], body: str = "Новое сообщение",
                   title: str = "GhostChat") -> int:
    """Push без plaintext. Возвращает число успешных отправок."""
    if not tokens or not _init():
        return 0
    sent = 0
    for tok in tokens:
        try:
            msg = _messaging.Message(
                token=tok,
                notification=_messaging.Notification(title=title, body=body),
                android=_messaging.AndroidConfig(
                    priority="high",
                    notification=_messaging.AndroidNotification(
                        channel_id="messages",
                        default_sound=True,
                        default_vibrate_timings=True,
                    ),
                ),
                data={"type": "wake"},
            )
            _messaging.send(msg)
            sent += 1
        except Exception as e:
            # Токены FCM — как пароль: даже префикс не должен попасть в логи.
            log.warning("FCM send failed: %s", str(e)[:120])
    return sent


def get_tokens_for_user(conn, user_id: int) -> List[str]:
    try:
        rows = conn.execute(
            "SELECT token FROM fcm_tokens WHERE user_id=? ORDER BY updated DESC",
            (user_id,)
        ).fetchall()
        return [r["token"] for r in rows]
    except Exception:
        return []
