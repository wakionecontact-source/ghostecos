"""Keep the global request budget independent of unauthenticated headers."""


def test_fake_bearer_tokens_cannot_reset_ip_budget(client, monkeypatch):
    import social_app

    monkeypatch.setattr(social_app, "_RL_MAX", 3)
    social_app._RL_BUCKETS.clear()
    for i in range(3):
        response = client.get(
            "/api/soc/health",
            headers={"Authorization": f"Bearer forged-token-{i:04d}-00000000"},
        )
        assert response.status_code == 200
    blocked = client.get(
        "/api/soc/health",
        headers={"Authorization": "Bearer forged-token-9999-00000000"},
    )
    assert blocked.status_code == 429
    assert int(blocked.headers["Retry-After"]) > 0


def test_only_loopback_proxy_can_supply_forwarded_ip():
    from starlette.requests import Request
    from social_app import _rl_key

    def request(peer, xff):
        return Request({
            "type": "http", "method": "GET", "path": "/",
            "headers": [(b"x-forwarded-for", xff.encode())],
            "client": (peer, 12345), "server": ("127.0.0.1", 18005),
        })

    spoofed = "198.51.100.19, 203.0.113.8"
    assert _rl_key(request("127.0.0.1", spoofed)) == "ip:203.0.113.8"
    assert _rl_key(request("192.0.2.1", spoofed)) == "ip:192.0.2.1"
