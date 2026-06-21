@echo off
chcp 65001 > nul
title GhostRoulette Bot
cd /d "%~dp0"

echo.
echo  GhostRoulette - startup
echo.

REM Check Python
where python > nul 2>nul
if errorlevel 1 (
    echo [ERROR] Python not found in PATH.
    echo.
    echo Install Python 3.11+ from https://python.org/downloads/
    echo Check "Add Python to PATH" during install.
    echo.
    pause
    exit /b 1
)

REM Create venv
if not exist venv (
    echo Creating venv...
    python -m venv venv
    if errorlevel 1 (
        echo [ERROR] Could not create venv.
        pause
        exit /b 1
    )
)

REM Activate + install deps
call venv\Scripts\activate.bat

echo Installing dependencies...
pip install -q -r requirements.txt
if errorlevel 1 (
    echo [ERROR] Could not install dependencies.
    pause
    exit /b 1
)

REM Check .env
if not exist .env (
    echo.
    echo [WARN] .env not found. Creating from .env.example.
    echo Edit it - put real BOT_TOKEN there.
    copy .env.example .env > nul
    start notepad .env
    echo.
    echo After saving .env - run start.bat again.
    pause
    exit /b 0
)

REM Run
echo.
echo Starting bot + admin app...
echo Close this window or press Ctrl+C to stop.
echo.
python bot.py

pause
