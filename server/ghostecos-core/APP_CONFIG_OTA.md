# GhostChat settings OTA

This channel distributes declarative setting definitions for network and
appearance sections. It does not update Dart code and does not evaluate HTML,
JavaScript, or other server-supplied programs. Code changes still ship in an APK.

## Add or revise a settings bundle

Edit `APP_CONFIG_BUNDLES` in `app_config_ota.py`, then deploy the server. The
first bundle is `appearance.chat_list`: its compact-list toggle changes the
height of personal chat rows in GhostChat. The installed app already consumes
that setting ID, so changing it takes effect immediately without an APK update.
For another bundle, use this shape:

```python
{
    "id": "network.transport",
    "revision": 1,
    "title": "Сетевые настройки",
    "category": "network",  # network or appearance
    "min_app_version": "1.2.2",
    "settings": [
        {
            "id": "prefer_relay",
            "type": "toggle",
            "title": "Предпочитать relay",
            "description": "Подсказка под названием настройки.",
            "default": False,
        },
        {
            "id": "route",
            "type": "select",
            "title": "Маршрут",
            "options": [
                {"value": "auto", "label": "Автоматически"},
                {"value": "direct", "label": "Напрямую"},
            ],
            "default": "auto",
        },
    ],
}
```

Supported control types are `toggle`, `select`, `slider`, and `text`. A setting
value is stored only on the device, separately from the downloaded schema.
Changing a label, description, default, or control definition requires
incrementing the bundle `revision`; the client then downloads that revision
while retaining compatible user values. To retire a bundle, add its ID to
`RETIRED_BUNDLE_IDS`.

On each app start, the client sends only its installed bundle IDs and revisions
to `/api/app-config/check`. The server returns only missing or changed bundles
and retirement IDs; unchanged bundle bodies are not downloaded again. The
endpoint serves settings only to the current app version at or above
`MIN_CLIENT_VERSION`.

The client can render and persist a new setting without an APK. For a setting to
change network behavior or a visual property, the installed app must already
have code that reads that setting ID. Adding new behavior still requires an APK.
