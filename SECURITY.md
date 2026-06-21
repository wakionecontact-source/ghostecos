# Security Policy

## Reporting a vulnerability

If you found a security issue — **please do NOT open a public GitHub issue**.

Instead, contact directly:
- **Telegram:** [@waki_one](https://t.me/waki_one)

Include:
- Description of the issue
- Steps to reproduce / PoC if possible
- Affected component (chat/social/bank/lending)
- Your suggested fix (optional)

I'll respond within 48 hours. If the issue is critical (RCE, auth bypass, money theft via economy, mass PII leak) — fix will be deployed within 24h.

## Out of scope

- Self-XSS (browser console)
- DoS via reasonable rate-limits
- Issues in third-party dependencies that don't affect the service
- Social engineering of users or staff

## Hall of fame

(empty — be the first!)

---

## Security architecture notes

For researchers — what you should know about the threat model:

### E2E messaging (GhostChat)

- ECDH P-256 keys generated in-browser, private key never leaves client in plaintext
- IndexedDB stores private key as `CryptoKey` with `extractable=false` (XSS cannot call `exportKey`)
- Public keys: TOFU pinning per-peer, prompt on key change
- Master-key derivation: PBKDF2-SHA256 with 260k iterations + random salt
- Server stores only `(x25519_pub, encrypted_private_key, key_salt)` — sees no plaintext message content
- **Out of scope:** server CAN substitute peer's public key (we use TOFU but not OOB verification yet). Compromised server can MITM new conversations. Detected on key-change prompt.

### Economy (GhostBank)

- All money transactions use `BEGIN IMMEDIATE` for atomicity (no double-spend)
- WAL mode for SQLite, busy_timeout 5s
- 10% commissions on NFT market, 5% on invoices, 3% on transfers → all to `system_balance`
- System-buy of NFT burns 10% (deflationary)
- Admin endpoints require `GE_ADMIN_TOKEN` env var, compared via `hmac.compare_digest` (timing-safe)
- All write endpoints rate-limited

### Authentication

- Argon2id password hashing (PBKDF2 legacy auto-upgrade)
- Session tokens: 64 hex chars in `soc_tokens` (no expiry — log-out destroys)
- Seed phrases: 16-char alphabet without ambiguous chars (0/O/1/I), Argon2-hashed
- Constant-time comparison on login (dummy verify for non-existent users) — no user enumeration via timing
- Rate-limit: 15 login attempts per IP per 10 minutes

### What we DON'T protect against (yet)

- Phishing (anyone with your password can log in)
- Compromised endpoint device (XSS in browser → can do anything you can)
- Traffic analysis (metadata when messages sent to whom)
- Server-side adversary with full DB access (can read all messages-in-transit, public keys, balances)
