@echo off
chcp 65001 >nul
title GhostRoulette Bot
cd /d "%~dp0"

echo ====================================
echo   GhostRoulette - запуск
echo ====================================
echo.

REM ── Проверка Python ─────────────────────────────────
where python >nul 2>nul
if errorlevel 1 (
    echo [ОШИБКА] Python не найден в PATH.
    echo.
    echo Скачай Python 3.11+ с https://python.org/downloads/
    echo При установке поставь галку "Add Python to PATH".
    echo.
    pause
    exit /b 1
)

REM ── venv ────────────────────────────────────────────
if not exist venv (
    echo Создаю venv...
    python -m venv venv
    if errorlevel 1 (
        echo [ОШИБКА] Не удалось создать venv.
        pause
        exit /b 1
    )
)

REM ── Активация и зависимости ─────────────────────────
call venv\Scripts\activate.bat

echo Проверяю зависимости...
pip install -q -r requirements.txt
if errorlevel 1 (
    echo [ОШИБКА] Не удалось установить зависимости.
    pause
    exit /b 1
)

REM ── .env ────────────────────────────────────────────
if not exist .env (
    echo.
    echo [ВНИМАНИЕ] Файл .env не найден.
    echo Создаю из .env.example - заполни BOT_TOKEN.
    copy .env.example .env >nul
    notepad .env
    echo.
    echo После заполнения .env запусти start.bat снова.
    pause
    exit /b 0
)

REM ── Запуск ──────────────────────────────────────────
echo.
echo Стартую бот + admin-приложение...
echo Закрой это окно или нажми Ctrl+C чтобы остановить.
echo.
python bot.py

pause
