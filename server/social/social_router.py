from fastapi import APIRouter, Header, HTTPException, Query, UploadFile, File, Request, WebSocket, WebSocketDisconnect
import asyncio
from typing import Optional, List
from pydantic import BaseModel
from collections import defaultdict
import sqlite3, secrets, os, uuid, json, io, hashlib, hmac, re, time

router = APIRouter(prefix="/api/soc", tags=["GhostSocial"])
DB = '/opt/ghostchat/ghostchat.db'
MEDIA_DIR = "/var/www/ghostsocial/media"
os.makedirs(MEDIA_DIR, exist_ok=True)

ALLOWED_IMAGE = {"jpg","jpeg","png","gif","webp"}
ALLOWED_VIDEO = {"mp4","webm","mov"}
ALLOWED_AUDIO = {"mp3","wav","ogg","m4a"}
MAX_IMAGE = 30 * 1024 * 1024
MAX_VIDEO = 50 * 1024 * 1024
MAX_AUDIO = 15 * 1024 * 1024

_NAME_MIN, _NAME_MAX = 2, 100
_USER_MIN, _USER_MAX, _USER_TOTAL = 3, 60, 64
_PASS_MIN, _PASS_MAX = 8, 150
_RESERVED = {
    'admin','administrator','root','system','ghost','ghostchat','ghostsocial',
    'ghostecos','support','help','mod','moderator','staff','team','official',
    'api','www','mail','test',
}

# ── Pydantic models ────────────────────────────────────────────────────────────

class RegisterBody(BaseModel):
    username: str
    display_name: str
    password: str

class LoginBody(BaseModel):
    username: str
    password: str

class PollBody(BaseModel):
    question: str
    options: List[str]
    is_quiz: bool = False
    correct_idx: Optional[int] = None

class PostBody(BaseModel):
    text: str
    media: Optional[List[dict]] = None
    poll: Optional[PollBody] = None

class VoteBody(BaseModel):
    option_idx: int

class EditPostBody(BaseModel):
    text: Optional[str] = None
    media: Optional[List[dict]] = None  # медиа можно только УБРАТЬ (сократить список), не добавить

class CommentBody(BaseModel):
    text: str

class EditProfileBody(BaseModel):
    display_name: Optional[str] = None
    username: Optional[str] = None
    new_password: Optional[str] = None
    old_password: Optional[str] = None

class ReactBody(BaseModel):
    emoji: Optional[str] = None  # null = снять реакцию

# ── Validation (mirrors Dart validators.dart) ──────────────────────────────────

def _ctrl(cp: int) -> bool:
    return cp < 0x20 or (0x7F <= cp <= 0x9F)

def _invis(cp: int) -> bool:
    return (cp in (0x00AD, 0x034F, 0xFEFF, 0x180E) or
            0x200B <= cp <= 0x200F or 0x202A <= cp <= 0x202E or
            0x2060 <= cp <= 0x2064 or 0x2066 <= cp <= 0x206F or
            0xFFF9 <= cp <= 0xFFFB)

def _comb(cp: int) -> bool:
    return (0x0300 <= cp <= 0x036F or 0x0483 <= cp <= 0x0489 or
            0x0591 <= cp <= 0x05BD or
            cp in (0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7) or
            0x0610 <= cp <= 0x061A or 0x064B <= cp <= 0x065F or cp == 0x0670 or
            0x06D6 <= cp <= 0x06DC or 0x06DF <= cp <= 0x06E4 or
            0x06E7 <= cp <= 0x06E8 or 0x06EA <= cp <= 0x06ED or
            0x0900 <= cp <= 0x0903 or 0x093A <= cp <= 0x094F or
            0x0951 <= cp <= 0x0957 or 0x1AB0 <= cp <= 0x1AFF or
            0x1DC0 <= cp <= 0x1DFF or 0x20D0 <= cp <= 0x20FF or
            0xFE20 <= cp <= 0xFE2F)

def _emoji(cp: int) -> bool:
    return (0x1F000 <= cp <= 0x1FAFF or 0x2600 <= cp <= 0x27BF or
            0x2300 <= cp <= 0x23FF or 0x2B00 <= cp <= 0x2BFF or
            0x1F1E6 <= cp <= 0x1F1FF or 0xFE00 <= cp <= 0xFE0F or
            cp in (0x200D, 0x20E3, 0x203C, 0x2049, 0x2122, 0x2139) or
            0x2194 <= cp <= 0x21AA or 0x231A <= cp <= 0x231B or
            cp == 0x24C2 or 0x25AA <= cp <= 0x25FE or 0x2934 <= cp <= 0x2935)

def _val_name(raw: str) -> str:
    v = raw.strip()
    runes = list(v)
    if not runes:
        raise HTTPException(422, "Введите имя")
    if len(runes) < _NAME_MIN:
        raise HTTPException(422, f"Имя слишком короткое (минимум {_NAME_MIN})")
    if len(runes) > _NAME_MAX:
        raise HTTPException(422, f"Имя слишком длинное (максимум {_NAME_MAX})")
    for c in runes:
        cp = ord(c)
        if _ctrl(cp) or _invis(cp) or _comb(cp):
            raise HTTPException(422, "Имя содержит недопустимые символы")
    return v

def _val_username(raw: str) -> str:
    v = raw.strip().lower()
    if not v:
        raise HTTPException(422, "Введите имя пользователя")
    if len(v) > _USER_TOTAL:
        raise HTTPException(422, "Имя пользователя слишком длинное")
    for c in v:
        cp = ord(c)
        if not (0x61 <= cp <= 0x7A or 0x30 <= cp <= 0x39 or cp in (0x5F, 0x2E)):
            raise HTTPException(422, "Только латиница, цифры, _ и точка")
    nd = v.replace('.', '')
    if len(nd) < _USER_MIN:
        raise HTTPException(422, f"Минимум {_USER_MIN} символа (точки не в счёт)")
    if len(nd) > _USER_MAX:
        raise HTTPException(422, f"Максимум {_USER_MAX} символов (точки не в счёт)")
    if v in _RESERVED:
        raise HTTPException(422, "Это имя пользователя зарезервировано")
    return v

def _val_password(v: str) -> str:
    runes = list(v)
    if not runes:
        raise HTTPException(422, "Введите пароль")
    if len(runes) < _PASS_MIN:
        raise HTTPException(422, f"Пароль слишком короткий (минимум {_PASS_MIN} символов)")
    if len(runes) > _PASS_MAX:
        raise HTTPException(422, f"Пароль слишком длинный (максимум {_PASS_MAX} символов)")
    for c in runes:
        cp = ord(c)
        if _ctrl(cp):
            raise HTTPException(422, "Пароль содержит запрещённые символы")
        if _emoji(cp):
            raise HTTPException(422, "Пароль не должен содержать эмодзи")
    return v

# ── Password hashing ─────────────────────────────────────────────────────────
# Canonical: argon2 (общий с GhostChat).
# Legacy: pbkdf2 (старые GhostSocial-юзеры) — при первом успешном логине апгрейдим в argon2.

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHashError

_ph = PasswordHasher()
_PBKDF2_ITERS = 260_000
# Константный argon2-хэш заведомо-непроверяемой строки. Нужен чтобы /login
# тратил одинаковое время для существующих и несуществующих пользователей.
_DUMMY_ARGON2_HASH = _ph.hash("__non-existent-user-dummy__")

def hash_argon2(password: str) -> str:
    return _ph.hash(password)

def verify_argon2(password: str, stored: str) -> bool:
    try:
        return _ph.verify(stored, password)
    except (VerifyMismatchError, InvalidHashError, Exception):
        return False

def verify_pbkdf2(password: str, stored: str) -> bool:
    try:
        salt_hex, key_hex = stored.split(':', 1)
        key = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), bytes.fromhex(salt_hex), _PBKDF2_ITERS)
        return hmac.compare_digest(key.hex(), key_hex)
    except Exception:
        return False

# ── SQLite helpers ─────────────────────────────────────────────────────────────

def _ci_contains(haystack, needle):
    if haystack is None or needle is None:
        return 0
    return 1 if needle.lower() in haystack.lower() else 0

def db():
    # timeout=5: вместо мгновенного 'database is locked' ждём до 5 сек на освобождение
    c = sqlite3.connect(DB, timeout=5.0)
    c.row_factory = sqlite3.Row
    c.create_function("ci_contains", 2, _ci_contains, deterministic=True)
    # WAL: readers не блокируют writers, writer не блокирует readers. Безопасно вызывать
    # каждый коннект — pragma persists между сессиями (один раз пропишется и хватит).
    try:
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA synchronous=NORMAL")
        c.execute("PRAGMA busy_timeout=5000")
    except Exception:
        pass
    return c

# ── WebSocket hub ──────────────────────────────────────────────────────────────
# Простой in-memory pub/sub. Один процесс uvicorn — подойдёт.
# Если когда-нибудь запустим несколько воркеров — придётся вынести в Redis.

class _WSHub:
    def __init__(self):
        # user_id -> set[WebSocket]. 0 = аноним/гость (тоже получают broadcast)
        self._by_uid: dict = defaultdict(set)
        self._lock = asyncio.Lock()

    async def register(self, uid: int, ws: WebSocket):
        async with self._lock:
            self._by_uid[uid].add(ws)

    async def unregister(self, uid: int, ws: WebSocket):
        async with self._lock:
            self._by_uid[uid].discard(ws)
            if not self._by_uid[uid]:
                self._by_uid.pop(uid, None)

    async def _send(self, ws: WebSocket, payload: dict):
        try:
            await ws.send_json(payload)
        except Exception:
            # битый сокет — выкинем его при следующем reconnect
            pass

    # Типы событий, которые гости могут получать через broadcast (публичные)
    _PUBLIC_BROADCAST = {"post.new", "post.edit", "post.delete", "post.react",
                          "post.comment", "post.vote", "presence"}

    def broadcast(self, ev_type: str, data: dict):
        """Послать событие подключённым. Приватные (notif.*, chat.*) — только залогиненным.
        Гости (uid=0) получают только публичные события из _PUBLIC_BROADCAST."""
        try:
            loop = asyncio.get_event_loop()
        except RuntimeError:
            return
        payload = {"type": ev_type, "data": data}
        is_public = ev_type in self._PUBLIC_BROADCAST
        for uid, sockets in list(self._by_uid.items()):
            if uid == 0 and not is_public:
                continue  # гостям приватные события не показываем
            for ws in list(sockets):
                loop.create_task(self._send(ws, payload))

    def send_to(self, uid: int, ev_type: str, data: dict):
        """Послать конкретному юзеру (всем его открытым вкладкам/устройствам)."""
        if uid is None or uid <= 0:
            return
        try:
            loop = asyncio.get_event_loop()
        except RuntimeError:
            return
        payload = {"type": ev_type, "data": data}
        for ws in list(self._by_uid.get(uid, ())):
            loop.create_task(self._send(ws, payload))

ws_hub = _WSHub()

# Лимиты на коннекты — защита от DoS
_WS_MAX_PER_USER = 10        # 10 вкладок/устройств на юзера — достаточно
_WS_MAX_PER_IP_GUEST = 20    # гостям с одного IP не больше 20 коннектов

@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: str = Query("")):
    """Real-time канал. Аутентификация через ?token=. Гость тоже допускается.
    Принимает входящие события клиента (JSON): typing, presence.
    """
    uid = 0
    username = None
    if token and not token.startswith("guest_"):
        c = db()
        row = c.execute(
            "SELECT u.id, u.username FROM soc_tokens t JOIN users u ON u.id=t.user_id WHERE t.token=?",
            (token,)
        ).fetchone()
        c.close()
        if row:
            uid = row["id"]
            username = row["username"]
    # Cap: не более N открытых коннектов на одного юзера/IP.
    # Гостям отдельный лимит по IP (uid=0 у всех гостей).
    if uid > 0 and len(ws_hub._by_uid.get(uid, set())) >= _WS_MAX_PER_USER:
        await websocket.close(code=1008)  # policy violation
        return
    if uid == 0 and len(ws_hub._by_uid.get(0, set())) >= _WS_MAX_PER_IP_GUEST:
        # У нас нет per-IP fan-out для гостей, но общий cap на стол гостей хватит.
        await websocket.close(code=1008)
        return
    await websocket.accept()
    await ws_hub.register(uid, websocket)
    await websocket.send_json({"type": "hello", "data": {"uid": uid}})
    # Сообщить другим подключённым что я онлайн
    if uid > 0 and username:
        ws_hub.broadcast("presence", {"username": username, "online": True})
    try:
        while True:
            # Тайм-аут на receive: если клиент молчит больше 90с — отвал.
            # Клиент должен слать ping каждые ~25с. 90с = 3 ping-интервала.
            try:
                msg = await asyncio.wait_for(websocket.receive_text(), timeout=90)
            except asyncio.TimeoutError:
                break  # зомби-коннект → отключаем
            if msg == 'ping':
                await websocket.send_text('pong')
                continue
            if not msg or msg[0] != '{':
                continue
            try:
                ev = json.loads(msg)
            except Exception:
                continue
            t = ev.get("type")
            data = ev.get("data") or {}
            # Клиент сообщает что печатает в чат с username
            if t == "chat.typing" and username:
                to_user = (data.get("to") or "").lower()
                if not to_user:
                    continue
                c = db()
                peer = c.execute("SELECT id FROM users WHERE username=?", (to_user,)).fetchone()
                c.close()
                if peer:
                    ws_hub.send_to(peer["id"], "chat.typing", {
                        "from_username": username,
                        "is_typing": bool(data.get("is_typing", True)),
                    })
            # Клиент сообщает кому он "присутствует" — запрос статуса
            elif t == "presence.ask":
                target = (data.get("username") or "").lower()
                if not target:
                    continue
                c = db()
                peer = c.execute("SELECT id FROM users WHERE username=?", (target,)).fetchone()
                c.close()
                online = bool(peer and peer["id"] in ws_hub._by_uid and ws_hub._by_uid[peer["id"]])
                await websocket.send_json({"type": "presence", "data": {"username": target, "online": online}})
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        await ws_hub.unregister(uid, websocket)
        # Если последнее соединение для юзера закрылось — broadcast offline
        if uid > 0 and username and uid not in ws_hub._by_uid:
            ws_hub.broadcast("presence", {"username": username, "online": False})


