import asyncio
import os
import tempfile
from cryptography.fernet import Fernet

os.environ["DB_ENCRYPTION_KEY"] = Fernet.generate_key().decode()

import db
import ai


async def main():
    original_db_path = db.DB_PATH
    original_fernet = db._fernet
    with tempfile.TemporaryDirectory() as root:
        db.DB_PATH = os.path.join(root, "test.db")
        db._fernet = None
        db._init_db()
        db._init_api_keys_table()

        uid = 991001
        await db.set_fallback_on_rate_limit(uid, False)
        assert await db.get_fallback_on_rate_limit(uid) is False
        await db.set_fallback_on_rate_limit(uid, True)
        assert await db.get_fallback_on_rate_limit(uid) is True
        print("PASS fallback setting persistence")

        await db.add_user_key(uid, "groq", "gsk_test_private_abcdefghijk")
        await db.add_user_key(uid + 1, "groq", "gsk_test_pool_abcdefghijklm")
        await db.set_use_own_only(uid, "groq", True)

        pool = await db.get_active_keys("groq")
        owners = {int(item["user_id"]) for item in pool}
        assert uid not in owners, owners
        assert uid + 1 in owners, owners

        own = await db.get_user_key_any(uid, "groq")
        assert own and own["is_active"] and own["use_own_only"]

        await db.mark_key_failed(uid, "groq", deactivate_after=1)
        own = await db.get_user_key_any(uid, "groq")
        assert own and not own["is_active"]
        await db.reactivate_user_key(uid, "groq")
        own = await db.get_user_key_any(uid, "groq")
        assert own and own["is_active"] and own["fail_count"] == 0
        print("PASS private/pool key routing + reactivate")

    db.DB_PATH = original_db_path
    db._fernet = original_fernet

    raw = '{"chatid":"1791125967449","usedbytes":0,"limit_bytes":31457280,"files":[]}'
    safe = ai._fallback_from_tools([("list_files", raw)])
    assert raw not in safe
    assert "[list_files]" not in safe
    assert "files" not in safe.lower() or "служеб" in safe.lower()
    print("PASS internal tool results never leak raw JSON")

    model = ai.DEFAULT_MODEL_KEY
    provider = ai.AVAILABLE_MODELS[model]["provider"]
    old_premium = ai.user_has_premium
    old_tutorial = ai.db.get_tutorial_state
    try:
        async def fake_premium(_uid):
            return False
        async def fake_tutorial(_uid):
            return {"is_new_user": False, "age_seconds": 0, "topics": {}}
        ai.user_has_premium = fake_premium
        ai.db.get_tutorial_state = fake_tutorial
        ai._mark_runtime_rate_limit(provider, model)
        holder = [model]
        reply = await ai.ask_ai(
            991002,
            "тест",
            model,
            "",
            2,
            model_holder=holder,
            allow_rate_limit_fallback=False,
        )
        assert "Автосмена модели отключена" in reply, reply
        assert holder == [model], holder
        print("PASS pre-existing 429 cooldown does not switch model")
    finally:
        ai.user_has_premium = old_premium
        ai.db.get_tutorial_state = old_tutorial
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.pop(model, None)
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.pop(provider, None)


asyncio.run(main())
