import hashlib
import hashlib
import os
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch

import sso


class SsoTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.gs_db = os.path.join(self.tmp.name, "ghostchat.db")
        self.link_db = os.path.join(self.tmp.name, "subscriptions.db")
        c = sqlite3.connect(self.gs_db)
        c.executescript(
            """
            CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, display_name TEXT, avatar_url TEXT);
            CREATE TABLE soc_tokens (user_id INTEGER, token TEXT);
            CREATE TABLE user_devices (
                user_id INTEGER, token TEXT, is_active INTEGER, is_blocked INTEGER
            );
            INSERT INTO users VALUES (7, 'waki', 'Waki', '/media/avatars/waki.jpg');
            INSERT INTO soc_tokens VALUES (7, 'web-token-valid');
            INSERT INTO user_devices VALUES (7, 'device-token-valid', 1, 0);
            """
        )
        c.commit()
        c.close()
        self.paths = patch.multiple(sso, GS_DB_PATH=self.gs_db, LINK_DB_PATH=self.link_db)
        self.paths.start()
        sso._token_cache.clear()
        sso._init_link_db()

    def tearDown(self):
        self.paths.stop()
        sso._token_cache.clear()
        self.tmp.cleanup()

    def test_resolves_web_and_device_tokens(self):
        self.assertEqual(sso.resolve_gs_token("web-token-valid")["id"], 7)
        self.assertEqual(sso.resolve_gs_token("device-token-valid")["username"], "waki")
        self.assertIsNone(sso.resolve_gs_token("guest_not_an_account"))

    def test_link_code_is_single_use(self):
        code = sso.link_code_issue(7, "waki")
        ok, _message, _moved = sso.link_code_redeem(code, 12345)
        self.assertTrue(ok)
        self.assertEqual(sso.link_by_gs(7)["tg_id"], 12345)
        ok, message, _moved = sso.link_code_redeem(code, 54321)
        self.assertFalse(ok)
        self.assertIn("использован", message)

    def test_expired_link_code_is_rejected(self):
        code = sso.link_code_issue(7, "waki")
        c = sqlite3.connect(self.link_db)
        c.execute(
            "UPDATE gs_link_codes SET created_at=? WHERE code=?",
            (int(time.time()) - sso.LINK_CODE_TTL - 1, code),
        )
        c.commit()
        c.close()
        ok, message, _moved = sso.link_code_redeem(code, 12345)
        self.assertFalse(ok)
        self.assertIn("истёк", message)

    def test_webapp_code_is_bound_single_use_and_saved_in_bot_users(self):
        code, ttl = sso.webapp_login_code_issue(7, "waki", 12345)
        self.assertEqual(ttl, sso.WEBAPP_LOGIN_CODE_TTL)

        ok, message, _moved, account = sso.webapp_login_code_redeem(code, 54321)
        self.assertFalse(ok)
        self.assertIn("другого Telegram", message)

        ok, message, _moved, account = sso.webapp_login_code_redeem(code, 12345)
        self.assertTrue(ok)
        self.assertIn("успешно", message)
        self.assertEqual(account, {"gs_user_id": 7, "gs_username": "waki"})
        self.assertEqual(sso.link_by_tg(12345)["gs_user_id"], 7)

        c = sqlite3.connect(self.link_db)
        row = c.execute(
            "SELECT gs_user_id, gs_username, gs_linked_at FROM users WHERE user_id=?",
            (12345,),
        ).fetchone()
        stored_hash = c.execute(
            "SELECT code_hash FROM gs_webapp_login_codes"
        ).fetchone()[0]
        c.close()
        self.assertEqual(row[0:2], (7, "waki"))
        self.assertEqual(stored_hash, hashlib.sha256(code.encode()).hexdigest())

        ok, message, _moved, _account = sso.webapp_login_code_redeem(code, 12345)
        self.assertFalse(ok)
        self.assertIn("использована", message)

    def test_external_browser_code_binds_on_redemption_and_is_single_use(self):
        # Firefox has no signed Telegram initData. An unbound short-lived code
        # must attach to the Telegram user who redeems it, then reject reuse.
        code, ttl = sso.webapp_login_code_issue(
            7, "waki", 0, terms_version="2026-09-29", privacy_version="2026-09-29"
        )
        self.assertEqual(ttl, sso.WEBAPP_LOGIN_CODE_TTL)

        ok, message, _moved, account = sso.webapp_login_code_redeem(code, 12345)
        self.assertTrue(ok)
        self.assertIn("успешно", message)
        self.assertEqual(account, {"gs_user_id": 7, "gs_username": "waki"})
        self.assertEqual(sso.link_by_tg(12345)["gs_user_id"], 7)

        c = sqlite3.connect(self.link_db)
        consent = c.execute(
            "SELECT gs_user_id, tg_id, client_id, terms_version, privacy_version "
            "FROM sso_service_consents"
        ).fetchone()
        c.close()
        self.assertEqual(
            consent, (7, 12345, "ghogem_bot", "2026-09-29", "2026-09-29")
        )

        ok, message, _moved, _account = sso.webapp_login_code_redeem(code, 12345)
        self.assertFalse(ok)
        self.assertIn("использована", message)

    def test_webapp_code_is_scoped_to_client(self):
        code, _ttl = sso.webapp_login_code_issue(7, "waki", 12345, client_id="ghogem_bot")

        ok, message, _moved, _account = sso.webapp_login_code_redeem(
            code, 12345, client_id="another_service"
        )
        self.assertFalse(ok)
        self.assertIn("другого сервиса", message)

        ok, message, _moved, account = sso.webapp_login_code_redeem(
            code, 12345, client_id="ghogem_bot"
        )
        self.assertTrue(ok)
        self.assertEqual(account["gs_user_id"], 7)

    def test_service_consent_is_recorded(self):
        sso.record_service_consent(7, 12345, "ghogem_bot", "2026-09-28", "2026-09-28")
        c = sqlite3.connect(self.link_db)
        row = c.execute(
            "SELECT gs_user_id, tg_id, client_id, terms_version, privacy_version "
            "FROM sso_service_consents"
        ).fetchone()
        c.close()
        self.assertEqual(row, (7, 12345, "ghogem_bot", "2026-09-28", "2026-09-28"))

    def test_expired_webapp_code_is_rejected(self):
        code, _ttl = sso.webapp_login_code_issue(7, "waki", 12345)
        code_hash = hashlib.sha256(code.encode()).hexdigest()
        c = sqlite3.connect(self.link_db)
        c.execute(
            "UPDATE gs_webapp_login_codes SET expires_at=? WHERE code_hash=?",
            (int(time.time()) - 1, code_hash),
        )
        c.commit()
        c.close()

        ok, message, _moved, account = sso.webapp_login_code_redeem(code, 12345)
        self.assertFalse(ok)
        self.assertIn("истёк", message)
        self.assertIsNone(account)

    def test_unlink_clears_bot_user_profile_and_revokes_pending_login_codes(self):
        code, _ttl = sso.webapp_login_code_issue(7, "waki", 12345)
        ok, _message, _moved, _account = sso.webapp_login_code_redeem(code, 12345)
        self.assertTrue(ok)
        stale_code, _ttl = sso.webapp_login_code_issue(7, "waki", 12345)
        self.assertTrue(sso.link_delete_by_gs(7))

        ok, message, _moved, account = sso.webapp_login_code_redeem(stale_code, 54321)
        self.assertFalse(ok)
        self.assertIn("отозвана", message)
        self.assertIsNone(account)

        c = sqlite3.connect(self.link_db)
        row = c.execute(
            "SELECT gs_user_id, gs_username, gs_linked_at FROM users WHERE user_id=?",
            (12345,),
        ).fetchone()
        c.close()
        self.assertEqual(row, (None, None, None))


if __name__ == "__main__":
    unittest.main()