def init():
    """Создаём только соцсетевые таблицы; users + soc_tokens мигрированы вручную."""
    c = db()
    c.executescript('''
        CREATE TABLE IF NOT EXISTS soc_posts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            content TEXT NOT NULL,
            media TEXT DEFAULT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_reactions (
            post_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            emoji TEXT NOT NULL DEFAULT 'heart',
            PRIMARY KEY (post_id, user_id),
            FOREIGN KEY (post_id) REFERENCES soc_posts(id),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_comments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            post_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            text TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (post_id) REFERENCES soc_posts(id),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_follows (
            follower_id INTEGER NOT NULL,
            followee_id INTEGER NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (follower_id, followee_id),
            FOREIGN KEY (follower_id) REFERENCES users(id),
            FOREIGN KEY (followee_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_notifications (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            actor_id INTEGER NOT NULL,
            type TEXT NOT NULL,
            post_id INTEGER NOT NULL DEFAULT 0,
            preview TEXT DEFAULT NULL,
            is_read INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id),
            FOREIGN KEY (actor_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_tokens (
            user_id INTEGER PRIMARY KEY,
            token TEXT UNIQUE NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_polls (
            post_id INTEGER PRIMARY KEY,
            question TEXT NOT NULL,
            options TEXT NOT NULL,
            is_quiz INTEGER NOT NULL DEFAULT 0,
            correct_idx INTEGER,
            FOREIGN KEY (post_id) REFERENCES soc_posts(id)
        );
        CREATE TABLE IF NOT EXISTS soc_poll_votes (
            post_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            option_idx INTEGER NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (post_id, user_id),
            FOREIGN KEY (post_id) REFERENCES soc_posts(id),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_link_cache (
            url TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            fetched_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chat_dm (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sender_id INTEGER NOT NULL,
            receiver_id INTEGER NOT NULL,
            text TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (sender_id) REFERENCES users(id),
            FOREIGN KEY (receiver_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS chat_contacts (
            owner_id INTEGER NOT NULL,
            contact_id INTEGER NOT NULL,
            added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (owner_id, contact_id),
            FOREIGN KEY (owner_id) REFERENCES users(id),
            FOREIGN KEY (contact_id) REFERENCES users(id)
        );

        -- ══════ ЭКОНОМИКА: Soul + NFT ══════════════════════════════════════════
        -- Состояние сезона (одна строка с активным сезоном)
        CREATE TABLE IF NOT EXISTS soc_economy_state (
            season_id INTEGER PRIMARY KEY,
            cap INTEGER NOT NULL,
            system_balance INTEGER NOT NULL,
            burned_total INTEGER NOT NULL DEFAULT 0,
            is_active INTEGER NOT NULL DEFAULT 1,
            started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            closed_at TIMESTAMP
        );
        -- Аудит-лог Soul-транзакций (как soc_wallet_tx для gost, но для soul)
        -- source: 'admin_emit'|'transfer_in'|'transfer_out'|'fee'|'nft_buy'|'nft_sell'|'nft_fee'|'burn'
        CREATE TABLE IF NOT EXISTS soc_soul_tx (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            delta INTEGER NOT NULL,
            source TEXT NOT NULL,
            counter_user_id INTEGER NOT NULL DEFAULT 0,
            ref_type TEXT NOT NULL DEFAULT '',
            ref_id INTEGER NOT NULL DEFAULT 0,
            note TEXT DEFAULT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_soul_tx_user ON soc_soul_tx(user_id, id DESC);
        -- Каталог NFT (типы — например 'ghost', 'moon', ...)
        CREATE TABLE IF NOT EXISTS soc_nft_catalog (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            slug TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            description TEXT DEFAULT '',
            rarity TEXT NOT NULL DEFAULT 'common',
            max_supply INTEGER NOT NULL,
            creator_id INTEGER NOT NULL,
            start_price_soul INTEGER NOT NULL DEFAULT 5,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (creator_id) REFERENCES users(id)
        );
        -- Экземпляры NFT (instance)
        CREATE TABLE IF NOT EXISTS soc_nfts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            catalog_id INTEGER NOT NULL,
            serial INTEGER NOT NULL,
            owner_id INTEGER NOT NULL,
            minted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE (catalog_id, serial),
            FOREIGN KEY (catalog_id) REFERENCES soc_nft_catalog(id),
            FOREIGN KEY (owner_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_nfts_owner ON soc_nfts(owner_id);
        CREATE INDEX IF NOT EXISTS idx_soc_nfts_catalog ON soc_nfts(catalog_id);
        -- Маркет: один NFT может быть выставлен только 1 раз
        CREATE TABLE IF NOT EXISTS soc_nft_listings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nft_id INTEGER NOT NULL UNIQUE,
            seller_id INTEGER NOT NULL,
            price_soul INTEGER NOT NULL,
            listed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (nft_id) REFERENCES soc_nfts(id),
            FOREIGN KEY (seller_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_nft_listings_catalog ON soc_nft_listings(price_soul);

        CREATE INDEX IF NOT EXISTS idx_soc_posts_created ON soc_posts(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_soc_posts_user ON soc_posts(user_id);
        CREATE INDEX IF NOT EXISTS idx_soc_reactions_post ON soc_reactions(post_id);
        CREATE INDEX IF NOT EXISTS idx_soc_comments_post ON soc_comments(post_id);
        CREATE INDEX IF NOT EXISTS idx_soc_follows_followee ON soc_follows(followee_id);
        CREATE INDEX IF NOT EXISTS idx_soc_notif_user ON soc_notifications(user_id, id DESC);
        CREATE INDEX IF NOT EXISTS idx_soc_tokens_token ON soc_tokens(token);
        CREATE INDEX IF NOT EXISTS idx_chat_dm_recv ON chat_dm(receiver_id, id);

        -- ── Экономика GhostEcos: кошелёк (3 валюты) ──
        -- gost — non-transferable, бесплатная (активность)
        -- soul — основная, transferable, cap-эмиссия (пока 0 у всех — выкуп NFT не реализован)
        -- prem — премиальная (украшения), пока 0
        CREATE TABLE IF NOT EXISTS soc_wallets (
            user_id INTEGER PRIMARY KEY,
            gost INTEGER NOT NULL DEFAULT 0,
            soul INTEGER NOT NULL DEFAULT 0,
            prem INTEGER NOT NULL DEFAULT 0,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        -- Audit log + дедуп источников начисления.
        -- source = 'register'|'daily'|'post'|'react'|'comment'|'follow'|'spend'|'admin'|...
        -- actor_id — кто триггернул (например юзер который лайкнул); 0 если система
        -- ref_type/ref_id — на что ссылается (например 'post'/123); ref_id=0 если не применимо
        CREATE TABLE IF NOT EXISTS soc_wallet_tx (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            currency TEXT NOT NULL,
            delta INTEGER NOT NULL,
            source TEXT NOT NULL,
            actor_id INTEGER NOT NULL DEFAULT 0,
            ref_type TEXT NOT NULL DEFAULT '',
            ref_id INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        -- Дедуп: одна пара (получатель, источник, актор, ref) даёт начисление только ОДИН раз
        CREATE UNIQUE INDEX IF NOT EXISTS uq_soc_wallet_tx_dedup
            ON soc_wallet_tx(user_id, source, actor_id, ref_type, ref_id)
            WHERE source IN ('react','comment','follow','post','register');
        CREATE INDEX IF NOT EXISTS idx_soc_wallet_tx_user ON soc_wallet_tx(user_id, id DESC);
        CREATE INDEX IF NOT EXISTS idx_soc_wallet_tx_day ON soc_wallet_tx(user_id, source, created_at);
    ''')
    # Добавляем колонку is_official в users (для системного юзера GhostEcos с галочкой)
    try:
        c.execute("ALTER TABLE users ADD COLUMN is_official INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError:
        pass  # уже есть
    c.commit()
    c.close()

# ── Bootstrap: системный юзер GhostEcos, NFT-каталог, сезон 1 ─────────────────

# Стартовый каталог NFT — те же что в UI /bank/ + 100 экз каждого
_NFT_SEED = [
    {"slug":"ghost",   "name":"Призрак",  "rarity":"common", "price":5,
     "desc":"Символ экосистемы GhostEcos — призрак, плавающий в эфире."},
    {"slug":"moon",    "name":"Луна",     "rarity":"common", "price":5,
     "desc":"Лунный диск с пульсирующим свечением."},
    {"slug":"star",    "name":"Звезда",   "rarity":"rare",   "price":15,
     "desc":"Медленно вращающаяся пятиконечная звезда."},
    {"slug":"flame",   "name":"Пламя",    "rarity":"common", "price":5,
     "desc":"Колеблющееся пламя — энергия эфира."},
    {"slug":"heart",   "name":"Сердце",   "rarity":"common", "price":5,
     "desc":"Бьющееся сердце GhostEcos."},
    {"slug":"bolt",    "name":"Молния",   "rarity":"rare",   "price":15,
     "desc":"Молния с периодическими вспышками."},
    {"slug":"crystal", "name":"Кристалл", "rarity":"legend", "price":50,
     "desc":"Переливающийся кристалл — легендарная редкость."},
    {"slug":"eye",     "name":"Око",      "rarity":"rare",   "price":15,
     "desc":"Всевидящее око — следит за вами."},
    {"slug":"key",     "name":"Ключ",     "rarity":"rare",   "price":15,
     "desc":"Скелетный ключ — открывает то, что скрыто."},
    {"slug":"crown",   "name":"Корона",   "rarity":"legend", "price":50,
     "desc":"Корона избранных — три камня."},
]
SEASON_CAP = 100_000
GHOSTECOS_USERNAME = 'ghostecos'

def bootstrap_economy():
    """Идемпотентный сидинг: системный юзер, сезон 1, NFT-каталог + 100 экз каждого + листинги."""
    c = db()
    # 1) Системный юзер @ghostecos с is_official=1
    sys_row = c.execute("SELECT id FROM users WHERE username=?", (GHOSTECOS_USERNAME,)).fetchone()
    if not sys_row:
        sys_pwd = secrets.token_hex(48)  # никто никогда не залогинится — random
        try:
            c.execute(
                "INSERT INTO users (username, display_name, argon2_hash, in_ghostchat, is_official) VALUES (?,?,?,0,1)",
                (GHOSTECOS_USERNAME, 'GhostEcos', hash_argon2(sys_pwd)),
            )
            c.commit()
        except sqlite3.IntegrityError:
            pass
        sys_row = c.execute("SELECT id FROM users WHERE username=?", (GHOSTECOS_USERNAME,)).fetchone()
    else:
        # Уже есть — но мог быть создан без флага. Гарантируем флаг.
        c.execute("UPDATE users SET is_official=1, display_name='GhostEcos' WHERE username=?", (GHOSTECOS_USERNAME,))
        c.commit()
    sys_uid = sys_row['id']
    # Wallet для системного юзера (для удобства; balance Soul у него не считается — он "печатает")
    c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (sys_uid,))
    c.commit()

    # 2) Сезон 1
    season = c.execute("SELECT * FROM soc_economy_state WHERE season_id=1").fetchone()
    if not season:
        c.execute(
            "INSERT INTO soc_economy_state (season_id, cap, system_balance, is_active) VALUES (1, ?, ?, 1)",
            (SEASON_CAP, SEASON_CAP),
        )
        c.commit()
        print(f"[economy] season 1 started: cap={SEASON_CAP} system_balance={SEASON_CAP}")

    # 3) NFT-каталог + минт 100 экз каждого NFT + выставление на маркет
    catalog_count = c.execute("SELECT COUNT(*) as c FROM soc_nft_catalog").fetchone()['c']
    if catalog_count == 0:
        for nft in _NFT_SEED:
            c.execute(
                "INSERT INTO soc_nft_catalog (slug, name, description, rarity, max_supply, creator_id, start_price_soul) "
                "VALUES (?,?,?,?,100,?,?)",
                (nft['slug'], nft['name'], nft['desc'], nft['rarity'], sys_uid, nft['price']),
            )
            cat_id = c.execute("SELECT last_insert_rowid() as id").fetchone()['id']
            # Минтим 100 экз
            for serial in range(1, 101):
                c.execute(
                    "INSERT INTO soc_nfts (catalog_id, serial, owner_id) VALUES (?,?,?)",
                    (cat_id, serial, sys_uid),
                )
                nft_id = c.execute("SELECT last_insert_rowid() as id").fetchone()['id']
                # Выставляем на маркет по стартовой цене (немного варьируем по серийному номеру: первые — дороже)
                # serial 1-10 → +50%, 11-30 → +20%, остальные — base price
                price = nft['price']
                if serial <= 10: price = int(nft['price'] * 1.5)
                elif serial <= 30: price = int(nft['price'] * 1.2)
                c.execute(
                    "INSERT INTO soc_nft_listings (nft_id, seller_id, price_soul) VALUES (?,?,?)",
                    (nft_id, sys_uid, price),
                )
            print(f"[economy] minted {nft['name']} x100 (catalog #{cat_id})")
        c.commit()
    c.close()

init()
bootstrap_economy()

# ── Auth middleware ─────────────────────────────────────────────────────────────

def auth(authorization: Optional[str]) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = authorization.split(" ", 1)[1]
    # Гостевой токен — не лежит в БД, формат `guest_<hex>`
    if token.startswith("guest_") and len(token) > 16:
        return {"id": 0, "username": "__guest__", "display_name": "Гость", "token": token, "is_guest": True}
    c = db()
    row = c.execute(
        "SELECT u.* FROM users u JOIN soc_tokens t ON t.user_id = u.id WHERE t.token = ?",
        (token,),
    ).fetchone()
    c.close()
    if not row:
        raise HTTPException(401, "Invalid token")
    u = dict(row)
    u["is_guest"] = False
    u["token"] = token
    return u

