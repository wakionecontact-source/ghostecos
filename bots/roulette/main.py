"""
OKey — точка входа.

Запускает bot.py отдельным процессом в НОВОМ окне консоли (чтобы логи
бота не мешались с интерактивным меню), а в этом, текущем окне
открывает console.py — статистика и команды.

Раньше start.bat запускал bot.py напрямую. Теперь он должен запускать
main.py — см. обновлённый start.bat.
"""
import platform
import subprocess
import sys
from pathlib import Path

BASE_DIR = Path(__file__).parent


def launch_bot() -> subprocess.Popen:
    """Запускает bot.py как отдельный процесс. На Windows — в новом окне,
    чтобы его логи не путались с консольным меню."""
    python_exe = sys.executable
    kwargs = {}
    if platform.system() == "Windows":
        # Отдельное окно консоли только на Windows — на Linux/Mac у Popen
        # такого понятия нет, просто запускаем в фоне.
        kwargs["creationflags"] = subprocess.CREATE_NEW_CONSOLE
    return subprocess.Popen(
        [python_exe, str(BASE_DIR / "bot.py")],
        cwd=str(BASE_DIR),
        **kwargs,
    )


def main() -> None:
    print("=" * 44)
    print("   OKey — запуск")
    print("=" * 44)
    print()

    if not (BASE_DIR / ".env").exists():
        print("[ERROR] .env не найден рядом с main.py.")
        print("Запусти start.bat — он создаст .env из шаблона.")
        input("\nEnter для выхода...")
        return

    print("🚀 Запускаю бота в отдельном окне...")
    bot_proc = launch_bot()
    print(f"✅ Бот запущен (PID={bot_proc.pid}). Его логи — в новом окне.")
    print("   Если новое окно сразу закрылось — там ошибка, глянь в него.")
    print()
    input("Enter, чтобы открыть консоль статистики...")

    import console  # локальный модуль console.py
    console.run(bot_proc)


if __name__ == "__main__":
    main()
