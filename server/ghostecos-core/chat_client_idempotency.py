"""Transaction-local message deduplication; never cache across a commit gap."""
import hashlib
import json
import time
from fastapi import HTTPException


def begin(c, sender_id, scope, body):
    message_id = getattr(body, "client_message_id", None)
    if not message_id:
        return None
    c.execute("CREATE TABLE IF NOT EXISTS gc_client_idempotency (sender_id INTEGER, scope TEXT, "
              "client_message_id TEXT, request_hash TEXT NOT NULL, response_json TEXT NOT NULL, created_at INTEGER, "
              "PRIMARY KEY(sender_id, scope, client_message_id))")
    c.commit()
    c.execute("BEGIN IMMEDIATE")
    c.execute("DELETE FROM gc_client_idempotency WHERE created_at<?", (int(time.time()) - 365 * 86400,))
    r = c.execute("SELECT * FROM gc_client_idempotency WHERE sender_id=? AND scope=? AND client_message_id=?",
                  (sender_id, scope, message_id)).fetchone()
    digest = hashlib.sha256(json.dumps(body.model_dump(), sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if r:
        if r["request_hash"] != digest:
            raise HTTPException(409, "client_message_id уже использован для другого сообщения")
        return json.loads(r["response_json"])
    return None


def save(c, sender_id, scope, body, response):
    if not getattr(body, "client_message_id", None):
        return
    digest = hashlib.sha256(json.dumps(body.model_dump(), sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    c.execute("INSERT INTO gc_client_idempotency VALUES (?,?,?,?,?,?)",
              (sender_id, scope, body.client_message_id, digest, json.dumps(response), int(time.time())))