def require_member(user: dict):
    """Эндпоинт требует полноценного аккаунта (не гостя)."""
    if user.get("is_guest"):
        raise HTTPException(403, "Войдите или зарегистрируйтесь, чтобы продолжить")

def auth_member(authorization: Optional[str]) -> dict:
    user = auth(authorization)
    require_member(user)
    return user

# ── Post/profile helpers ───────────────────────────────────────────────────────

def fmt_post(row: dict, user_id: int, reactions: Optional[dict] = None, am_following: bool = False) -> dict:
    media_list = []
    if row.get("media"):
        try:
            media_list = json.loads(row["media"])
        except Exception:
            pass
    return {
        "id": row["id"],
        "content": row["content"],
        "created_at": row["created_at"],
        "edited_at": row.get("edited_at"),
        "user_id": row["user_id"],
        "username": row["username"],
        "display_name": row["display_name"],
        "reactions": reactions or {"counts": {}, "your_emoji": None, "total": 0},
        "comments_count": row["comments_count"],
        "media": media_list,
        "am_following": am_following,
    }

def get_user_stats(c, user_id: int) -> dict:
    posts_count = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_posts WHERE user_id=?", (user_id,)
    ).fetchone()["cnt"]
    likes_received = c.execute("""
        SELECT COUNT(*) as cnt FROM soc_reactions l
        JOIN soc_posts p ON l.post_id=p.id WHERE p.user_id=?
    """, (user_id,)).fetchone()["cnt"]
    likes_given = c.execute("""
        SELECT COUNT(*) as cnt FROM soc_reactions l
        JOIN soc_posts p ON l.post_id=p.id
        WHERE l.user_id=? AND p.user_id!=?
    """, (user_id, user_id)).fetchone()["cnt"]
    followers = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_follows WHERE followee_id=?", (user_id,)
    ).fetchone()["cnt"]
    following = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_follows WHERE follower_id=?", (user_id,)
    ).fetchone()["cnt"]
    return {
        "posts_count": posts_count,
        "likes_received": likes_received,
        "likes_given": likes_given,
        "followers_count": followers,
        "following_count": following,
    }

# ── Media validation (anti stored-XSS) ──────────────────────────────────────────

import re
_MEDIA_URL_RE = re.compile(r'^/social/media/[A-Za-z0-9._-]+$')

def _val_media(media: Optional[List[dict]]) -> Optional[List[dict]]:
    """Media must reference our own uploaded files. Reject arbitrary URLs —
    they end up inside HTML attributes on the client and could carry script."""
    if not media:
        return None
    if len(media) > 5:
        raise HTTPException(400, "Максимум 5 медиафайлов")
    clean = []
    for m in media:
        if not isinstance(m, dict):
            raise HTTPException(400, "Некорректное медиа")
        url = m.get("url", "")
        ftype = m.get("type", "")
        if ftype not in ("image", "video", "audio"):
            raise HTTPException(400, "Некорректный тип медиа")
        if not isinstance(url, str) or not _MEDIA_URL_RE.match(url):
            raise HTTPException(400, "Некорректный URL медиа")
        name = m.get("name", "")
        if not isinstance(name, str):
            name = ""
        clean.append({"url": url, "type": ftype, "name": name[:200]})
    return clean

# ── Notifications ───────────────────────────────────────────────────────────────

def _add_notif(c, recipient_id: int, actor_id: int, ntype: str, post_id: int = 0, preview: Optional[str] = None):
    if recipient_id == actor_id:
        return  # don't notify yourself
    c.execute(
        "INSERT INTO soc_notifications (user_id, actor_id, type, post_id, preview) VALUES (?,?,?,?,?)",
        (recipient_id, actor_id, ntype, post_id, preview),
    )
    # Real-time пинг адресату — клиент покажет бейдж сразу
    try:
        ws_hub.send_to(recipient_id, "notif.new", {"type": ntype})
    except Exception:
        pass

# ── Rate limit (in-memory, per IP) ──────────────────────────────────────────────

_rl_buckets: dict = defaultdict(list)

def _client_ip(request: Request) -> str:
    # nginx ставит X-Forwarded-For; берём первый IP цепочки
    fwd = request.headers.get('x-forwarded-for', '')
    if fwd:
        return fwd.split(',')[0].strip()
    return request.client.host if request.client else 'unknown'

def _rate_limit(key: str, limit: int, window: int):
    now = time.time()
    arr = _rl_buckets[key] = [t for t in _rl_buckets[key] if now - t < window]
    if len(arr) >= limit:
        raise HTTPException(429, "Слишком много попыток, попробуйте позже")
    arr.append(now)

# ── Hashtags & mentions parsing ─────────────────────────────────────────────────

# Хэштеги: латиница/кириллица/цифры/_, 1..30 символов после #
_TAG_RE = re.compile(r'#([0-9A-Za-zА-Яа-яЁё_]{1,30})', re.UNICODE)
# Упоминания: ровно тот же набор что и валидный username (a-z, 0-9, _, .)
_MENTION_RE = re.compile(r'(?<![A-Za-z0-9_.])@([a-z0-9._]{3,64})')

def _extract_tags(text: str) -> list:
    seen = set()
    out = []
    for m in _TAG_RE.findall(text or ''):
        low = m.lower()
        if low not in seen:
            seen.add(low)
            out.append(low)
    return out[:10]  # ограничим 10 уникальных тегов на пост

def _extract_mentions(text: str) -> list:
    seen = set()
    out = []
    for m in _MENTION_RE.findall(text or ''):
        low = m.lower()
        if low not in seen:
            seen.add(low)
            out.append(low)
    return out[:10]

# ── Reactions aggregation ─────────────────────────────────────────────────────

# Допустимые эмодзи-коды (хранятся в БД как короткие имена, фронт мапит на символ)
ALLOWED_EMOJI = {'heart', 'fire', 'laugh', 'sad', 'clap', 'eyes'}

def _post_reactions(c, post_id: int, user_id: int) -> dict:
    """Возвращает { 'heart': 5, 'fire': 2 } и какую реакцию поставил юзер."""
    rows = c.execute(
        "SELECT emoji, COUNT(*) as cnt FROM soc_reactions WHERE post_id=? GROUP BY emoji",
        (post_id,)
    ).fetchall()
    counts = {r["emoji"]: r["cnt"] for r in rows}
    you = c.execute(
        "SELECT emoji FROM soc_reactions WHERE post_id=? AND user_id=?",
        (post_id, user_id)
    ).fetchone()
    return {"counts": counts, "your_emoji": you["emoji"] if you else None, "total": sum(counts.values())}

# ── Auth endpoints ─────────────────────────────────────────────────────────────

@router.post("/register")
def register(body: RegisterBody, request: Request):
    # 5 регистраций с одного IP в час — отбиваем спам-аккаунты
    _rate_limit(f"reg:{_client_ip(request)}", limit=5, window=3600)
    username = _val_username(body.username)
    display_name = _val_name(body.display_name)
    _val_password(body.password)
    argon2 = hash_argon2(body.password)
    token = secrets.token_hex(32)
    c = db()
    try:
        c.execute(
            "INSERT INTO users (username, display_name, argon2_hash, in_ghostchat) VALUES (?,?,?,0)",
            (username, display_name, argon2),
        )
        uid = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
        c.execute("INSERT INTO soc_tokens (user_id, token) VALUES (?,?)", (uid, token))
        c.commit()
    except sqlite3.IntegrityError:
        c.close()
        raise HTTPException(409, "Имя пользователя уже занято")
    finally:
        c.close()
    # Welcome bonus: 100 gost. UNIQUE-индекс не даст продублировать при повторном регистрате (теоретически невозможно — username уникален, но на всякий)
    try: award_gost(uid, 'register')
    except Exception: pass  # не блокируем регистрацию из-за wallet-сбоя
    return {"id": uid, "username": username, "display_name": display_name, "token": token}

@router.post("/guest")
def guest_login(request: Request):
    """Гостевой токен — read-only доступ, без записи в БД."""
    # 20 гостевых сессий с IP в час — защита от бессмысленного флуда
    _rate_limit(f"guest:{_client_ip(request)}", limit=20, window=3600)
    return {
        "id": 0,
        "username": "__guest__",
        "display_name": "Гость",
        "token": "guest_" + secrets.token_hex(24),
        "is_guest": True,
    }

@router.post("/login")
def login(body: LoginBody, request: Request):
    # 15 неудачных попыток входа с одного IP за 10 минут — защита от перебора
    _rate_limit(f"login:{_client_ip(request)}", limit=15, window=600)
    username = body.username.strip().lower()
    if not username:
        raise HTTPException(422, "Введите имя пользователя")
    c = db()
    user = c.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    if not user:
        c.close()
        # Защита от user enumeration через тайминг: выполняем argon2-проверку
        # с фиктивным хэшем (одинаковый константный хэш, всегда не пройдёт),
        # чтобы время ответа было идентично "юзер существует + неверный пароль".
        verify_argon2(body.password, _DUMMY_ARGON2_HASH)
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    u = dict(user)
    ok = False
    # Сначала argon2 (канонический), потом legacy pbkdf2 с авто-апгрейдом
    if u.get("argon2_hash") and verify_argon2(body.password, u["argon2_hash"]):
        ok = True
    elif u.get("pbkdf2_hash") and verify_pbkdf2(body.password, u["pbkdf2_hash"]):
        ok = True
        # Прозрачный апгрейд хэша
        new_hash = hash_argon2(body.password)
        c.execute("UPDATE users SET argon2_hash=?, pbkdf2_hash=NULL WHERE id=?", (new_hash, u["id"]))
        c.commit()
    if not ok:
        c.close()
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    # Выдаём (или переиспользуем) соц-токен
    tok_row = c.execute("SELECT token FROM soc_tokens WHERE user_id=?", (u["id"],)).fetchone()
    if tok_row:
        token = tok_row["token"]
    else:
        token = secrets.token_hex(32)
        c.execute("INSERT INTO soc_tokens (user_id, token) VALUES (?,?)", (u["id"], token))
        c.commit()
    c.close()
    return {"id": u["id"], "username": u["username"], "display_name": u["display_name"], "token": token}

# ── Media upload ───────────────────────────────────────────────────────────────

