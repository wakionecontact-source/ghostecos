import ecos_core_app as a
from fastapi.testclient import TestClient

http = TestClient(a.app)
probe = http.post("/api/v2/auth/authorize", json={})
print("authorize:", probe.status_code, probe.text[:80])
print("me:", http.get("/api/v2/auth/me").status_code)
print("sso userinfo:", http.get("/api/sso/userinfo").status_code)
