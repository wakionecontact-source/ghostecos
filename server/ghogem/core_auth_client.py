"""Restricted loopback client for GhostEcos public identity information."""
from __future__ import annotations
import hashlib
import hmac
import json
import os
import secrets
import time
import urllib.error
import urllib.request

RESOLVE_PATH = '/internal/v1/identity/resolve'
PROFILE_PATH = '/internal/v1/identity/public-profile'
_PATHS = frozenset((RESOLVE_PATH, PROFILE_PATH))

class CoreUnavailable(RuntimeError):
    pass

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def _post(path: str, payload: dict):
    if path not in _PATHS:
        raise ValueError('Unsupported identity endpoint')
    key = os.environ.get('GE_INTERNAL_KEY_GHOGEM', '')
    if len(key) < 32:
        raise CoreUnavailable('Identity service key is unavailable')
    body = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
    if len(body) > 65536:
        raise ValueError('Identity request is too large')
    timestamp, nonce = str(int(time.time())), secrets.token_hex(24)
    prefix = f'{timestamp}\n{nonce}\nPOST\n{path}\n'.encode()
    signature = hmac.new(key.encode(), prefix + body, hashlib.sha256).hexdigest()
    request = urllib.request.Request('http://127.0.0.1:8002' + path, body, method='POST', headers={
        'Content-Type': 'application/json', 'X-GE-Service': 'ghogem',
        'X-GE-Timestamp': timestamp, 'X-GE-Nonce': nonce, 'X-GE-Signature': signature,
    })
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    try:
        with opener.open(request, timeout=5) as response:
            raw = response.read(65537)
    except urllib.error.HTTPError as exc:
        if path == RESOLVE_PATH and exc.code == 401:
            raw_error = exc.read(4096)
            try:
                detail = json.loads(raw_error).get('detail')
            except (ValueError, TypeError, AttributeError):
                detail = None
            if detail in ('Invalid token', 'Token revoked', 'Missing token'):
                return None
        raise CoreUnavailable('Identity service rejected the request') from None
    except (OSError, urllib.error.URLError) as exc:
        raise CoreUnavailable('Identity service is unavailable') from None
    if len(raw) > 65536:
        raise CoreUnavailable('Identity response is too large')
    try:
        result = json.loads(raw)
    except (ValueError, UnicodeError):
        raise CoreUnavailable('Invalid identity response') from None
    if not isinstance(result, dict):
        raise CoreUnavailable('Invalid identity response')
    return result

def resolve_token(token: str):
    return _post(RESOLVE_PATH, {'token': token})

def profile_by_id(user_id: int):
    result = _post(PROFILE_PATH, {'user_id': int(user_id)})
    user = result.get('user')
    if user is not None and not isinstance(user, dict):
        raise CoreUnavailable('Invalid public profile response')
    return user