@router.post("/upload")
async def upload_media(request: Request, file: UploadFile = File(...), authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    # Защита от спама файлами: 60 загрузок в час с аккаунта
    _rate_limit(f"upload:{user['id']}", limit=60, window=3600)
    ext = file.filename.rsplit(".", 1)[-1].lower() if "." in file.filename else ""
    mime = file.content_type or ""
    mime_ext = {
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png",
        "image/gif": "gif", "image/webp": "webp",
        "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov",
        "video/3gpp": "mp4", "video/x-msvideo": "mp4",
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/wav": "wav",
        "audio/ogg": "ogg", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "mp3",
    }.get(mime, "")
    if not ext or ext not in (ALLOWED_IMAGE | ALLOWED_VIDEO | ALLOWED_AUDIO):
        ext = mime_ext
    if ext in ALLOWED_IMAGE:
        ftype, max_size = "image", MAX_IMAGE
    elif ext in ALLOWED_VIDEO:
        ftype, max_size = "video", MAX_VIDEO
    elif ext in ALLOWED_AUDIO:
        ftype, max_size = "audio", MAX_AUDIO
    else:
        raise HTTPException(400, f"Недопустимый тип файла: .{ext}")
    data = await file.read()
    if len(data) > max_size:
        raise HTTPException(400, f"Файл слишком большой. Максимум: {max_size // 1024 // 1024}MB")
    filename = f"{uuid.uuid4()}.{ext}"
    filepath = os.path.join(MEDIA_DIR, filename)
    if ftype == "image":
        try:
            from PIL import Image
            # Defuse decompression-bomb: запрет картинок > 50MP (~примерно 7000x7000)
            # По дефолту PIL ругается на 89.5MP, но мы и того не хотим — обрабатываем сами.
            Image.MAX_IMAGE_PIXELS = 50_000_000
            img = Image.open(io.BytesIO(data))
            img.verify()  # rapid integrity check
            # verify() закрывает stream, открываем заново для реальной обработки
            img = Image.open(io.BytesIO(data))
            if img.mode not in ("RGB", "RGBA"):
                img = img.convert("RGB")
            if img.width > 1920 or img.height > 1920:
                img.thumbnail((1920, 1920), Image.LANCZOS)
            out = io.BytesIO()
            fmt = {"jpg": "JPEG", "jpeg": "JPEG", "png": "PNG", "webp": "WEBP", "gif": "GIF"}.get(ext, "JPEG")
            kwargs = {"optimize": True}
            if fmt == "JPEG":
                kwargs["quality"] = 82
            img.save(out, format=fmt, **kwargs)
            with open(filepath, "wb") as f:
                f.write(out.getvalue())
        except HTTPException:
            raise
        except Exception:
            # Не показываем PIL-детали наружу (могут утечь пути/версия)
            raise HTTPException(400, "Не удалось обработать изображение")
    elif ftype == "video":
        with open(filepath, "wb") as f:
            f.write(data)
        compressed = os.path.join(MEDIA_DIR, f"{uuid.uuid4()}.mp4")
        ret = os.system(
            f'ffmpeg -i "{filepath}" -vcodec libx264 -crf 28 -preset fast '
            f'-acodec aac -b:a 128k -movflags +faststart "{compressed}" -y -loglevel error'
        )
        if ret == 0 and os.path.exists(compressed):
            os.remove(filepath)
            filepath, filename = compressed, os.path.basename(compressed)
    elif ftype == "audio":
        with open(filepath, "wb") as f:
            f.write(data)
        compressed = os.path.join(MEDIA_DIR, f"{uuid.uuid4()}.mp3")
        ret = os.system(
            f'ffmpeg -i "{filepath}" -acodec libmp3lame -b:a 128k "{compressed}" -y -loglevel error'
        )
        if ret == 0 and os.path.exists(compressed):
            os.remove(filepath)
            filepath, filename = compressed, os.path.basename(compressed)
    return {"url": f"/social/media/{filename}", "type": ftype, "name": file.filename}

# ── Posts ──────────────────────────────────────────────────────────────────────

def _hydrate_posts(c, rows: list, uid: int) -> list:
    """Дополняет посты реакциями и подпиской текущего юзера на автора."""
    if not rows:
        return []
    ids = [r["id"] for r in rows]
    placeholders = ",".join("?" * len(ids))
    react_rows = c.execute(
        f"SELECT post_id, emoji, COUNT(*) as cnt FROM soc_reactions WHERE post_id IN ({placeholders}) GROUP BY post_id, emoji",
        ids
    ).fetchall()
    my_rows = c.execute(
        f"SELECT post_id, emoji FROM soc_reactions WHERE user_id=? AND post_id IN ({placeholders})",
        [uid] + ids
    ).fetchall()
    per_post: dict = {pid: {"counts": {}, "your_emoji": None, "total": 0} for pid in ids}
    for r in react_rows:
        per_post[r["post_id"]]["counts"][r["emoji"]] = r["cnt"]
        per_post[r["post_id"]]["total"] += r["cnt"]
    for r in my_rows:
        per_post[r["post_id"]]["your_emoji"] = r["emoji"]
    # На кого из авторов этих постов я подписан
    author_ids = list({r["user_id"] for r in rows})
    followed: set = set()
    if uid and author_ids:
        ap = ",".join("?" * len(author_ids))
        f_rows = c.execute(
            f"SELECT followee_id FROM soc_follows WHERE follower_id=? AND followee_id IN ({ap})",
            [uid] + author_ids
        ).fetchall()
        followed = {r["followee_id"] for r in f_rows}
    # Опросы (одним запросом для всех постов в пачке)
    polls_map = {}
    p_rows = c.execute(
        f"SELECT post_id, question, options, is_quiz, correct_idx FROM soc_polls WHERE post_id IN ({placeholders})",
        ids
    ).fetchall()
    if p_rows:
        # Голоса
        v_rows = c.execute(
            f"SELECT post_id, option_idx, COUNT(*) as cnt FROM soc_poll_votes WHERE post_id IN ({placeholders}) GROUP BY post_id, option_idx",
            ids
        ).fetchall()
        my_votes = {}
        if uid > 0:
            mv_rows = c.execute(
                f"SELECT post_id, option_idx FROM soc_poll_votes WHERE user_id=? AND post_id IN ({placeholders})",
                [uid] + ids
            ).fetchall()
            my_votes = {r["post_id"]: r["option_idx"] for r in mv_rows}
        votes_by_post = defaultdict(dict)
        for r in v_rows:
            votes_by_post[r["post_id"]][r["option_idx"]] = r["cnt"]
        for r in p_rows:
            pid = r["post_id"]
            try: opts = json.loads(r["options"])
            except: opts = []
            counts = votes_by_post.get(pid, {})
            mv = my_votes.get(pid)
            polls_map[pid] = {
                "question": r["question"],
                "options": opts,
                "counts": counts,
                "total": sum(counts.values()),
                "my_vote": mv,
                "is_quiz": bool(r["is_quiz"]),
                "correct_idx": r["correct_idx"] if (r["is_quiz"] and mv is not None) else None,
            }
    out = []
    for r in rows:
        post = fmt_post(dict(r), uid, per_post[r["id"]], r["user_id"] in followed)
        if r["id"] in polls_map:
            post["poll"] = polls_map[r["id"]]
        out.append(post)
    return out

@router.get("/post")
def get_posts(
    sort: str = Query("new"),
    offset: int = Query(0),
    tag: Optional[str] = Query(None),
    seed: int = Query(0),
    authorization: Optional[str] = Header(None),
):
    user = auth(authorization)
    uid = user["id"]
    c = db()
    if sort == "top":
        order = "(SELECT COUNT(*) FROM soc_reactions l WHERE l.post_id=p.id) DESC, p.created_at DESC"
    elif sort == "old":
        order = "p.created_at ASC"
    elif sort == "random":
        # Псевдослучайный, но детерминированный для данного seed.
        # Без seed офсеты ломались бы — каждая страница тасовалась бы заново.
        s = max(1, int(seed) % 1000003) or 1
        order = f"((p.id * {s}) % 1000003)"
    else:
        order = "p.created_at DESC"

    where = ["p.kind='post'"]  # обычная лента — без минисок
    params: list = []
    join_following = ""
    if sort == "following":
        join_following = "JOIN soc_follows f ON f.followee_id=p.user_id AND f.follower_id=?"
        params.append(uid)
    if tag:
        where.append("(p.content LIKE ? OR p.content LIKE ? OR p.content LIKE ? OR p.content = ?)")
        like = f'%#{tag}%'
        params.extend([like, like, like, f'#{tag}'])
    where_sql = "WHERE " + " AND ".join(where)

    params.extend([offset])
    rows = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p
        JOIN users u ON p.user_id=u.id
        {join_following}
        {where_sql}
        ORDER BY {order}
        LIMIT 15 OFFSET ?
    """, params).fetchall()
    result = _hydrate_posts(c, rows, uid)
    c.close()
    return result

@router.get("/post/feed")
def get_feed_candidates(
    offset: int = Query(0),
    limit: int = Query(50),
    exclude: str = Query("", description="comma-separated post ids уже видены клиентом"),
    authorization: Optional[str] = Header(None),
):
    """Candidate-pool для алгоритмической ленты «Для вас».
    Mix: ~40% свежие (последние 24ч), ~30% топ по реакциям за неделю, ~30% случайные.
    Клиент ранжирует локально по своему профилю интересов.
    """
    user = auth(authorization)
    uid = user["id"]
    limit = max(5, min(100, limit))
    excluded: list = []
    if exclude:
        try:
            excluded = [int(x) for x in exclude.split(",") if x.strip().isdigit()][:500]
        except Exception:
            pass
    excl_sql = ""
    excl_params: list = []
    if excluded:
        ph = ",".join("?" * len(excluded))
        excl_sql = f"AND p.id NOT IN ({ph})"
        excl_params = excluded

    n_new = max(1, int(limit * 0.4))
    n_top = max(1, int(limit * 0.3))
    n_rnd = max(1, limit - n_new - n_top)

    c = db()
    # Свежие за 24ч
    fresh = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.created_at >= datetime('now', '-1 day') {excl_sql}
        ORDER BY p.created_at DESC
        LIMIT ? OFFSET ?
    """, excl_params + [n_new, offset]).fetchall()

    # Топ по реакциям за неделю (минус уже взятые)
    taken = {r["id"] for r in fresh} | set(excluded)
    ph2 = ",".join("?" * len(taken)) if taken else "NULL"
    top = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.created_at >= datetime('now', '-7 days')
          AND p.id NOT IN ({ph2})
        ORDER BY (SELECT COUNT(*) FROM soc_reactions WHERE post_id=p.id) DESC, p.created_at DESC
        LIMIT ?
    """, list(taken) + [n_top]).fetchall()

    # Рандомные (детерминирован по uid и offset чтобы при докачке не повторялись)
    seed = (uid * 9973 + offset * 17 + 1) % 1000003
    taken |= {r["id"] for r in top}
    ph3 = ",".join("?" * len(taken)) if taken else "NULL"
    rnd = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.id NOT IN ({ph3})
        ORDER BY ((p.id * {seed}) % 1000003)
        LIMIT ?
    """, list(taken) + [n_rnd]).fetchall()

    all_rows = list(fresh) + list(top) + list(rnd)
    result = _hydrate_posts(c, all_rows, uid)
    c.close()
    return result

@router.get("/post/newhere")
def check_new(last_id: int = Query(...), sort: str = Query("new"), authorization: Optional[str] = Header(None)):
    auth(authorization)
    if sort == "old":
        return {"has_new": False, "count": 0}
    c = db()
    row = c.execute("SELECT COUNT(*) as cnt FROM soc_posts WHERE id > ?", (last_id,)).fetchone()
    c.close()
    return {"has_new": row["cnt"] > 0, "count": row["cnt"]}

@router.get("/post/counts")
def get_post_counts(ids: str = Query(...), authorization: Optional[str] = Header(None)):
    user = auth(authorization)
    uid = user["id"]
    try:
        post_ids = [int(x) for x in ids.split(",") if x.strip()]
    except Exception:
        raise HTTPException(400, "Invalid ids")
    if not post_ids or len(post_ids) > 30:
        raise HTTPException(400, "1-30 ids required")
    c = db()
    placeholders = ",".join("?" * len(post_ids))
    comm_rows = c.execute(
        f"SELECT p.id, (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count "
        f"FROM soc_posts p WHERE p.id IN ({placeholders})",
        post_ids
    ).fetchall()
    react_rows = c.execute(
        f"SELECT post_id, emoji, COUNT(*) as cnt FROM soc_reactions WHERE post_id IN ({placeholders}) GROUP BY post_id, emoji",
        post_ids
    ).fetchall()
    my_rows = c.execute(
        f"SELECT post_id, emoji FROM soc_reactions WHERE user_id=? AND post_id IN ({placeholders})",
        [uid] + post_ids
    ).fetchall()
    result: dict = {}
    for r in comm_rows:
        result[r["id"]] = {
            "reactions": {"counts": {}, "your_emoji": None, "total": 0},
            "comments_count": r["comments_count"],
        }
    for r in react_rows:
        if r["post_id"] in result:
            result[r["post_id"]]["reactions"]["counts"][r["emoji"]] = r["cnt"]
            result[r["post_id"]]["reactions"]["total"] += r["cnt"]
    for r in my_rows:
        if r["post_id"] in result:
            result[r["post_id"]]["reactions"]["your_emoji"] = r["emoji"]
    c.close()
    return result

@router.get("/post/{post_id}")
def get_one_post(post_id: int, authorization: Optional[str] = Header(None)):
    """Для шаринга — открыть один пост по id."""
    user = auth(authorization)
    uid = user["id"]
    c = db()
    row = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.id=?
    """, (post_id,)).fetchone()
    if not row:
        c.close()
        raise HTTPException(404, "Post not found")
    result = _hydrate_posts(c, [row], uid)
    c.close()
    return result[0]

@router.post("/post/new")
def create_post(body: PostBody, request: Request, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    # 30 постов в час — больше реальный человек не пишет
    _rate_limit(f"post:{user['id']}", limit=30, window=3600)
    text = body.text.strip()
    if not text:
        raise HTTPException(400, "Empty")
    if len(text) > 1000:
        raise HTTPException(400, "Too long")
    media = _val_media(body.media)
    media_json = json.dumps(media, ensure_ascii=False) if media else None

    # Валидация опроса (если есть)
    poll = body.poll
    if poll is not None:
        q = (poll.question or "").strip()
        if not q or len(q) > 200:
            raise HTTPException(400, "Вопрос опроса: 1–200 символов")
        opts = [o.strip() for o in (poll.options or []) if o and o.strip()]
        if len(opts) < 2 or len(opts) > 6:
            raise HTTPException(400, "Опрос: от 2 до 6 вариантов")
        for o in opts:
            if len(o) > 80:
                raise HTTPException(400, "Вариант ответа: максимум 80 символов")
        if poll.is_quiz:
            if poll.correct_idx is None or poll.correct_idx < 0 or poll.correct_idx >= len(opts):
                raise HTTPException(400, "Викторина: укажите правильный ответ")

    c = db()
    c.execute("INSERT INTO soc_posts (user_id, content, media) VALUES (?,?,?)", (user["id"], text, media_json))
    post_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    if poll is not None:
        c.execute(
            "INSERT INTO soc_polls (post_id, question, options, is_quiz, correct_idx) VALUES (?,?,?,?,?)",
            (post_id, q, json.dumps(opts, ensure_ascii=False),
             1 if poll.is_quiz else 0,
             poll.correct_idx if poll.is_quiz else None),
        )

    preview = text[:120]
    notified = {user["id"]}  # не дублируем уведомления автору / повторно

    # Уведомить подписчиков о новом посте
    followers = c.execute(
        "SELECT follower_id FROM soc_follows WHERE followee_id=?", (user["id"],)
    ).fetchall()
    for f in followers:
        fid = f["follower_id"]
        if fid in notified:
            continue
        _add_notif(c, fid, user["id"], "new_post", post_id, preview)
        notified.add(fid)

    # Уведомить @упомянутых пользователей
    for uname in _extract_mentions(text):
        u = c.execute("SELECT id FROM users WHERE username=?", (uname,)).fetchone()
        if u and u["id"] not in notified:
            _add_notif(c, u["id"], user["id"], "mention", post_id, preview)
            notified.add(u["id"])

    c.commit()
    # Подтянуть только что созданный пост в полном формате и разослать
    c2 = db()
    row = c2.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               0 as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id WHERE p.id=?
    """, (post_id,)).fetchone()
    if row:
        full = _hydrate_posts(c2, [row], 0)[0]
        ws_hub.broadcast("post.new", {"post": full})
    c2.close()
    c.close()
    # Награда автору за пост (cap 25/день — антиспам)
    try: award_gost(user["id"], 'post', ref_type='post', ref_id=post_id)
    except Exception: pass
    return {"status": "ok", "post_id": post_id}

