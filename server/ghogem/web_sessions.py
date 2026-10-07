"""Signed, short-lived HttpOnly sessions for GhoGem web visitors."""
import base64
import hashlib
import hmac
import json
import os
import pathlib
import secrets
import time

COOKIE = '__Host-ghogem_session'
TTL = 24 * 60 * 60
_key_file = pathlib.Path(__file__).with_name('.web_session_key')
if not _key_file.exists():
    try:
        fd = os.open(_key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(secrets.token_bytes(64))
_KEY = _key_file.read_bytes()
if len(_KEY) < 32:
    raise RuntimeError('Invalid web session key')

def _encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode('ascii')

def _decode(value):
    return base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))

def new_guest_uid():
    # Negative IDs are disjoint from Telegram and GhostEcos namespaces.
    return -(2 ** 60 + secrets.randbits(60))

def issue(guest_uid, tg_user=None):
    now = int(time.time())
    data = {'g':int(guest_uid),'iat':now,'exp':now + TTL}
    if tg_user and int(tg_user.get('id', 0)) > 0:
        data['tg'] = {'id':int(tg_user['id'])}
        for key in ['username','first_name','last_name']:
            if tg_user.get(key):
                data['tg'][key] = str(tg_user[key])[:128]
    payload = _encode(json.dumps(data, separators=(',',':'), ensure_ascii=False).encode())
    signature = _encode(hmac.new(_KEY, payload.encode(), hashlib.sha256).digest())
    return payload + '.' + signature

def read(token):
    if not token or len(token) > 2048:
        return None
    try:
        payload, signature = token.split('.')
        expected = hmac.new(_KEY, payload.encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(_decode(signature), expected):
            return None
        data = json.loads(_decode(payload))
        now = int(time.time())
        if not (now - TTL <= int(data['iat']) <= now + 30 and now < int(data['exp']) <= int(data['iat']) + TTL):
            return None
        if not -(2 ** 61) < int(data['g']) <= -(2 ** 60):
            return None
        if 'tg' in data and not isinstance(data['tg'], dict):
            return None
        return data
    except (ValueError, TypeError, KeyError, UnicodeError):
        return None

def set_cookie(response, token):
    response.set_cookie(COOKIE, token, max_age=TTL, secure=True, httponly=True, samesite='lax', path='/')

