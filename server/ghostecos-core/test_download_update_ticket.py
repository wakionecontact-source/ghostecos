import unittest
from unittest.mock import patch

_SERVER_DEPENDENCY_ERROR = None
try:
    from fastapi import HTTPException
    from starlette.requests import Request

    import config
    import routers.downloads as downloads
except ModuleNotFoundError as error:
    _SERVER_DEPENDENCY_ERROR = error.name
    HTTPException = Request = config = downloads = None


def _request(headers=None):
    return Request(
        {
            "type": "http",
            "asgi": {"version": "3.0"},
            "http_version": "1.1",
            "method": "POST",
            "scheme": "https",
            "path": "/api/download/update-ticket",
            "raw_path": b"/api/download/update-ticket",
            "query_string": b"",
            "headers": [
                (name.lower().encode(), value.encode())
                for name, value in (headers or {}).items()
            ],
            "client": ("203.0.113.5", 43120),
            "server": ("ghostecos.duckdns.org", 443),
        }
    )


@unittest.skipIf(
    _SERVER_DEPENDENCY_ERROR is not None,
    f"server dependencies unavailable: {_SERVER_DEPENDENCY_ERROR}",
)
class UpdateTicketTests(unittest.TestCase):
    def setUp(self):
        with downloads._state_lock:
            downloads._tickets.clear()

    def test_ticket_is_resumable_and_can_follow_download_manager_network_changes(self):
        with patch("routers.downloads._version_item") as version_item, patch(
            "routers.downloads._release_open", return_value=True
        ), patch("routers.downloads.bot_check.consume_bot_token") as consume_token:
            version_item.return_value = {
                "path": "/tmp/GhostChat.apk",
                "filename": "GhostChat.apk",
            }
            with patch.object(config, "LATEST_VERSION", "1.2.2"):
                result = downloads.update_ticket(
                    downloads.UpdateBody(version="1.2.2"),
                    _request({"X-Ghost-Bot-Token": "captcha-token"}),
                )

        self.assertTrue(result["download_url"].startswith("/api/download/file/"))
        self.assertGreater(result["expires_in"], 0)
        ticket = result["download_url"].rsplit("/", 1)[-1]
        self.assertEqual(downloads._tickets[ticket]["ip"], "203.0.113.5")
        self.assertEqual(downloads._tickets[ticket]["path"], "/tmp/GhostChat.apk")
        self.assertFalse(downloads._tickets[ticket]["one_use"])
        self.assertTrue(downloads._tickets[ticket]["allow_ip_change"])
        consume_token.assert_called_once_with("captcha-token", "download")

    def test_ticket_rejects_a_version_that_is_no_longer_latest(self):
        with patch("routers.downloads._version_item") as version_item:
            with patch.object(config, "LATEST_VERSION", "1.2.3"):
                with self.assertRaises(HTTPException) as raised:
                    downloads.update_ticket(
                        downloads.UpdateBody(version="1.2.2"), _request()
                    )

        self.assertEqual(raised.exception.status_code, 409)
        version_item.assert_not_called()


if __name__ == "__main__":
    unittest.main()