@router.patch("/post/{post_id}")
def edit_post(post_id: int, body: EditPostBody, authorization: Optional[str] = Header(None)):
    """Редактирование своего поста. Текст можно менять. Медиа — только убрать
    (нельзя добавить, нельзя подменить url). Не чаще раза в 30 минут."""
    user = auth_member(authorization)
    _rate_limit(f"editpost:{user['id']}", limit=10, window=60)
    c = db()
    post = c.execute("SELECT * FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not post:
        c.close()
        raise HTTPException(404, "Post not found")
    p = dict(post)
    if p["user_id"] != user["id"]:
        c.close()
        raise HTTPException(403, "Forbidden")

    # Окно редактирования: только в течение 30 минут после публикации.
    # Также если уже редактировали — не чаще раз в 30 минут.
    # (раньше проверялось только edited_at; если NULL — можно было править через год)
    reference_ts = p.get("edited_at") or p.get("created_at")
    if reference_ts:
        ok_after = c.execute(
            "SELECT (strftime('%s','now') - strftime('%s', ?)) >= 1800 as ok", (reference_ts,)
        ).fetchone()["ok"]
        if not ok_after:
            wait = c.execute(
                "SELECT 1800 - (strftime('%s','now') - strftime('%s', ?)) as s", (reference_ts,)
            ).fetchone()["s"]
            c.close()
            raise HTTPException(429, f"Можно редактировать раз в 30 минут. Подождите ещё {max(1, wait//60)} мин.")

    updates = []
    params = []

    if body.text is not None:
        text = body.text.strip()
        if not text:
            c.close()
            raise HTTPException(400, "Текст не может быть пустым")
        if len(text) > 1000:
            c.close()
            raise HTTPException(400, "Слишком длинный текст (макс 1000)")
        updates.append("content=?")
        params.append(text)

    if body.media is not None:
        # Парсим старые медиа
        old_media = []
        if p.get("media"):
            try: old_media = json.loads(p["media"])
            except: pass
        old_urls = {m.get("url") for m in old_media}
        new_urls = {m.get("url") for m in (body.media or [])}
        # Все новые URL должны быть подмножеством старых (медиа можно только убрать)
        added = new_urls - old_urls
        if added:
            c.close()
            raise HTTPException(400, "Добавлять медиа нельзя — только удалять существующие")
        # Удаляем файлы тех, что убрал
        removed = old_urls - new_urls
        for m in old_media:
            if m.get("url") in removed:
                fname = m["url"].split("/")[-1]
                if fname:
                    fp = os.path.join(MEDIA_DIR, fname)
                    if os.path.exists(fp):
                        try: os.remove(fp)
                        except: pass
        # Сохраняем оставшиеся (с оригинальной структурой, чтоб name не терялся)
        kept = [m for m in old_media if m.get("url") in new_urls]
        updates.append("media=?")
        params.append(json.dumps(kept, ensure_ascii=False) if kept else None)

    if not updates:
        c.close()
        raise HTTPException(422, "Нечего менять")

    updates.append("edited_at=datetime('now')")
    params.append(post_id)
    c.execute(f"UPDATE soc_posts SET {', '.join(updates)} WHERE id=?", params)
    c.commit()
    # Broadcast обновлённого поста
    row = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id WHERE p.id=?
    """, (post_id,)).fetchone()
    if row:
        full = _hydrate_posts(c, [row], 0)[0]
        ws_hub.broadcast("post.edit", {"post": full})
    c.close()
    return {"status": "ok"}

@router.delete("/post/{post_id}")
def delete_post(post_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"delpost:{user['id']}", limit=20, window=60)
    c = db()
    post = c.execute("SELECT * FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not post:
        c.close()
        raise HTTPException(404, "Post not found")
    if dict(post)["user_id"] != user["id"]:
        c.close()
        raise HTTPException(403, "Forbidden")
    if post["media"]:
        try:
            for m in json.loads(post["media"]):
                fname = m.get("url", "").split("/")[-1]
                if fname:
                    path = os.path.join(MEDIA_DIR, fname)
                    if os.path.exists(path):
                        os.remove(path)
        except Exception:
            pass
    c.execute("DELETE FROM soc_reactions WHERE post_id=?", (post_id,))
    c.execute("DELETE FROM soc_comments WHERE post_id=?", (post_id,))
    c.execute("DELETE FROM soc_notifications WHERE post_id=?", (post_id,))
    c.execute("DELETE FROM soc_posts WHERE id=?", (post_id,))
    c.commit()
    c.close()
    ws_hub.broadcast("post.delete", {"post_id": post_id})
    return {"status": "ok"}

# ── Search ─────────────────────────────────────────────────────────────────────

@router.get("/search")
def search(q: str = Query(...), offset: int = Query(0), authorization: Optional[str] = Header(None)):
    user = auth(authorization)
    uid = user["id"]
    q = q.strip()
    if not q:
        raise HTTPException(400, "Empty query")
    c = db()
    if q.startswith("@"):
        term = q[1:].strip()
        if not term:
            c.close()
            return {"type": "users", "results": []}
        rows = c.execute("""
            SELECT u.id, u.username, u.display_name,
                   (SELECT COUNT(*) FROM soc_posts p WHERE p.user_id=u.id) as posts_count
            FROM users u
            WHERE ci_contains(u.username, ?) OR ci_contains(u.display_name, ?)
            ORDER BY posts_count DESC LIMIT 20 OFFSET ?
        """, (term, term, offset)).fetchall()
        c.close()
        return {"type": "users", "results": [dict(r) for r in rows]}
    else:
        rows = c.execute("""
            SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
                   u.username, u.display_name,
                   (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
            FROM soc_posts p JOIN users u ON p.user_id=u.id
            WHERE ci_contains(p.content, ?)
            ORDER BY p.created_at DESC LIMIT 15 OFFSET ?
        """, (q, offset)).fetchall()
        result = _hydrate_posts(c, rows, uid)
        c.close()
        return {"type": "posts", "results": result}

# ── Profile ────────────────────────────────────────────────────────────────────

@router.get("/prof/{username}")
def get_profile(username: str, offset: int = Query(0), authorization: Optional[str] = Header(None)):
    user = auth(authorization)
    uid = user["id"]
    c = db()
    u = c.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    if not u:
        c.close()
        raise HTTPException(404, "User not found")
    u = dict(u)
    stats = get_user_stats(c, u["id"])
    am_following = c.execute(
        "SELECT 1 FROM soc_follows WHERE follower_id=? AND followee_id=?", (uid, u["id"])
    ).fetchone() is not None
    rows = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.user_id=? ORDER BY p.created_at DESC LIMIT 15 OFFSET ?
    """, (u["id"], offset)).fetchall()
    posts = _hydrate_posts(c, rows, uid)
    c.close()
    return {
        "user_id": u["id"],
        "username": u["username"],
        "display_name": u["display_name"],
        "am_following": am_following,
        "is_me": uid == u["id"],
        **stats,
        "posts": posts,
    }

@router.get("/prof/{username}/posts")
def get_profile_posts(username: str, offset: int = Query(0), authorization: Optional[str] = Header(None)):
    """Пагинация постов профиля (без stats — для подгрузки)."""
    user = auth(authorization)
    uid = user["id"]
    c = db()
    u = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
    if not u:
        c.close()
        raise HTTPException(404, "User not found")
    rows = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.user_id=? ORDER BY p.created_at DESC LIMIT 15 OFFSET ?
    """, (u["id"], offset)).fetchall()
    posts = _hydrate_posts(c, rows, uid)
    c.close()
    return posts

@router.post("/follow/{username}")
def follow(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    # 30 фолловов в минуту — защита от mass-follow ботов
    _rate_limit(f"follow:{user['id']}", limit=30, window=60)
    c = db()
    target = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
    if not target:
        c.close()
        raise HTTPException(404, "User not found")
    if target["id"] == user["id"]:
        c.close()
        raise HTTPException(400, "Нельзя подписаться на себя")
    existing = c.execute(
        "SELECT 1 FROM soc_follows WHERE follower_id=? AND followee_id=?",
        (user["id"], target["id"])
    ).fetchone()
    if existing:
        c.close()
        return {"status": "ok", "following": True}
    c.execute(
        "INSERT INTO soc_follows (follower_id, followee_id) VALUES (?,?)",
        (user["id"], target["id"])
    )
    _add_notif(c, target["id"], user["id"], "follow", 0)
    c.commit()
    c.close()
    # Награда followee за нового подписчика. UNIQUE по (followee, 'follow', follower, '', 0)
    # → если follower отписался и подписался снова — НЕ начисляется повторно (как и должно быть).
    try: award_gost(target["id"], 'follow', actor_id=user["id"])
    except Exception: pass
    return {"status": "ok", "following": True}

@router.delete("/follow/{username}")
def unfollow(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"unfollow:{user['id']}", limit=30, window=60)
    c = db()
    target = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
    if not target:
        c.close()
        raise HTTPException(404, "User not found")
    c.execute(
        "DELETE FROM soc_follows WHERE follower_id=? AND followee_id=?",
        (user["id"], target["id"])
    )
    # снять follow-уведомление чтобы не осталось мусора при follow-unfollow спаме
    c.execute(
        "DELETE FROM soc_notifications WHERE user_id=? AND actor_id=? AND type='follow' AND is_read=0",
        (target["id"], user["id"])
    )
    c.commit()
    c.close()
    return {"status": "ok", "following": False}

@router.get("/me")
def get_me(authorization: Optional[str] = Header(None)):
    user = auth(authorization)
    if user.get("is_guest"):
        return {
            "id": 0, "user_id": 0,
            "username": "__guest__",
            "display_name": "Гость",
            "is_guest": True,
            "posts_count": 0, "likes_received": 0, "likes_given": 0,
            "followers_count": 0, "following_count": 0,
        }
    c = db()
    stats = get_user_stats(c, user["id"])
    c.close()
    return {
        "id": user["id"],
        "user_id": user["id"],
        "username": user["username"],
        "display_name": user["display_name"],
        "is_guest": False,
        **stats,
    }

@router.patch("/me")
def edit_me(body: EditProfileBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    # Защита от перебора старого пароля + от спама смены username
    _rate_limit(f"editme:{user['id']}", limit=10, window=3600)

    needs_old_pwd = body.username is not None or body.new_password is not None
    if needs_old_pwd:
        if not body.old_password:
            raise HTTPException(422, "Введите текущий пароль")
        # Используем существующие argon2-функции; legacy PBKDF2 → upgrade при следующем логине
        stored_hash = user.get("argon2_hash") or user.get("password_hash")
        if not stored_hash or not verify_argon2(body.old_password, stored_hash):
            raise HTTPException(401, "Неверный текущий пароль")

    updates: dict = {}
    if body.display_name is not None:
        updates["display_name"] = _val_name(body.display_name)
    if body.username is not None:
        updates["username"] = _val_username(body.username)
    if body.new_password is not None:
        _val_password(body.new_password)
        updates["argon2_hash"] = hash_argon2(body.new_password)
        # Инвалидируем legacy-pbkdf2-хэш если он был — пусть остаётся только argon2
        updates["password_hash"] = None
        # Сменили пароль → старый encrypted_private_key (зашифрован старым паролем)
        # больше не расшифровать. Зануляем E2E-ключи — клиент сгенерирует новые при
        # следующем входе в /chat. История в IDB у клиента остаётся (там plaintext).
        updates["x25519_pub"] = None
        updates["encrypted_private_key"] = None
        updates["key_salt"] = None

    if not updates:
        raise HTTPException(422, "Нечего изменять")

    c = db()
    if "username" in updates:
        clash = c.execute(
            "SELECT id FROM users WHERE username=? AND id!=?", (updates["username"], user["id"])
        ).fetchone()
        if clash:
            c.close()
            raise HTTPException(409, "Имя пользователя уже занято")

    set_clause = ", ".join(f"{k}=?" for k in updates)
    c.execute(f"UPDATE users SET {set_clause} WHERE id=?", list(updates.values()) + [user["id"]])
    c.commit()
    row = c.execute(
        "SELECT id, username, display_name FROM users WHERE id=?", (user["id"],)
    ).fetchone()
    c.close()
    return {"status": "ok", "id": row["id"], "username": row["username"], "display_name": row["display_name"]}

# ── Likes ──────────────────────────────────────────────────────────────────────

@router.post("/react/{post_id}")
def react(post_id: int, body: ReactBody, authorization: Optional[str] = Header(None)):
    """Установить/сменить/снять реакцию. emoji=null → снять."""
    user = auth_member(authorization)
    # 120 реакций в минуту — нормально тапать быстро, но защита от скрипта
    _rate_limit(f"react:{user['id']}", limit=120, window=60)
    if body.emoji is not None and body.emoji not in ALLOWED_EMOJI:
        raise HTTPException(400, "Недопустимая реакция")
    c = db()
    post = c.execute("SELECT user_id FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not post:
        c.close()
        raise HTTPException(404, "Post not found")
    owner_id = post["user_id"]
    existing = c.execute(
        "SELECT emoji FROM soc_reactions WHERE post_id=? AND user_id=?", (post_id, user["id"])
    ).fetchone()

    # Помечаем что нужно наградить АВТОРА поста после commit (а не во время — иначе SQLite lock)
    do_award_owner = False

    if body.emoji is None:
        # Снять реакцию
        if existing:
            c.execute("DELETE FROM soc_reactions WHERE post_id=? AND user_id=?", (post_id, user["id"]))
            c.execute(
                "DELETE FROM soc_notifications WHERE user_id=? AND actor_id=? AND type='react' AND post_id=? AND is_read=0",
                (owner_id, user["id"], post_id),
            )
    else:
        if existing:
            if existing["emoji"] != body.emoji:
                c.execute(
                    "UPDATE soc_reactions SET emoji=? WHERE post_id=? AND user_id=?",
                    (body.emoji, post_id, user["id"]),
                )
        else:
            c.execute(
                "INSERT INTO soc_reactions (post_id, user_id, emoji) VALUES (?,?,?)",
                (post_id, user["id"], body.emoji),
            )
            _add_notif(c, owner_id, user["id"], "react", post_id, body.emoji)
            # Награду отдадим ПОСЛЕ c.commit() / c.close() — award_gost открывает своё
            # соединение и BEGIN IMMEDIATE: пока мы держим транзакцию здесь — он словит lock.
            if owner_id != user["id"]:
                do_award_owner = True

    c.commit()
    result = _post_reactions(c, post_id, user["id"])
    # Глобальный broadcast реакций (без your_emoji — каждый клиент сам определит)
    public = {"counts": result.get("counts", {}), "total": result.get("total", 0)}
    ws_hub.broadcast("post.react", {"post_id": post_id, "reactions": public})
    c.close()

    # Награда автору — отдельным соединением, без конфликта lock'ов
    if do_award_owner:
        try: award_gost(owner_id, 'react', actor_id=user["id"], ref_type='post', ref_id=post_id)
        except Exception: pass

    return result

# ── Comments ───────────────────────────────────────────────────────────────────

@router.get("/com/get/{post_id}")
def get_comments(post_id: int, offset: int = Query(0), authorization: Optional[str] = Header(None)):
    auth(authorization)
    c = db()
    rows = c.execute("""
        SELECT cm.id, cm.text, cm.created_at, u.username, u.display_name
        FROM soc_comments cm JOIN users u ON cm.user_id=u.id
        WHERE cm.post_id=? ORDER BY cm.created_at DESC LIMIT 3 OFFSET ?
    """, (post_id, offset)).fetchall()
    total = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_comments WHERE post_id=?", (post_id,)
    ).fetchone()["cnt"]
    c.close()
    return {"comments": [dict(r) for r in rows], "has_more": (offset + 3) < total, "total": total}

@router.post("/com/{post_id}")
def write_comment(post_id: int, body: CommentBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"com:{user['id']}", limit=30, window=60)
    text = body.text.strip()
    if not text:
        raise HTTPException(400, "Empty")
    if len(text) > 500:
        raise HTTPException(400, "Too long")
    c = db()
    post = c.execute("SELECT user_id FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not post:
        c.close()
        raise HTTPException(404, "Post not found")
    c.execute(
        "INSERT INTO soc_comments (post_id, user_id, text) VALUES (?,?,?)", (post_id, user["id"], text)
    )
    notified = {user["id"]}
    _add_notif(c, post["user_id"], user["id"], "comment", post_id, text[:120])
    notified.add(post["user_id"])
    for uname in _extract_mentions(text):
        u = c.execute("SELECT id FROM users WHERE username=?", (uname,)).fetchone()
        if u and u["id"] not in notified:
            _add_notif(c, u["id"], user["id"], "mention", post_id, text[:120])
            notified.add(u["id"])
    c.commit()
    comment_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    total = c.execute("SELECT COUNT(*) as cnt FROM soc_comments WHERE post_id=?", (post_id,)).fetchone()["cnt"]
    c.close()
    # Награда автору поста за чужой коммент. ref_id = comment_id чтобы каждый отдельный коммент засчитывался.
    if post["user_id"] != user["id"]:
        try: award_gost(post["user_id"], 'comment', actor_id=user["id"], ref_type='comment', ref_id=comment_id)
        except Exception: pass
    ws_hub.broadcast("post.comment", {
        "post_id": post_id,
        "comments_count": total,
        "comment": {
            "id": comment_id, "text": text,
            "username": user["username"], "display_name": user["display_name"],
        },
    })
    return {"status": "ok", "comment_id": comment_id}

@router.delete("/com/{comment_id}")
def delete_comment(comment_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"delcom:{user['id']}", limit=30, window=60)
    c = db()
    row = c.execute("SELECT cm.user_id, p.user_id as post_owner FROM soc_comments cm JOIN soc_posts p ON cm.post_id=p.id WHERE cm.id=?", (comment_id,)).fetchone()
    if not row:
        c.close()
        raise HTTPException(404, "Comment not found")
    # Удалить может автор коммента ИЛИ автор поста (модерация своей ленты)
    if row["user_id"] != user["id"] and row["post_owner"] != user["id"]:
        c.close()
        raise HTTPException(403, "Forbidden")
    c.execute("DELETE FROM soc_comments WHERE id=?", (comment_id,))
    c.commit()
    c.close()
    return {"status": "ok"}

# ── Notifications ───────────────────────────────────────────────────────────────

@router.get("/notif")
def get_notifications(offset: int = Query(0), authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    rows = c.execute("""
        SELECT n.id, n.type, n.post_id, n.preview, n.is_read, n.created_at,
               a.username as actor_username, a.display_name as actor_name
        FROM soc_notifications n
        JOIN users a ON n.actor_id = a.id
        WHERE n.user_id = ?
        ORDER BY n.id DESC
        LIMIT 20 OFFSET ?
    """, (user["id"], offset)).fetchall()
    total = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_notifications WHERE user_id=?", (user["id"],)
    ).fetchone()["cnt"]
    c.close()
    return {
        "notifications": [
            {
                "id": r["id"],
                "type": r["type"],
                "post_id": r["post_id"],
                "preview": r["preview"],
                "is_read": bool(r["is_read"]),
                "created_at": r["created_at"],
                "actor_username": r["actor_username"],
                "actor_name": r["actor_name"],
            }
            for r in rows
        ],
        "has_more": offset + 20 < total,
        "total": total,
    }

@router.get("/notif/unread")
def unread_count(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    cnt = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_notifications WHERE user_id=? AND is_read=0", (user["id"],)
    ).fetchone()["cnt"]
    c.close()
    return {"count": cnt}

@router.post("/notif/read")
def mark_read(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"notifread:{user['id']}", limit=30, window=60)
    c = db()
    c.execute("UPDATE soc_notifications SET is_read=1 WHERE user_id=? AND is_read=0", (user["id"],))
    c.commit()
    c.close()
    return {"status": "ok"}

# ── Health ─────────────────────────────────────────────────────────────────────

# ── Link preview (OG/twitter meta tags, SSRF-safe) ───────────────────────────

import ipaddress
import socket
from urllib.parse import urlparse, urljoin

_LINK_CACHE_TTL = 24 * 3600  # 24 часа
_LINK_FETCH_MAX = 200 * 1024  # 200 KB max HTML

def _safe_url(u: str) -> Optional[str]:
    """Возвращает нормализованный URL или None если небезопасный."""
    if not u or len(u) > 2000:
        return None
    try:
        p = urlparse(u)
    except Exception:
        return None
    if p.scheme not in ("http", "https"):
        return None
    if not p.netloc:
        return None
    host = p.hostname or ""
    # SSRF: блокируем internal IPs
    try:
        for fam in (socket.AF_INET, socket.AF_INET6):
            try:
                infos = socket.getaddrinfo(host, None, fam)
            except Exception:
                continue
            for info in infos:
                addr = info[4][0]
                ip = ipaddress.ip_address(addr)
                if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved:
                    return None
    except Exception:
        return None
    return f"{p.scheme}://{p.netloc}{p.path or '/'}{'?' + p.query if p.query else ''}"

@router.get("/linkpreview")
async def link_preview(url: str = Query(..., max_length=2000), authorization: Optional[str] = Header(None)):
    """OG/Twitter meta preview. SSRF-safe, кэш 24ч."""
    auth(authorization)  # любой авторизованный, включая гостя
    safe = _safe_url(url)
    if not safe:
        raise HTTPException(400, "Невалидный URL")

    c = db()
    row = c.execute(
        "SELECT data, fetched_at FROM soc_link_cache WHERE url=?", (safe,)
    ).fetchone()
    now = int(time.time())
    if row and (now - row["fetched_at"]) < _LINK_CACHE_TTL:
        c.close()
        try:
            return json.loads(row["data"])
        except Exception:
            pass

    import httpx
    from bs4 import BeautifulSoup
    try:
        async with httpx.AsyncClient(
            timeout=5.0, follow_redirects=True, max_redirects=4,
            headers={"User-Agent": "GhostSocialPreview/1.0 (+https://ghostecos.duckdns.org)"}
        ) as client:
            r = await client.get(safe)
            ctype = r.headers.get("content-type", "")
            if "html" not in ctype.lower():
                c.close()
                raise HTTPException(415, "Не HTML")
            content = r.content[:_LINK_FETCH_MAX]
            final_url = str(r.url)
    except HTTPException:
        raise
    except Exception:
        c.close()
        raise HTTPException(502, "Не удалось загрузить")

    try:
        soup = BeautifulSoup(content, "html.parser")
    except Exception:
        c.close()
        raise HTTPException(500, "Ошибка парсинга")

    def meta(prop):
        for key in ("property", "name"):
            tag = soup.find("meta", attrs={key: prop})
            if tag and tag.get("content"):
                return tag["content"].strip()
        return None

    title = (meta("og:title") or meta("twitter:title") or
             (soup.title.string.strip() if soup.title and soup.title.string else None))
    description = meta("og:description") or meta("twitter:description") or meta("description")
    image = meta("og:image") or meta("twitter:image")
    site = meta("og:site_name") or urlparse(final_url).hostname

    # Абсолютный URL картинки
    if image and not image.startswith(("http://", "https://")):
        image = urljoin(final_url, image)
    if image:
        image = _safe_url(image) or None

    out = {
        "url": final_url,
        "title": (title or "")[:200],
        "description": (description or "")[:400],
        "image": image,
        "site": (site or "")[:100],
    }

    c.execute(
        "INSERT OR REPLACE INTO soc_link_cache (url, data, fetched_at) VALUES (?,?,?)",
        (safe, json.dumps(out, ensure_ascii=False), now),
    )
    c.commit()
    c.close()
    return out

# ── Polls / Quizzes ───────────────────────────────────────────────────────────

@router.post("/post/{post_id}/vote")
def vote(post_id: int, body: VoteBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"vote:{user['id']}", limit=60, window=3600)
    c = db()
    poll = c.execute("SELECT * FROM soc_polls WHERE post_id=?", (post_id,)).fetchone()
    if not poll:
        c.close()
        raise HTTPException(404, "Опрос не найден")
    try: opts = json.loads(poll["options"])
    except: opts = []
    if body.option_idx < 0 or body.option_idx >= len(opts):
        c.close()
        raise HTTPException(400, "Невалидный вариант")
    # один голос на юзера. Можно поменять
    c.execute(
        "INSERT OR REPLACE INTO soc_poll_votes (post_id, user_id, option_idx) VALUES (?,?,?)",
        (post_id, user["id"], body.option_idx)
    )
    c.commit()
    state = _poll_state(c, post_id, user["id"])
    c.close()
    ws_hub.broadcast("post.vote", {"post_id": post_id, "poll": {
        "counts": state["counts"], "total": state["total"],
    }})
    return state

def _poll_state(c, post_id: int, uid: int) -> dict:
    """Полное состояние опроса для поста: вопрос, варианты, голоса, мой выбор."""
    poll = c.execute("SELECT * FROM soc_polls WHERE post_id=?", (post_id,)).fetchone()
    if not poll:
        return None
    try: opts = json.loads(poll["options"])
    except: opts = []
    rows = c.execute(
        "SELECT option_idx, COUNT(*) as cnt FROM soc_poll_votes WHERE post_id=? GROUP BY option_idx",
        (post_id,)
    ).fetchall()
    counts = {r["option_idx"]: r["cnt"] for r in rows}
    total = sum(counts.values())
    my_vote = None
    if uid > 0:
        mv = c.execute(
            "SELECT option_idx FROM soc_poll_votes WHERE post_id=? AND user_id=?",
            (post_id, uid)
        ).fetchone()
        if mv:
            my_vote = mv["option_idx"]
    return {
        "question": poll["question"],
        "options": opts,
        "counts": counts,
        "total": total,
        "my_vote": my_vote,
        "is_quiz": bool(poll["is_quiz"]),
        "correct_idx": poll["correct_idx"] if (poll["is_quiz"] and my_vote is not None) else None,
    }

# ── Миниски (короткие вертикальные видео) ───────────────────────────────────

class MiniskaBody(BaseModel):
    caption: str = ""
    video_url: str

MINISKA_MAX_DURATION = 30
MINISKA_MAX_TEXT = 200

@router.post("/miniska/new")
def create_miniska(body: MiniskaBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    # Миниски тяжёлые (видео + cron убирает их), 10 в час более чем достаточно
    _rate_limit(f"miniska:{user['id']}", limit=10, window=3600)
    if not _MEDIA_URL_RE.match(body.video_url or ""):
        raise HTTPException(400, "Некорректный URL видео")
    caption = (body.caption or "").strip()
    if len(caption) > MINISKA_MAX_TEXT:
        raise HTTPException(400, f"Текст до {MINISKA_MAX_TEXT} символов")
    fname = body.video_url.split("/")[-1]
    fpath = os.path.join(MEDIA_DIR, fname)
    if not os.path.exists(fpath):
        raise HTTPException(404, "Видео не найдено")
    # Длительность через ffprobe
    try:
        import subprocess
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", fpath],
            capture_output=True, text=True, timeout=10
        )
        dur = float((out.stdout or "0").strip() or 0)
        if dur > MINISKA_MAX_DURATION + 1:
            try: os.remove(fpath)
            except: pass
            raise HTTPException(400, f"Слишком длинно. Максимум {MINISKA_MAX_DURATION} сек")
    except HTTPException:
        raise
    except Exception:
        pass
    media = [{"url": body.video_url, "type": "video", "name": fname}]
    media_json = json.dumps(media, ensure_ascii=False)
    c = db()
    c.execute(
        "INSERT INTO soc_posts (user_id, content, media, kind) VALUES (?,?,?,'miniska')",
        (user["id"], caption or " ", media_json),
    )
    post_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    c.commit()
    c.close()
    return {"status": "ok", "id": post_id}

@router.get("/miniska/feed")
def miniska_feed(
    offset: int = Query(0),
    limit: int = Query(20),
    exclude: str = Query(""),
    authorization: Optional[str] = Header(None),
):
    user = auth(authorization)
    uid = user["id"]
    limit = max(1, min(50, limit))
    excluded: list = []
    if exclude:
        try: excluded = [int(x) for x in exclude.split(",") if x.strip().isdigit()][:500]
        except: pass
    excl_sql = ""
    excl_params: list = []
    if excluded:
        excl_sql = f"AND p.id NOT IN ({','.join('?' * len(excluded))})"
        excl_params = excluded
    seed = (uid * 9973 + offset * 17 + 1) % 1000003 if uid else 12345
    c = db()
    rows = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.kind='miniska' {excl_sql}
        ORDER BY (p.id * {seed}) % 1000003
        LIMIT ? OFFSET ?
    """, excl_params + [limit, offset]).fetchall()
    result = _hydrate_posts(c, rows, uid)
    c.close()
    return result


