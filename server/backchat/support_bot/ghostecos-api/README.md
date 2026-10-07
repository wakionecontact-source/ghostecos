# ghostecos-api

Python SDK for GhostEcos services. The distribution name is `ghostecos-api`;
the Python import name is `ghostapi`.

```bash
python -m pip install ghostecos-api
```

The first service module is `ghostapi.ghostbot`. It uses a WebSocket connection
and a small event/action API—not Telegram-style polling or commands:

```python
from ghostapi import ghostbot

bot = ghostbot.Bot(token="YOUR_BOT_TOKEN")


@bot.on("message.received")
def on_message(event):
    if "from_user_id" in event.data:  # обычный чат; ID не меняется вместе с username
        bot.send_message(user_id=event.data["from_user_id"], text="Привет!")
    else:  # зашифрованный чат владельца для тестирования
        bot.send_message(event.data["from_username"], "Привет!")


@bot.on_status
def on_status(event):
    print("Статус:", event.data)


bot.run()
```

Register any server event with `@bot.on("event.name")` and send any named
action with `bot.send_action("action.name", field=value)`. The convenience
method `send_message()` maps to `message.send`. Online status is controlled by
the server from the live connection and heartbeat; the client doesn't set
it manually. Use `bot.go_offline()` to request a manual offline state and stop
the current connection. The token is sent directly in the WebSocket
`Authorization: Bot …` header; the SDK doesn't create a JWT.

The event/action envelope and default WebSocket route are documented in
[PROTOCOL.md](PROTOCOL.md). The current GhostChat backend implements the bot
WebSocket and encrypted owner test-chat flows; a different server URL must
have a matching bot API deployment.

## Persistent bot data

Each bot has a separate server-side JSON key/value store. It can be used from
any device running that bot. In regular user chats, `from_user_id` is available
for stable per-user keys; the encrypted owner test chat intentionally omits it:

```python
user_id = event.data["from_user_id"]
key = f"player:{user_id}"
player = bot.storage.get(key, {"coins": 0})
player["coins"] += 1
bot.storage.set(key, player)
```

Use `bot.storage.get(key, default=None)`, `set(key, value)`, and
`delete(key)`. Values must be JSON-compatible; keys are limited to 128 simple
ASCII characters, each value to 64 KiB, and each bot to 1,000 keys / 1 MiB.
This is a small key/value store, not direct SQL access to GhostChat's shared
database. Data is readable by the server and is not end-to-end encrypted, so
don't store passwords, API keys, or other secrets there. Storage calls use the
bot's token over HTTPS and are synchronous HTTP requests.

## Runnable game bot

[`examples/clicker_bot.py`](examples/clicker_bot.py) is a working tap-to-earn
example for the encrypted GhostBots test chat. Install the checkout in
editable mode once with `python -m pip install -e .`, then start it with
`python examples/clicker_bot.py`. It asks for the bot token without echoing it
to the terminal. Player balances and upgrades are stored in a local SQLite
file (`ghost_clicker.sqlite3` by default), not on the GhostChat server.

In the test chat, send `/start`, then `тап` or `/tap 10`. Use `/shop` and
`/buy power` or `/buy auto` to purchase upgrades. The SDK transparently decrypts
incoming test-chat messages and encrypts replies. The current chat UI is
text-based, so a tap is sent as a message rather than a custom on-screen game
button.

Set `GHOSTBOT_GAME_DB` to choose another local database path. For a local
development server, `GHOSTBOT_BASE_URL` can override the default GhostEcos URL.

## Message buttons

Messages can carry either an inline keyboard below the message or a reply
keyboard above the composer. Inline buttons deliver `button.callback` events
to the bot (or open an HTTP(S) URL); reply-keyboard taps send their configured
`send_text` as an ordinary chat message.

```python
from ghostapi.ghostbot import (
    InlineKeyboard,
    InlineKeyboardButton,
    KeyboardButton,
    ReplyKeyboard,
)

bot.send_message(
    "player",
    "Choose an upgrade:",
    reply_markup=InlineKeyboard(
        [[InlineKeyboardButton("Power", callback_data="buy:power")]]
    ),
)

bot.send_message(
    "player",
    "Quick actions:",
    reply_markup=ReplyKeyboard(
        [[KeyboardButton("Tap", send_text="/tap"), KeyboardButton("Shop", "/shop")]]
    ),
)

@bot.on("button.callback")
def on_button(event):
    if event.data["callback_data"] == "buy:power":
        bot.send_message(event.data["from_username"], "Power selected!")
```

The server validates and retains button markup with the bot message so it can
verify callback taps. The encrypted owner test chat remains text-only until its
encrypted payload/UI also supports markup.

## Local development

From this directory:

```bash
python -m pip install -e .
python -m pytest
```

## Name mapping

| Layer | Name |
| --- | --- |
| Product / brand | GhostAPI |
| Python distribution | `ghostecos-api` |
| Python import | `ghostapi` |
