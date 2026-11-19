"""Partner transport security tests; fixtures use temporary databases."""
import secrets
import base64
import hashlib
from urllib.parse import urlencode, parse_qs, urlsplit
from test_service_sso import client, register, entrance, authorize, token_payload, MEMBER, ADMIN, CALLBACK, ISSUER, definition
from ecos_core import partner_oauth as oauth, service_sso as sso
import pytest

@pytest.fixture
def http(client):
    client.app.include_router(oauth.router)
    return client

def test_standard_transport_and_revoke(http):
    register(http)
    verifier = secrets.token_urlsafe(48)
    params = {"response_type":"code", "client_id":"my_service", "redirect_uri":CALLBACK,
              "scope":"identity profile", "state":secrets.token_urlsafe(32),
              "code_challenge":sso._pkce(verifier), "code_challenge_method":"S256"}
    response=http.get("/api/sso/oauth/authorize",params=params,follow_redirects=False)
    assert response.status_code==302
    assert response.headers["cache-control"]=="no-store"
    rid=parse_qs(urlsplit(response.headers["location"]).query)["sso_request"][0]
    grant=authorize(http,{"request_id":rid})
    payload={"grant_type":"authorization_code","client_id":"my_service","redirect_uri":CALLBACK,"code":grant["code"][0],"code_verifier":verifier}
    result=http.post("/api/sso/oauth/token",data=payload)
    assert result.status_code==200
    token=result.json()["access_token"]
    assert http.post("/api/sso/oauth/token",data=payload).json()["error"]=="invalid_grant"
    assert http.get("/api/sso/userinfo",headers={"Authorization":"Bearer "+token}).status_code==200
    assert http.post("/api/sso/oauth/revoke",data={"client_id":"my_service","token":token}).status_code==200
    assert http.get("/api/sso/userinfo",headers={"Authorization":"Bearer "+token}).status_code==401
    assert http.post("/api/sso/oauth/revoke",data={"client_id":"my_service","token":token}).status_code==200

def test_duplicate_and_unsafe_authorize_never_redirect(http):
    register(http)
    response=http.get("/api/sso/oauth/authorize?response_type=code&client_id=my_service&client_id=evil",follow_redirects=False)
    assert response.status_code==400 and "location" not in response.headers
    response=http.post("/api/sso/oauth/token",content="grant_type=authorization_code&code=a&code=b",headers={"Content-Type":"application/x-www-form-urlencoded"})
    assert response.status_code==400
    assert http.post("/api/sso/oauth/token",json={"code":"secret"}).status_code==400

def test_revoke_grant_invalidates_codes_and_tokens(http):
    register(http)
    first=entrance(http);query=authorize(http,first)
    token=http.post("/api/sso/token",json=token_payload(first,query)).json()["access_token"]
    pending=entrance(http);pending_query=authorize(http,pending)
    assert http.delete("/api/sso/grants/my_service").status_code==401
    assert http.delete("/api/sso/grants/my_service",headers={**MEMBER,"Origin":"https://external.example"}).status_code==403
    assert http.delete("/api/sso/grants/my_service",headers=MEMBER).status_code==204
    assert http.get("/api/sso/userinfo",headers={"Authorization":"Bearer "+token}).status_code==401
    assert http.post("/api/sso/token",json=token_payload(pending,pending_query)).status_code==400

def test_widget_has_registered_target_and_no_script(http):
    register(http,login_start_uri="https://external.example/auth/ghostid/start",name='Service <script>alert(1)</script>')
    response=http.get("/api/sso/widget/my_service")
    assert response.status_code==200
    assert '<script>' not in response.text
    assert 'target="_top"' in response.text
    assert 'href="https://external.example/auth/ghostid/start"' in response.text
    csp=response.headers["content-security-policy"]
    assert "frame-ancestors https://external.example" in csp
    assert "default-src 'none'" in csp
    assert "sha256-" in csp
    assert http.get("/api/sso/widget/my_service?redirect=https://evil.example").status_code==400

def test_widget_rejects_unconfigured_disabled_and_other_origin(http):
    register(http)
    assert http.get("/api/sso/widget/my_service").status_code==409
    assert http.get("/api/sso/widget/unknown").status_code==404
    response=http.post("/api/sso/clients",json=definition("bad_start",login_start_uri="https://evil.example/start"),headers=ADMIN)
    assert response.status_code==422
    assert http.post("/api/sso/clients",json=definition("bad_http",login_start_uri="http://external.example/start"),headers=ADMIN).status_code==422
    register(http,"disabled",enabled=False,login_start_uri="https://external.example/start")
    assert http.get("/api/sso/widget/disabled").status_code==403

@pytest.mark.parametrize("url", ['https://evil";script-src/callback', "https://evil;example/callback", "https://evil%0a.example/callback", "https://-invalid.example/callback"])
def test_malformed_host_cannot_enter_policy(http, url):
    assert http.post("/api/sso/clients", json=definition(redirect_uris=[url]), headers=ADMIN).status_code == 422