@router.get("/health")
def health():
    return {"status": "ok", "service": "GhostSocial"}

# ══════════════════════════════════════════════════════════════════════════════
# ЭКОНОМИКА: КОШЕЛЁК (gost / soul / prem)
# ══════════════════════════════════════════════════════════════════════════════
# Дизайн см. memory/project_economy.md
#   gost — бесплатная, активность, non-transferable, тратится только на первичные NFT
#   soul — transferable, cap-эмиссия, эмитируется через выкуп NFT (TODO)
#   prem — украшения, не пересекается с другими (TODO)

# Тарифы и лимиты — все в одном месте, чтобы балансировать без хождения по коду
GOST_REWARDS = {
    'register':  100,   # one-time welcome bonus
    'daily':      10,   # раз в 24ч
    'post':        5,   # за свой пост
    'react':       1,   # автор поста — за чужой лайк
    'comment':     2,   # автор поста — за чужой коммент
    'follow':      5,   # юзер — за нового подписчика
}
# Cap начисления per-источник per-юзер за скользящие 24ч (защита от спама)
GOST_DAILY_CAP = {
    'post':     25,    # ≈ 5 постов в день максимум засчитано
    'react':    50,    # ≈ 50 лайков на свои посты
    'comment':  60,    # ≈ 30 комментов
    'follow':   25,    # ≈ 5 новых фолловеров
    # daily/register — natural cap (1 раз/24ч / one-time)
}
DAILY_CLAIM_INTERVAL = 24 * 3600   # секунд между daily-claim
ALLOWED_CURRENCIES = {'gost', 'soul', 'prem'}


