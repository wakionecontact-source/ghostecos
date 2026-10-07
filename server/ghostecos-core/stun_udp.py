"""
GhostChat — минимальный STUN-подобный UDP-сервис для режима «Треугольник».

Отвечает на ЛЮБОЙ входящий датаграм тем же адресом:портом, что видел сам —
клиент так узнаёт свой публичный IP:порт для NAT-punching. Не проксируется
через nginx (UDP), слушает напрямую на отдельном порту.
"""
from __future__ import annotations

import asyncio
import json
import logging

log = logging.getLogger("gc.stun")


class _StunProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data: bytes, addr):
        ip, port = addr[0], addr[1]
        try:
            reply = json.dumps({"ip": ip, "port": port}).encode("utf-8")
            self.transport.sendto(reply, addr)
        except Exception as e:
            log.debug(f"stun reply error: {e}")

    def error_received(self, exc):
        log.debug(f"stun udp error: {exc}")


async def start_stun_server(host: str = "0.0.0.0", port: int = 47779):
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: _StunProtocol(), local_addr=(host, port),
    )
    log.info(f"STUN-lite UDP слушает на {host}:{port}")
    return transport
