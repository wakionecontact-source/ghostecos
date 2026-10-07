"""Self-hosted declarative settings bundles for GhostChat's config OTA.

Add or revise entries in ``APP_CONFIG_BUNDLES`` and deploy the server. Clients
report the bundle IDs and revisions already cached on-device; this module
returns only missing or changed bundles. Values chosen by users are stored
separately by the app and are not part of these definitions.

Only declarative controls are accepted (toggle/select/slider/text). This is
deliberately not a remote-code, HTML, or JavaScript execution mechanism.
"""

from __future__ import annotations

import copy
import json
import re
from typing import Any


MIN_CLIENT_VERSION = "1.2.2"

# Add server-delivered settings here. Increment ``revision`` when an existing
# bundle changes; clients will replace the cached schema without overwriting
# the values users have already chosen.
APP_CONFIG_BUNDLES: list[dict[str, Any]] = [
    {
        "id": "appearance.chat_list",
        "revision": 1,
        "title": "Список чатов",
        "category": "appearance",
        "min_app_version": "1.2.2",
        "settings": [
            {
                "id": "compact",
                "type": "toggle",
                "title": "Компактный список",
                "description": "Уменьшает высоту строк в списке личных чатов.",
                "default": False,
            },
        ],
    },
]

# Keep IDs here when a previously released bundle should disappear from clients.
# Their locally saved values remain dormant, so a later re-release can restore them.
RETIRED_BUNDLE_IDS: list[str] = []

_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
_ALLOWED_CATEGORIES = {"network", "appearance"}
_ALLOWED_TYPES = {"toggle", "select", "slider", "text"}


def _version_key(value: str) -> tuple[int, int, int, int] | None:
    match = re.fullmatch(r"v?(\d+(?:\.\d+){0,3})(?:\+\d+)?", value.strip())
    if not match:
        return None
    parts = tuple(int(part) for part in match.group(1).split("."))
    return (parts + (0, 0, 0, 0))[:4]


def _validate_bundle(bundle: Any) -> tuple[str, int, tuple[int, int, int, int]]:
    if not isinstance(bundle, dict):
        raise ValueError("OTA bundle must be an object")
    bundle_id = bundle.get("id")
    revision = bundle.get("revision")
    title = bundle.get("title")
    category = bundle.get("category")
    min_version = bundle.get("min_app_version", MIN_CLIENT_VERSION)
    settings = bundle.get("settings")
    min_key = _version_key(min_version) if isinstance(min_version, str) else None
    if (
        not isinstance(bundle_id, str)
        or not _ID_RE.fullmatch(bundle_id)
        or not isinstance(revision, int)
        or isinstance(revision, bool)
        or revision < 1
        or not isinstance(title, str)
        or not title.strip()
        or len(title) > 100
        or not isinstance(category, str)
        or category not in _ALLOWED_CATEGORIES
        or min_key is None
        or not isinstance(settings, list)
        or not 1 <= len(settings) <= 30
    ):
        raise ValueError(f"invalid OTA bundle metadata: {bundle_id!r}")

    setting_ids: set[str] = set()
    for setting in settings:
        if not isinstance(setting, dict):
            raise ValueError(f"invalid setting in bundle {bundle_id}")
        setting_id = setting.get("id")
        kind = setting.get("type")
        setting_title = setting.get("title")
        description = setting.get("description", "")
        if (
            not isinstance(setting_id, str)
            or not _ID_RE.fullmatch(setting_id)
            or setting_id in setting_ids
            or not isinstance(kind, str)
            or kind not in _ALLOWED_TYPES
            or not isinstance(setting_title, str)
            or not setting_title.strip()
            or len(setting_title) > 100
            or not isinstance(description, str)
            or len(description) > 240
        ):
            raise ValueError(f"invalid setting metadata in bundle {bundle_id}")
        setting_ids.add(setting_id)

        if kind == "toggle" and "default" in setting and not isinstance(setting["default"], bool):
            raise ValueError(f"toggle default must be boolean in {bundle_id}.{setting_id}")
        if kind == "select":
            options = setting.get("options")
            if not isinstance(options, list) or not 1 <= len(options) <= 30:
                raise ValueError(f"select requires 1..30 options in {bundle_id}.{setting_id}")
            values: set[str] = set()
            for option in options:
                if not isinstance(option, dict):
                    raise ValueError(f"invalid option in {bundle_id}.{setting_id}")
                value, label = option.get("value"), option.get("label")
                if (
                    not isinstance(value, str)
                    or not value
                    or len(value) > 80
                    or value in values
                    or not isinstance(label, str)
                    or not label.strip()
                    or len(label) > 80
                ):
                    raise ValueError(f"invalid option in {bundle_id}.{setting_id}")
                values.add(value)
            if setting.get("default", options[0]["value"]) not in values:
                raise ValueError(f"select default is not an option in {bundle_id}.{setting_id}")
        if kind == "slider":
            low, high, default = (
                setting.get("min"),
                setting.get("max"),
                setting.get("default"),
            )
            if (
                not all(isinstance(value, (int, float)) and not isinstance(value, bool) for value in (low, high, default))
                or not low < high
                or low < -10000
                or high > 10000
                or not low <= default <= high
            ):
                raise ValueError(f"invalid slider range in {bundle_id}.{setting_id}")
            steps = setting.get("steps")
            if steps is not None and (not isinstance(steps, int) or isinstance(steps, bool) or not 1 <= steps <= 100):
                raise ValueError(f"invalid slider steps in {bundle_id}.{setting_id}")
        if kind == "text":
            max_length = setting.get("max_length", 160)
            default = setting.get("default", "")
            if (
                not isinstance(max_length, int)
                or isinstance(max_length, bool)
                or not 1 <= max_length <= 512
                or not isinstance(default, str)
                or len(default) > max_length
            ):
                raise ValueError(f"invalid text setting in {bundle_id}.{setting_id}")

    return bundle_id, revision, min_key