def _ensure_wallet(c, user_id: int) -> None:
    """Гарантирует наличие строки wallet (для join'ов и обновлений)."""
    c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (user_id,))


def get_balance(user_id: int) -> dict:
    """Возвращает баланс юзера. Все три валюты — всегда возвращаем (нули если нет записи)."""
    c = db()
    row = c.execute(
        "SELECT gost, soul, prem FROM soc_wallets WHERE user_id=?", (user_id,)
    ).fetchone()
    c.close()
    return {
        "gost": (row["gost"] if row else 0),
        "soul": (row["soul"] if row else 0),
        "prem": (row["prem"] if row else 0),
    }


def _sum_source_24h(c, user_id: int, source: str) -> int:
    """Сколько начислено за последние 24ч по этому источнику (для cap-чека)."""
    row = c.execute(
        "SELECT COALESCE(SUM(delta), 0) as s FROM soc_wallet_tx "
        "WHERE user_id=? AND source=? AND delta>0 "
        "AND created_at > datetime('now', '-1 day')",
        (user_id, source),
    ).fetchone()
    return row["s"] or 0


def award_gost(
    user_id: int,
    source: str,
    actor_id: int = 0,
    ref_type: str = '',
    ref_id: int = 0,
    amount_override: Optional[int] = None,
) -> dict:
    """Начисляет gost за активность. Атомарно. Возвращает {credited, new_balance, reason}.

    Дедуп: для source ∈ {register, post, react, comment, follow} —
    UNIQUE индекс на (user_id, source, actor_id, ref_type, ref_id) не даст начислить дважды.
    daily — отдельный check по времени.
    Cap per-day по источнику — мягкий cap (выше cap'а просто не начисляется, без ошибки).
    """
    if user_id <= 0:
        return {"credited": 0, "new_balance": 0, "reason": "guest"}
    if source not in GOST_REWARDS and amount_override is None:
        return {"credited": 0, "new_balance": 0, "reason": "unknown_source"}
    amount = amount_override if amount_override is not None else GOST_REWARDS[source]
    if amount <= 0:
        return {"credited": 0, "new_balance": 0, "reason": "zero"}

    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        _ensure_wallet(c, user_id)

        # daily — особый: 1 раз в 24ч
        if source == 'daily':
            last = c.execute(
                "SELECT created_at FROM soc_wallet_tx "
                "WHERE user_id=? AND source='daily' "
                "ORDER BY id DESC LIMIT 1",
                (user_id,),
            ).fetchone()
            if last:
                age = c.execute(
                    "SELECT strftime('%s','now') - strftime('%s', ?) as age",
                    (last["created_at"],),
                ).fetchone()["age"]
                if (age or 0) < DAILY_CLAIM_INTERVAL:
                    c.execute("ROLLBACK")
                    c.close()
                    return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "too_soon"}

        # Per-day cap для тех источников где он есть
        if source in GOST_DAILY_CAP:
            already = _sum_source_24h(c, user_id, source)
            if already >= GOST_DAILY_CAP[source]:
                c.execute("ROLLBACK")
                c.close()
                return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "daily_cap"}
            # Не дать переплеснуть cap — режем amount
            if already + amount > GOST_DAILY_CAP[source]:
                amount = GOST_DAILY_CAP[source] - already

        # Запись tx (UNIQUE index блокирует дубль — IntegrityError)
        try:
            c.execute(
                "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
                "VALUES (?, 'gost', ?, ?, ?, ?, ?)",
                (user_id, amount, source, actor_id, ref_type, ref_id),
            )
        except sqlite3.IntegrityError:
            # Дубль по UNIQUE — это OK, источник уже был засчитан
            c.execute("ROLLBACK")
            c.close()
            return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "already_credited"}

        # Обновляем баланс
        c.execute(
            "UPDATE soc_wallets SET gost = gost + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (amount, user_id),
        )
        new_bal = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user_id,)).fetchone()["gost"]
        c.execute("COMMIT")
    except Exception:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise
    c.close()
    # WS-пуш владельцу: моментально подсветить +N в кошельке
    ws_hub.send_to(user_id, "wallet.credit", {
        "currency": "gost", "delta": amount, "source": source,
        "balance": new_bal,
    })
    return {"credited": amount, "new_balance": new_bal, "reason": "ok"}


# ── Wallet API ────────────────────────────────────────────────────────────────

@router.get("/wallet")
def my_wallet(authorization: Optional[str] = Header(None)):
    """Текущий баланс залогиненного юзера."""
    user = auth_member(authorization)
    bal = get_balance(user["id"])
    # Информация о daily-claim для UI: сколько ждать до следующего
    c = db()
    last = c.execute(
        "SELECT created_at FROM soc_wallet_tx WHERE user_id=? AND source='daily' "
        "ORDER BY id DESC LIMIT 1",
        (user["id"],),
    ).fetchone()
    next_daily_in = 0
    if last:
        age = c.execute(
            "SELECT strftime('%s','now') - strftime('%s', ?) as age", (last["created_at"],)
        ).fetchone()["age"] or 0
        next_daily_in = max(0, DAILY_CLAIM_INTERVAL - age)
    c.close()
    return {
        "balance": bal,
        "daily_reward": GOST_REWARDS['daily'],
        "next_daily_in": next_daily_in,  # секунд до следующего claim (0 = можно сейчас)
    }


@router.get("/wallet/tx")
def my_wallet_tx(offset: int = Query(0, ge=0), authorization: Optional[str] = Header(None)):
    """История транзакций (последние 30, пагинация)."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute(
        "SELECT id, currency, delta, source, actor_id, ref_type, ref_id, created_at "
        "FROM soc_wallet_tx WHERE user_id=? "
        "ORDER BY id DESC LIMIT 30 OFFSET ?",
        (user["id"], offset),
    ).fetchall()
    # Дотягиваем username актора одной пачкой
    actor_ids = list({r["actor_id"] for r in rows if r["actor_id"]})
    actor_map = {}
    if actor_ids:
        ph = ",".join("?" * len(actor_ids))
        for u in c.execute(f"SELECT id, username, display_name FROM users WHERE id IN ({ph})", actor_ids):
            actor_map[u["id"]] = {"username": u["username"], "display_name": u["display_name"]}
    c.close()
    return {
        "transactions": [
            {
                "id": r["id"],
                "currency": r["currency"],
                "delta": r["delta"],
                "source": r["source"],
                "ref_type": r["ref_type"],
                "ref_id": r["ref_id"],
                "actor": actor_map.get(r["actor_id"]),
                "created_at": r["created_at"],
            }
            for r in rows
        ],
        "has_more": len(rows) == 30,
    }


@router.post("/wallet/claim_daily")
def claim_daily(authorization: Optional[str] = Header(None)):
    """Ежедневный бонус gost. Раз в 24ч."""
    user = auth_member(authorization)
    _rate_limit(f"daily:{user['id']}", limit=5, window=60)  # анти-спам кнопки
    res = award_gost(user["id"], 'daily')
    if res["reason"] == "too_soon":
        raise HTTPException(429, "Ежедневный бонус уже получен. Приходи завтра.")
    return res


# ══════════════════════════════════════════════════════════════════════════════
# SOUL — основная валюта (transferable, cap-эмиссия, динамический курс)
# ══════════════════════════════════════════════════════════════════════════════

SOUL_MIN_RATE = 100              # 1 Soul = 100 Gost минимум
SOUL_TRANSFER_FEE_BPS = 300      # 3% (в базисных пунктах: 10000bps = 100%)
NFT_MARKET_FEE_BPS = 1000        # 10% при покупке с маркета
NFT_TRANSFER_FEE_SOUL = 1        # 1 Soul за передачу NFT

def _economy_state(c) -> Optional[dict]:
    row = c.execute("SELECT * FROM soc_economy_state WHERE is_active=1 LIMIT 1").fetchone()
    return dict(row) if row else None

def compute_soul_rate(system_balance: int, cap: int) -> int:
    """Курс: сколько Gost за 1 Soul. Формула 100 × cap / system_balance.
    При system_balance=0 курс «приостановлен» (-1 как маркер)."""
    if system_balance <= 0: return -1
    return max(SOUL_MIN_RATE, round(SOUL_MIN_RATE * cap / system_balance))

def _credit_soul_tx(c, user_id, delta, source, counter=0, ref_type='', ref_id=0, note=None):
    """Записать tx + обновить баланс. Должно вызываться внутри уже открытой транзакции."""
    c.execute(
        "INSERT INTO soc_soul_tx (user_id, delta, source, counter_user_id, ref_type, ref_id, note) "
        "VALUES (?,?,?,?,?,?,?)",
        (user_id, delta, source, counter, ref_type, ref_id, note),
    )
    if user_id > 0:
        c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (user_id,))
        c.execute(
            "UPDATE soc_wallets SET soul = soul + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (delta, user_id),
        )

def _push_soul_event(user_id, delta, source, balance):
    """WS-уведомление владельцу о движении Soul."""
    ws_hub.send_to(user_id, "wallet.credit", {
        "currency": "soul", "delta": delta, "source": source, "balance": balance,
    })

def _soul_balance(c, user_id) -> int:
    row = c.execute("SELECT soul FROM soc_wallets WHERE user_id=?", (user_id,)).fetchone()
    return row["soul"] if row else 0


@router.get("/economy/state")
def economy_state(authorization: Optional[str] = Header(None)):
    """Состояние экономики: курс, системный баланс, сезон."""
    auth(authorization)  # любой авторизованный включая гостя
    c = db()
    state = _economy_state(c)
    c.close()
    if not state:
        raise HTTPException(503, "Экономика не инициализирована")
    rate = compute_soul_rate(state["system_balance"], state["cap"])
    return {
        "season_id": state["season_id"],
        "cap": state["cap"],
        "system_balance": state["system_balance"],
        "burned_total": state["burned_total"],
        "soul_rate_gost": rate,         # сколько Gost за 1 Soul (-1 если приостановлено)
        "rate_paused": rate == -1,
        "transfer_fee_bps": SOUL_TRANSFER_FEE_BPS,
        "market_fee_bps": NFT_MARKET_FEE_BPS,
        "nft_transfer_fee_soul": NFT_TRANSFER_FEE_SOUL,
    }


class SoulTransferBody(BaseModel):
    to_username: str
    amount: int
    note: Optional[str] = None


@router.post("/soul/transfer")
def soul_transfer(body: SoulTransferBody, authorization: Optional[str] = Header(None)):
    """Перевод Soul другому юзеру. Комиссия 3% сверху (платит отправитель).
    Минимум перевода: 1 Soul (значит итого спишется 1 + ceil(0.03) = 2)."""
    user = auth_member(authorization)
    _rate_limit(f"soul_tx:{user['id']}", limit=30, window=60)
    if body.amount <= 0:
        raise HTTPException(400, "Сумма должна быть положительной")
    if body.amount > 1_000_000:
        raise HTTPException(400, "Слишком большая сумма")
    to_username = (body.to_username or "").strip().lower()
    if to_username == user["username"]:
        raise HTTPException(400, "Нельзя перевести самому себе")
    note = (body.note or "").strip()[:200] if body.note else None

    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        recipient = c.execute("SELECT id, username, display_name FROM users WHERE username=?", (to_username,)).fetchone()
        if not recipient:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(404, "Получатель не найден")
        # Комиссия — округление вверх, минимум 1 Soul
        fee = max(1, (body.amount * SOUL_TRANSFER_FEE_BPS + 9999) // 10000)
        total_debit = body.amount + fee
        sender_bal = _soul_balance(c, user["id"])
        if sender_bal < total_debit:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Недостаточно Soul. Нужно {total_debit} (включая комиссию {fee}), у вас {sender_bal}")
        # 1) Списываем у отправителя сумму + комиссию (одной записью)
        _credit_soul_tx(c, user["id"], -total_debit, 'transfer_out',
                        counter=recipient["id"], note=note)
        # 2) Зачисляем получателю
        _credit_soul_tx(c, recipient["id"], body.amount, 'transfer_in',
                        counter=user["id"], note=note)
        # 3) Комиссия → system_balance
        c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (fee,))
        sender_new = _soul_balance(c, user["id"])
        recipient_new = _soul_balance(c, recipient["id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise HTTPException(500, f"Ошибка перевода: {e}")
    c.close()
    _push_soul_event(user["id"], -total_debit, 'transfer_out', sender_new)
    _push_soul_event(recipient["id"], body.amount, 'transfer_in', recipient_new)
    return {"status": "ok", "fee": fee, "new_balance": sender_new,
            "recipient": {"username": recipient["username"], "display_name": recipient["display_name"]}}


@router.get("/soul/tx")
def soul_tx_history(offset: int = Query(0, ge=0), authorization: Optional[str] = Header(None)):
    """История моих Soul-транзакций."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute(
        "SELECT id, delta, source, counter_user_id, ref_type, ref_id, note, created_at "
        "FROM soc_soul_tx WHERE user_id=? ORDER BY id DESC LIMIT 30 OFFSET ?",
        (user["id"], offset),
    ).fetchall()
    counter_ids = list({r["counter_user_id"] for r in rows if r["counter_user_id"]})
    counter_map = {}
    if counter_ids:
        ph = ",".join("?" * len(counter_ids))
        for u in c.execute(f"SELECT id, username, display_name, is_official FROM users WHERE id IN ({ph})", counter_ids):
            counter_map[u["id"]] = {"username": u["username"], "display_name": u["display_name"], "is_official": bool(u["is_official"])}
    c.close()
    return {
        "transactions": [
            {
                "id": r["id"], "delta": r["delta"], "source": r["source"],
                "ref_type": r["ref_type"], "ref_id": r["ref_id"], "note": r["note"],
                "counter": counter_map.get(r["counter_user_id"]),
                "created_at": r["created_at"],
            }
            for r in rows
        ],
        "has_more": len(rows) == 30,
    }


