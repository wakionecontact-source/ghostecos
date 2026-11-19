"""Отдельный процесс-супервайзер конструктора ботов GhostChat."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import signal
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen

from bot_program_runtime import attach_bot_program
from bot_runner_crypto import decrypt_runner_token, runner_control_token
from ghostapi import ghostbot

LOG = logging.getLogger("gc.bot_runner")
CONTROL_URL = os.environ.get(
    "GHOSTBOT_CONTROL_URL",
    "http://127.0.0.1:8005/api/bots/internal/managed",
)
HEARTBEAT_PATH = Path(
    os.environ.get(
        "GHOSTBOT_RUNNER_HEARTBEAT_FILE",
        "/run/ghostchat-bot-runner/heartbeat",
    )
)
POLL_SECONDS = 3.0
MAX_BOTS = 64


@dataclass
class _Worker:
    fingerprint: str
    client: ghostbot.Bot
    stop_event: threading.Event
    thread: threading.Thread


def _read_desired() -> dict[int, tuple[str, str]]:
    """Забираем только включённые определения из локального API."""
    request = Request(
        CONTROL_URL,
        headers={"X-Ghost-Bot-Runner": runner_control_token()},
        method="GET",
    )
    with urlopen(request, timeout=5) as response:
        payload = json.loads(response.read(4_000_000))
    if not isinstance(payload, dict) or not isinstance(payload.get("bots"), list):
        raise ValueError("invalid runner control response")
    desired: dict[int, tuple[str, str]] = {}
    for row in payload["bots"][:MAX_BOTS]:
        if not isinstance(row, dict):
            raise ValueError("invalid runner bot entry")
        bot_id = row.get("id")
        token_enc = row.get("token_enc")
        program_json = row.get("program_json")
        if type(bot_id) is not int or bot_id <= 0:
            raise ValueError("invalid managed bot ID")
        if not isinstance(token_enc, str) or not isinstance(program_json, str):
            raise ValueError("invalid managed bot configuration")
        desired[bot_id] = (token_enc, program_json)
    return desired


def _fingerprint(token_enc: str, program_json: str) -> str:
    return hashlib.sha256(
        (token_enc + "\0" + program_json).encode("utf-8")
    ).hexdigest()


def _write_heartbeat() -> None:
    HEARTBEAT_PATH.parent.mkdir(parents=True, exist_ok=True)
    HEARTBEAT_PATH.touch()


def _start_worker(bot_id: int, token_enc: str, program_json: str) -> _Worker:
    token = decrypt_runner_token(token_enc, bot_id)
    program_data: Any = json.loads(program_json)
    base_url = os.environ.get("GHOSTBOT_BASE_URL", "").strip()
    client = ghostbot.Bot(token, **({"base_url": base_url} if base_url else {}))
    attach_bot_program(client, program_data)
    stop_event = threading.Event()

    def run() -> None:
        try:
            client.run(stop_event=stop_event)
        except Exception as exc:
            # SECURITY: текст ошибки может раскрыть адрес и тело запроса
            LOG.warning(
                "Managed bot worker exited (bot_id=%s, error=%s)",
                bot_id,
                type(exc).__name__,
            )

    thread = threading.Thread(
        target=run,
        name=f"ghostchat-bot-{bot_id}",
        daemon=True,
    )
    worker = _Worker(
        fingerprint=_fingerprint(token_enc, program_json),
        client=client,
        stop_event=stop_event,
        thread=thread,
    )
    thread.start()
    return worker


def _stop_worker(bot_id: int, worker: _Worker) -> None:
    worker.stop_event.set()
    worker.client.stop()
    worker.thread.join(timeout=5)
    if worker.thread.is_alive():
        LOG.warning("Managed bot worker is still stopping (bot_id=%s)", bot_id)


def serve(stop_event: threading.Event | None = None) -> None:
    stop = stop_event or threading.Event()
    workers: dict[int, _Worker] = {}
    retry_after: dict[int, float] = {}
    failures: dict[int, int] = {}

    while not stop.is_set():
        try:
            desired = _read_desired()
        except Exception as exc:
            LOG.error("Could not read managed bot configuration (%s)", type(exc).__name__)
            stop.wait(POLL_SECONDS)
            continue

        _write_heartbeat()
        now = time.monotonic()

        for bot_id, worker in list(workers.items()):
            wanted = desired.get(bot_id)
            changed = wanted is not None and _fingerprint(*wanted) != worker.fingerprint
            if wanted is None or changed or not worker.thread.is_alive():
                _stop_worker(bot_id, worker)
                workers.pop(bot_id, None)
                if wanted is not None and not changed:
                    count = failures.get(bot_id, 0) + 1
                    failures[bot_id] = count
                    retry_after[bot_id] = now + min(60.0, 2.0 ** min(count, 6))
                elif changed:
                    failures[bot_id] = 0
                    retry_after.pop(bot_id, None)

        for bot_id, (token_enc, program_json) in desired.items():
            if bot_id in workers or now < retry_after.get(bot_id, 0):
                continue
            try:
                workers[bot_id] = _start_worker(bot_id, token_enc, program_json)
                failures[bot_id] = 0
                retry_after.pop(bot_id, None)
                LOG.info("Started managed bot worker (bot_id=%s)", bot_id)
            except Exception as exc:
                count = failures.get(bot_id, 0) + 1
                failures[bot_id] = count
                retry_after[bot_id] = now + min(60.0, 2.0 ** min(count, 6))
                LOG.error(
                    "Could not start managed bot worker (bot_id=%s, error=%s)",
                    bot_id,
                    type(exc).__name__,
                )

        stop.wait(POLL_SECONDS)

    for bot_id, worker in list(workers.items()):
        _stop_worker(bot_id, worker)
    HEARTBEAT_PATH.unlink(missing_ok=True)


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("GHOSTBOT_RUNNER_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda _signum, _frame: stop.set())
    serve(stop)


if __name__ == "__main__":
    main()
