import unittest

from app_config_ota import APP_CONFIG_BUNDLES, updates_for_client


class AppConfigOtaTests(unittest.TestCase):
    def setUp(self):
        self.bundle = {
            "id": "network.transport",
            "revision": 3,
            "title": "Сеть",
            "category": "network",
            "min_app_version": "1.2.2",
            "settings": [
                {
                    "id": "prefer_relay",
                    "type": "toggle",
                    "title": "Предпочитать relay",
                    "description": "Пример ограниченной OTA-настройки.",
                    "default": False,
                }
            ],
        }

    def test_first_install_receives_bundle(self):
        result = updates_for_client(
            "1.2.2", [], latest_version="1.2.2", bundles=[self.bundle]
        )
        self.assertTrue(result["eligible"])
        self.assertEqual([self.bundle], result["bundles"])

    def test_real_appearance_bundle_is_sent_once(self):
        first = updates_for_client("1.2.2", [], latest_version="1.2.2")
        self.assertEqual(1, len(first["bundles"]))
        self.assertEqual("appearance.chat_list", first["bundles"][0]["id"])

        installed = [
            {"id": item["id"], "revision": item["revision"]}
            for item in first["bundles"]
        ]
        second = updates_for_client(
            "1.2.2", installed, latest_version="1.2.2"
        )
        self.assertEqual([], second["bundles"])

    def test_same_revision_is_not_downloaded_again(self):
        result = updates_for_client(
            "1.2.2",
            [{"id": "network.transport", "revision": 3}],
            latest_version="1.2.2",
            bundles=[self.bundle],
        )
        self.assertEqual([], result["bundles"])

    def test_changed_revision_is_sent_and_retired_id_is_removed(self):
        result = updates_for_client(
            "1.2.2",
            [
                {"id": "network.transport", "revision": 2},
                {"id": "old.bundle", "revision": 1},
            ],
            latest_version="1.2.2",
            bundles=[self.bundle],
            retired_ids=["old.bundle"],
        )
        self.assertEqual([self.bundle], result["bundles"])
        self.assertEqual(["old.bundle"], result["retired"])

    def test_non_latest_and_legacy_clients_receive_no_config(self):
        for version in ("1.2.1", "1.2.3"):
            with self.subTest(version=version):
                result = updates_for_client(
                    version,
                    [],
                    latest_version="1.2.2",
                    bundles=[self.bundle],
                )
                self.assertFalse(result["eligible"])
                self.assertEqual([], result["bundles"])

    def test_remote_code_type_is_rejected(self):
        unsafe = {
            **self.bundle,
            "settings": [
                {
                    "id": "run_code",
                    "type": "javascript",
                    "title": "Code",
                }
            ],
        }
        with self.assertRaises(ValueError):
            updates_for_client("1.2.2", [], latest_version="1.2.2", bundles=[unsafe])


if __name__ == "__main__":
    unittest.main()