class AdminEmitBody(BaseModel):
    amount: int
    token: str  # admin-secret (env)

@router.post("/admin/economy/emit")
def admin_emit(body: AdminEmitBody, authorization: Optional[str] = Header(None)):
    """Эмиссия Soul в system_balance (только админ). amount может быть отрицательным (изъятие)."""
    admin_token = os.environ.get('GE_ADMIN_TOKEN', '')
    if not admin_token or body.token != admin_token:
        raise HTTPException(403, "Forbidden")
    if abs(body.amount) > 10_000_000:
        raise HTTPException(400, "Слишком большая сумма")
    c = db()
    state = _economy_state(c)
    if not state:
        c.close(); raise HTTPException(503, "Сезон не активен")
    new_bal = max(0, state["system_balance"] + body.amount)
    c.execute("UPDATE soc_economy_state SET system_balance=? WHERE season_id=?", (new_bal, state["season_id"]))
    c.commit(); c.close()
    return {"status": "ok", "system_balance": new_bal, "delta": body.amount}


# ══════════════════════════════════════════════════════════════════════════════
# NFT — каталог, владение, маркет, передача
# ══════════════════════════════════════════════════════════════════════════════

def _nft_card(row: dict) -> dict:
    """Унифицированный формат NFT для API."""
    return {
        "id": row["id"],
        "serial": row["serial"],
        "owner": {
            "id": row["owner_id"],
            "username": row.get("owner_username"),
            "display_name": row.get("owner_display_name"),
            "is_official": bool(row.get("owner_is_official", 0)),
        },
        "catalog": {
            "id": row["catalog_id"],
            "slug": row["catalog_slug"],
            "name": row["catalog_name"],
            "rarity": row["catalog_rarity"],
            "max_supply": row["catalog_max_supply"],
        },
        "listing": (
            {"id": row["listing_id"], "price_soul": row["listing_price"]}
            if row.get("listing_id") else None
        ),
    }

_NFT_JOIN_SQL = """
    SELECT n.id, n.serial, n.owner_id, n.catalog_id,
           u.username as owner_username, u.display_name as owner_display_name, u.is_official as owner_is_official,
           cat.slug as catalog_slug, cat.name as catalog_name, cat.rarity as catalog_rarity, cat.max_supply as catalog_max_supply,
           l.id as listing_id, l.price_soul as listing_price
    FROM soc_nfts n
    JOIN users u ON u.id = n.owner_id
    JOIN soc_nft_catalog cat ON cat.id = n.catalog_id
    LEFT JOIN soc_nft_listings l ON l.nft_id = n.id
"""


@router.get("/nft/catalog")
def nft_catalog(authorization: Optional[str] = Header(None)):
    """Список всех типов NFT в каталоге."""
    auth(authorization)
    c = db()
    rows = c.execute("""
        SELECT cat.*, u.username as creator_username, u.display_name as creator_display_name, u.is_official as creator_is_official,
               (SELECT COUNT(*) FROM soc_nfts n WHERE n.catalog_id = cat.id) as minted,
               (SELECT COUNT(*) FROM soc_nft_listings l JOIN soc_nfts n ON l.nft_id=n.id WHERE n.catalog_id = cat.id) as listed,
               (SELECT MIN(l.price_soul) FROM soc_nft_listings l JOIN soc_nfts n ON l.nft_id=n.id WHERE n.catalog_id = cat.id) as floor_price
        FROM soc_nft_catalog cat
        JOIN users u ON u.id = cat.creator_id
        ORDER BY cat.id ASC
    """).fetchall()
    c.close()
    return {
        "catalog": [
            {
                "id": r["id"], "slug": r["slug"], "name": r["name"], "description": r["description"],
                "rarity": r["rarity"], "max_supply": r["max_supply"],
                "minted": r["minted"], "listed": r["listed"],
                "floor_price_soul": r["floor_price"],
                "start_price_soul": r["start_price_soul"],
                "creator": {
                    "username": r["creator_username"],
                    "display_name": r["creator_display_name"],
                    "is_official": bool(r["creator_is_official"]),
                },
            }
            for r in rows
        ]
    }


@router.get("/nft/my")
def nft_my(authorization: Optional[str] = Header(None)):
    """Мои NFT (с пометкой выставлен ли на рынок)."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute(_NFT_JOIN_SQL + " WHERE n.owner_id=? ORDER BY n.id DESC", (user["id"],)).fetchall()
    c.close()
    return {"nfts": [_nft_card(dict(r)) for r in rows]}


@router.get("/nft/listings")
def nft_listings(slug: Optional[str] = Query(None), sort: str = Query("price_asc"),
                  offset: int = Query(0, ge=0), authorization: Optional[str] = Header(None)):
    """Активные листинги маркета. Можно фильтровать по slug каталога."""
    auth(authorization)
    order = {"price_asc": "l.price_soul ASC", "price_desc": "l.price_soul DESC", "new": "l.id DESC"}.get(sort, "l.price_soul ASC")
    c = db()
    sql = _NFT_JOIN_SQL + " WHERE l.id IS NOT NULL"
    params: list = []
    if slug:
        sql += " AND cat.slug=?"; params.append(slug)
    sql += f" ORDER BY {order} LIMIT 30 OFFSET ?"
    params.append(offset)
    rows = c.execute(sql, params).fetchall()
    c.close()
    return {"listings": [_nft_card(dict(r)) for r in rows], "has_more": len(rows) == 30}


class NftListBody(BaseModel):
    nft_id: int
    price_soul: int


@router.post("/nft/list")
def nft_list_for_sale(body: NftListBody, authorization: Optional[str] = Header(None)):
    """Выставить свой NFT на маркет."""
    user = auth_member(authorization)
    _rate_limit(f"nftlist:{user['id']}", limit=30, window=60)
    if body.price_soul <= 0 or body.price_soul > 1_000_000:
        raise HTTPException(400, "Цена должна быть от 1 до 1 000 000 Soul")
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        nft = c.execute("SELECT owner_id FROM soc_nfts WHERE id=?", (body.nft_id,)).fetchone()
        if not nft:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "NFT не найден")
        if nft["owner_id"] != user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(403, "Это не ваш NFT")
        existing = c.execute("SELECT id FROM soc_nft_listings WHERE nft_id=?", (body.nft_id,)).fetchone()
        if existing:
            c.execute("UPDATE soc_nft_listings SET price_soul=? WHERE nft_id=?", (body.price_soul, body.nft_id))
        else:
            c.execute("INSERT INTO soc_nft_listings (nft_id, seller_id, price_soul) VALUES (?,?,?)",
                      (body.nft_id, user["id"], body.price_soul))
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    return {"status": "ok"}


@router.delete("/nft/list/{nft_id}")
def nft_unlist(nft_id: int, authorization: Optional[str] = Header(None)):
    """Снять свой NFT с маркета."""
    user = auth_member(authorization)
    c = db()
    row = c.execute("SELECT seller_id FROM soc_nft_listings WHERE nft_id=?", (nft_id,)).fetchone()
    if not row:
        c.close(); raise HTTPException(404, "Не выставлен")
    if row["seller_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Не ваш листинг")
    c.execute("DELETE FROM soc_nft_listings WHERE nft_id=?", (nft_id,))
    c.commit(); c.close()
    return {"status": "ok"}


@router.post("/nft/buy/{nft_id}")
def nft_buy(nft_id: int, authorization: Optional[str] = Header(None)):
    """Купить NFT с маркета. Покупатель платит price + 10% комиссия системе."""
    user = auth_member(authorization)
    _rate_limit(f"nftbuy:{user['id']}", limit=30, window=60)
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        lst = c.execute(
            "SELECT l.id as lid, l.price_soul, l.seller_id, n.id as nft_id, n.owner_id, n.catalog_id "
            "FROM soc_nft_listings l JOIN soc_nfts n ON l.nft_id=n.id WHERE l.nft_id=?",
            (nft_id,),
        ).fetchone()
        if not lst:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "Не продаётся")
        if lst["seller_id"] == user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(400, "Нельзя купить свой NFT")
        price = lst["price_soul"]
        fee = max(1, (price * NFT_MARKET_FEE_BPS + 9999) // 10000)
        buyer_bal = _soul_balance(c, user["id"])
        if buyer_bal < price + fee:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Недостаточно Soul. Цена {price} + комиссия {fee} = {price+fee}, у вас {buyer_bal}")
        # Списываем у покупателя: цена + комиссия
        _credit_soul_tx(c, user["id"], -(price + fee), 'nft_buy',
                        counter=lst["seller_id"], ref_type='nft', ref_id=nft_id)
        # Продавцу — цена (без комиссии)
        # Если продавец GhostEcos — это «системная продажа», 10% комиссия СЖИГАЕТСЯ, а цена идёт в system_balance
        seller_official = c.execute("SELECT is_official FROM users WHERE id=?", (lst["seller_id"],)).fetchone()
        if seller_official and seller_official["is_official"]:
            # Системная продажа: цена идёт системе, комиссия сжигается
            c.execute("UPDATE soc_economy_state SET system_balance = system_balance - ?, burned_total = burned_total + ? WHERE is_active=1",
                      (price, fee))
            # tx для системного юзера (как «отдала NFT»)
            _credit_soul_tx(c, lst["seller_id"], 0, 'nft_sell',  # 0 delta — балланс не меняется
                            counter=user["id"], ref_type='nft', ref_id=nft_id, note=f'sold for {price}, burn {fee}')
        else:
            # P2P-продажа: цена продавцу, комиссия системе
            _credit_soul_tx(c, lst["seller_id"], price, 'nft_sell',
                            counter=user["id"], ref_type='nft', ref_id=nft_id)
            c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (fee,))
        # Передача NFT
        c.execute("UPDATE soc_nfts SET owner_id=? WHERE id=?", (user["id"], nft_id))
        c.execute("DELETE FROM soc_nft_listings WHERE nft_id=?", (nft_id,))
        buyer_new = _soul_balance(c, user["id"])
        seller_new = _soul_balance(c, lst["seller_id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise HTTPException(500, f"Ошибка покупки: {e}")
    c.close()
    _push_soul_event(user["id"], -(price + fee), 'nft_buy', buyer_new)
    if not (seller_official and seller_official["is_official"]):
        _push_soul_event(lst["seller_id"], price, 'nft_sell', seller_new)
    ws_hub.broadcast("nft.sold", {"nft_id": nft_id})
    return {"status": "ok", "price": price, "fee": fee, "new_balance": buyer_new}


class NftTransferBody(BaseModel):
    nft_id: int
    to_username: str
    note: Optional[str] = None


@router.post("/nft/transfer")
def nft_transfer(body: NftTransferBody, authorization: Optional[str] = Header(None)):
    """Передать NFT юзеру. Комиссия — 1 Soul."""
    user = auth_member(authorization)
    _rate_limit(f"nfttx:{user['id']}", limit=30, window=60)
    to_username = (body.to_username or "").strip().lower()
    if to_username == user["username"]:
        raise HTTPException(400, "Нельзя передать самому себе")
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        nft = c.execute("SELECT owner_id FROM soc_nfts WHERE id=?", (body.nft_id,)).fetchone()
        if not nft:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "NFT не найден")
        if nft["owner_id"] != user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(403, "Не ваш NFT")
        recipient = c.execute("SELECT id, username, display_name FROM users WHERE username=?", (to_username,)).fetchone()
        if not recipient:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "Получатель не найден")
        # Комиссия — 1 Soul
        sender_bal = _soul_balance(c, user["id"])
        if sender_bal < NFT_TRANSFER_FEE_SOUL:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Нужно {NFT_TRANSFER_FEE_SOUL} Soul для оплаты комиссии передачи")
        _credit_soul_tx(c, user["id"], -NFT_TRANSFER_FEE_SOUL, 'nft_fee',
                        counter=recipient["id"], ref_type='nft', ref_id=body.nft_id)
        c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (NFT_TRANSFER_FEE_SOUL,))
        # Снимаем с маркета если был выставлен
        c.execute("DELETE FROM soc_nft_listings WHERE nft_id=?", (body.nft_id,))
        # Передаём
        c.execute("UPDATE soc_nfts SET owner_id=? WHERE id=?", (recipient["id"], body.nft_id))
        sender_new = _soul_balance(c, user["id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise HTTPException(500, f"Ошибка передачи: {e}")
    c.close()
    _push_soul_event(user["id"], -NFT_TRANSFER_FEE_SOUL, 'nft_fee', sender_new)
    ws_hub.send_to(recipient["id"], "nft.received", {"nft_id": body.nft_id, "from": user["username"]})
    return {"status": "ok", "fee": NFT_TRANSFER_FEE_SOUL,
            "recipient": {"username": recipient["username"], "display_name": recipient["display_name"]}}
