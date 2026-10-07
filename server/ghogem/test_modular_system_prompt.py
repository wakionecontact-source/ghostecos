"""Regression tests for the modular provider-facing system prompt."""
import ai


def build(prompt: str, **kwargs) -> str:
    return ai.build_modular_system_prompt(
        prompt=prompt,
        model_key="groq:gpt-oss-20b",
        timezone_name="Europe/Moscow",
        is_premium=True,
        **kwargs,
    )


plain=build("объясни кратко что такое TCP")
music=build("найди музыку в GhoSou")
reminder=build("выруби напоминание про сервер", reminder_mode=True)
files=build("прочитай файл и поправь код")
web=build("найди свежие новости сегодня", force_web_search=True)
choice=build("сделай вопрос с вариантами и кнопками")

assert len(plain)+len(ai.tool_registry.PROTOCOL_PROMPT) < 4000
assert len(music)+len(ai.tool_registry.PROTOCOL_PROMPT) < 4500
assert "GHOSOU / МУЗЫКА" in music
assert "GHOSOU / МУЗЫКА" not in plain
assert "НАПОМИНАНИЯ:" in reminder
assert "ФАЙЛЫ И МЕДИА:" in files
assert "ПРИНУДИТЕЛЬНЫЙ WEB:" in web
assert "ask_user_choice" in choice
assert "switch_model" in plain
assert "subscription_access_prompt" not in plain
assert len(ai.tool_registry.PROTOCOL_PROMPT) < 500
print("ALL MODULAR SYSTEM PROMPT TESTS PASS")
