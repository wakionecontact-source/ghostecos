"""
Data migration: ghostchat_server.db -> ghostchat.db
Run ONCE after deploying the new server.
"""
import asyncio
import aiosqlite

OLD_DB = "/opt/ghostchat/ghostchat_server.db"
NEW_DB = "/opt/ghostchat/ghostchat.db"

async def migrate():
    async with aiosqlite.connect(OLD_DB) as old, aiosqlite.connect(NEW_DB) as new:
        old.row_factory = aiosqlite.Row
        new.row_factory = aiosqlite.Row

        # users
        cur = await old.execute(
            "SELECT username, display_name, about, argon2_hash, "
            "x25519_pub, ed25519_pub, created_at, screen_block, is_premium, "
            "COALESCE(glow_color,'') as glow_color, "
            "COALESCE(pinned_channel_tag,'') as pinned_channel_tag "
            "FROM users"
        )
        users = await cur.fetchall()
        for u in users:
            await new.execute(
                "INSERT OR IGNORE INTO users "
                "(username, display_name, about, argon2_hash, x25519_pub, ed25519_pub, "
                "created_at, screen_block, is_premium, glow_color, pinned_channel_tag, "
                "avatar_bg_color, ghost_score, token_min_iat) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (u["username"], u["display_name"] or u["username"], u["about"] or "",
                 u["argon2_hash"], u["x25519_pub"] or "", u["ed25519_pub"] or "",
                 u["created_at"], u["screen_block"] or 0, u["is_premium"] or 0,
                 u["glow_color"] or "", u["pinned_channel_tag"] or "",
                 "", 0, 0)
            )
        print(f"users: {len(users)} migrated")

        # contacts
        cur = await old.execute("SELECT user_a, user_b, created_at FROM contacts")
        rows = await cur.fetchall()
        for r in rows:
            await new.execute(
                "INSERT OR IGNORE INTO contacts (user_a, user_b, created_at) VALUES (?,?,?)",
                (r["user_a"], r["user_b"], r["created_at"])
            )
        print(f"contacts: {len(rows)} migrated")

        # device_registry
        cur = await old.execute(
            "SELECT username, device_id, device_name, registered_at, blocked, "
            "trust_type, trust_level, permissions FROM device_registry"
        )
        rows = await cur.fetchall()
        for r in rows:
            await new.execute(
                "INSERT OR IGNORE INTO device_registry "
                "(username, device_id, device_name, registered_at, blocked, "
                "trust_type, trust_level, permissions) VALUES (?,?,?,?,?,?,?,?)",
                (r["username"], r["device_id"], r["device_name"] or "",
                 r["registered_at"], r["blocked"] or 0,
                 r["trust_type"] or "numeric", r["trust_level"] or 0,
                 r["permissions"] or "{}")
            )
        print(f"device_registry: {len(rows)} migrated")

        # messages (undelivered only)
        cur = await old.execute(
            "SELECT from_username, to_username, enc_body, msg_id, sent_at, "
            "COALESCE(forwarded_from,'') as forwarded_from, "
            "COALESCE(reply_to_msg_id,'') as reply_to_msg_id "
            "FROM messages WHERE delivered = 0"
        )
        rows = await cur.fetchall()
        for r in rows:
            await new.execute(
                "INSERT OR IGNORE INTO messages "
                "(from_username, to_username, enc_body, msg_id, sent_at, "
                "delivered, forwarded_from, reply_to_msg_id) VALUES (?,?,?,?,?,?,?,?)",
                (r["from_username"], r["to_username"], r["enc_body"],
                 r["msg_id"], r["sent_at"], 0,
                 r["forwarded_from"], r["reply_to_msg_id"])
            )
        print(f"messages (undelivered): {len(rows)} migrated")

        # channels
        cur = await old.execute(
            "SELECT id, name, tag, description, type, is_private, creator, created_at "
            "FROM channels"
        )
        rows = await cur.fetchall()
        for r in rows:
            await new.execute(
                "INSERT OR IGNORE INTO channels "
                "(id, name, tag, description, type, is_private, creator, created_at) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (r["id"], r["name"], r["tag"], r["description"] or "",
                 r["type"] or "group", r["is_private"] or 0,
                 r["creator"], r["created_at"])
            )
        print(f"channels: {len(rows)} migrated")

        # channel_members
        cur = await old.execute(
            "SELECT channel_id, username, role, joined_at FROM channel_members"
        )
        rows = await cur.fetchall()
        for r in rows:
            await new.execute(
                "INSERT OR IGNORE INTO channel_members "
                "(channel_id, username, role, joined_at) VALUES (?,?,?,?)",
                (r["channel_id"], r["username"], r["role"] or "member", r["joined_at"])
            )
        print(f"channel_members: {len(rows)} migrated")

        # channel_keys
        cur = await old.execute(
            "SELECT channel_id, username, wrapped_key FROM channel_keys"
        )
        rows = await cur.fetchall()
        for r in rows:
            await new.execute(
                "INSERT OR IGNORE INTO channel_keys "
                "(channel_id, username, wrapped_key) VALUES (?,?,?)",
                (r["channel_id"], r["username"], r["wrapped_key"] or "")
            )
        print(f"channel_keys: {len(rows)} migrated")

        # message_receipts
        try:
            cur = await old.execute(
                "SELECT msg_id, from_user, to_user, sent_at, delivered_at, seen_at "
                "FROM message_receipts"
            )
            rows = await cur.fetchall()
            for r in rows:
                await new.execute(
                    "INSERT OR IGNORE INTO message_receipts "
                    "(msg_id, from_user, to_user, sent_at, delivered_at, seen_at) "
                    "VALUES (?,?,?,?,?,?)",
                    (r["msg_id"], r["from_user"], r["to_user"],
                     r["sent_at"], r["delivered_at"] or 0, r["seen_at"] or 0)
                )
            print(f"message_receipts: {len(rows)} migrated")
        except Exception as e:
            print(f"message_receipts: skipped ({e})")

        # offline_events
        try:
            cur = await old.execute(
                "SELECT to_username, type, msg_id, enc_body, created_at "
                "FROM offline_events"
            )
            rows = await cur.fetchall()
            for r in rows:
                await new.execute(
                    "INSERT OR IGNORE INTO offline_events "
                    "(to_username, type, msg_id, enc_body, created_at) VALUES (?,?,?,?,?)",
                    (r["to_username"], r["type"], r["msg_id"],
                     r["enc_body"] or "", r["created_at"])
                )
            print(f"offline_events: {len(rows)} migrated")
        except Exception as e:
            print(f"offline_events: skipped ({e})")

        await new.commit()
        print("\n=== Migration complete! ===")

        # Final check
        for table in ["users", "contacts", "device_registry", "messages",
                      "channels", "channel_members", "channel_keys"]:
            cur = await new.execute(f"SELECT COUNT(*) FROM {table}")
            r = await cur.fetchone()
            print(f"  NEW {table}: {r[0]}")

asyncio.run(migrate())
