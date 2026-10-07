import asyncio
from types import SimpleNamespace
import bot as b

TASK_ID = "abcdef0123456789abcdef0123456789"
task = {
    "id": TASK_ID,
    "user_id": 42,
    "telegram_chat_id": 1234,
    "config_message_id": 400,
    "status": "pending",
    "title": "Тест",
    "instruction": "Напомни про тест",
    "run_at": 1893456000,
    "recurrence": "once",
    "weekdays": "",
    "execution_mode": "ai",
    "confirm_button": "✅ Подтвердить",
    "cancel_button": "❌ Отменить",
}

class FakeMessage:
    def __init__(self):
        self.chat = SimpleNamespace(id=1234)
        self.message_id = 500
        self.edits = []
    async def edit_text(self, text, **kwargs):
        self.edits.append((text, kwargs))

class FakeQuery:
    def __init__(self):
        self.data = f"task:legacy:{TASK_ID}"
        self.from_user = SimpleNamespace(id=42)
        self.message = FakeMessage()
        self.answers = []
    async def answer(self, text=None, **kwargs):
        self.answers.append((text, kwargs))

class FakeBot:
    def __init__(self):
        self.sent = []
        self.deleted = []
    async def send_message(self, chat_id, text, **kwargs):
        self.sent.append((chat_id, text, kwargs))
        return SimpleNamespace(message_id=901)
    async def delete_message(self, chat_id, message_id):
        self.deleted.append((chat_id, message_id))

async def main():
    original_bot = b.bot
    original_get = b.reminders.get_owned
    original_set = b.reminders.set_config_message
    fake = FakeBot()
    set_calls = []

    async def get_owned(task_id, user_id):
        assert task_id == TASK_ID and user_id == 42
        return dict(task)

    async def set_config_message(task_id, user_id, message_id):
        set_calls.append((task_id, user_id, message_id))
        return True

    b.bot = fake
    b.reminders.get_owned = get_owned
    b.reminders.set_config_message = set_config_message
    try:
        await b._send_reminder_legacy_notice(1234, TASK_ID)
        notice = fake.sent[-1]
        markup = notice[2]["reply_markup"]
        assert markup.inline_keyboard[0][0].callback_data == f"task:legacy:{TASK_ID}"
        assert "обычную версию" in notice[1].lower()

        fake.sent.clear()
        query = FakeQuery()
        await b.handle_reminder_callback(query)

        assert len(fake.sent) == 1
        regular = fake.sent[0]
        assert regular[2]["parse_mode"] == "HTML"
        assert regular[2]["reply_markup"].inline_keyboard
        assert set_calls == [(TASK_ID, 42, 901)]
        assert fake.deleted == [(1234, 400)]
        assert query.answers[-1][0] == "Обычная версия включена"
        assert "обычная версия" in query.message.edits[-1][0].lower()
        print("PASS: rich reminder compatibility fallback switches to classic card")
    finally:
        b.bot = original_bot
        b.reminders.get_owned = original_get
        b.reminders.set_config_message = original_set

asyncio.run(main())
