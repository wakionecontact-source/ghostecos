import os
import time
from pathlib import Path

import model_ratings as mr

tmp = "/tmp/ghogem_model_ratings_test.db"
try:
    os.remove(tmp)
except FileNotFoundError:
    pass
mr.DB_PATH = tmp
mr._init()

uid = 987654321
token = mr.create_response(uid, 123, "chat-x", "ans-1", "test:model-a", True)
row = mr.get(token, uid)
assert row and row["required"] == 1 and row["score"] is None
assert mr.pending_required(uid)["token"] == token

mr.attach_message(token, uid, 777)
assert mr.get(token, uid)["telegram_message_id"] == 777

assert mr.submit(token, uid, 4)
row = mr.get(token, uid)
assert row["score"] == 4 and row["rated_at"]
assert mr.pending_required(uid) is None

state = mr.user_rating_state(uid)
assert state["last_score"] == 4
assert state["total_ratings"] == 1

assert mr.submit(token, uid, 5)
state = mr.user_rating_state(uid)
assert state["last_score"] == 5
conn = mr._connect()
try:
    votes = conn.execute(
        "SELECT score FROM model_rating_votes WHERE response_token=? ORDER BY id",
        (token,),
    ).fetchall()
finally:
    conn.close()
assert [x[0] for x in votes] == [4, 5]

token2 = mr.create_response(uid, 123, "chat-x", "ans-2", "test:model-a", True)
assert mr.skip(token2, uid)
assert mr.pending_required(uid) is None

import bot
ctx = bot.rating_model_context(state, is_premium=False)
assert "Последний раз пользователь голосовал" in ctx
assert "GHOGEM_RATING" not in ctx
assert "request" not in ctx.lower()
assert "Тариф: Free" in ctx

urgent_state = {
    "last_rated_at": 0,
    "responses_since_rating": 100,
    "last_required_at": 0,
    "total_ratings": 0,
}
assert not bot.rating_request_allowed("срочно, человеку угрожает опасность", urgent_state)
assert bot.rating_request_allowed("объясни закон Ома", urgent_state)

preview = bot._scrub_agent_block_preview(
    "Ответ готов [[GHOGEM_RATING:request]]"
)
assert "GHOGEM_RATING" not in preview
assert bot._scrub_agent_block_preview("Ответ [[GHOGEM_RAT") == "Ответ "

kb = bot.rating_score_keyboard("abc123", is_premium=False, required=True)
assert len(kb.inline_keyboard) == 1
assert len(kb.inline_keyboard[0]) == 5
kb_p = bot.rating_score_keyboard("abc123", is_premium=True, required=True)
assert len(kb_p.inline_keyboard) == 2
assert kb_p.inline_keyboard[1][0].callback_data == "rating:skip:abc123"

answer_kb = bot.answer_keyboard(None, rating_token="abc123")
assert answer_kb.inline_keyboard[0][0].callback_data == "rating:open:abc123"

print("PASS: model ratings 1-5, history, gating, cooldown helpers and UI")