def updates_for_client(
    client_version: str,
    installed: Any,
    *,
    latest_version: str | None = None,
    bundles: list[dict[str, Any]] | None = None,
    retired_ids: list[str] | None = None,
) -> dict[str, Any]:
    """Return only changed compatible schemas for the client's cache inventory."""
    client_key = _version_key(client_version)
    min_client_key = _version_key(MIN_CLIENT_VERSION)
    if client_key is None or min_client_key is None:
        raise ValueError("invalid client version")
    if not isinstance(installed, list) or len(installed) > 100:
        raise ValueError("installed must contain at most 100 bundle revisions")

    installed_revisions: dict[str, int] = {}
    for entry in installed:
        if not isinstance(entry, dict):
            raise ValueError("invalid installed bundle entry")
        bundle_id, revision = entry.get("id"), entry.get("revision")
        if (
            not isinstance(bundle_id, str)
            or not _ID_RE.fullmatch(bundle_id)
            or not isinstance(revision, int)
            or isinstance(revision, bool)
            or revision < 1
            or bundle_id in installed_revisions
        ):
            raise ValueError("invalid installed bundle entry")
        installed_revisions[bundle_id] = revision

    latest_key = _version_key(latest_version) if latest_version is not None else None
    eligible = client_key >= min_client_key and (
        latest_version is None or client_key == latest_key
    )
    if not eligible:
        return {"protocol": 1, "eligible": False, "bundles": [], "retired": []}

    active_bundles = APP_CONFIG_BUNDLES if bundles is None else bundles
    retired = RETIRED_BUNDLE_IDS if retired_ids is None else retired_ids
    if len(active_bundles) > 50:
        raise ValueError("too many server OTA bundles")

    result: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for bundle in active_bundles:
        bundle_id, revision, min_version = _validate_bundle(bundle)
        if bundle_id in seen_ids:
            raise ValueError(f"duplicate OTA bundle id: {bundle_id}")
        seen_ids.add(bundle_id)
        if client_key >= min_version and installed_revisions.get(bundle_id) != revision:
            result.append(copy.deepcopy(bundle))

    retired_for_client = [
        bundle_id
        for bundle_id in retired
        if isinstance(bundle_id, str)
        and _ID_RE.fullmatch(bundle_id)
        and bundle_id in installed_revisions
    ]
    response = {
        "protocol": 1,
        "eligible": True,
        "bundles": result,
        "retired": retired_for_client,
    }
    if len(json.dumps(response, ensure_ascii=False).encode("utf-8")) > 128 * 1024:
        raise ValueError("OTA settings response exceeds 128 KiB")
    return response
