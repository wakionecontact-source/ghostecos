#!/usr/bin/env python3
"""Удаляет миниски (soc_posts.kind='miniska') старше 48 часов.
Удаляет: пост, медиафайл с диска, реакции, комменты, уведомления связанные с постом.

Запускается systemd-таймером каждый час.
"""
import sqlite3
import os
import json
import sys

DB = '/opt/ghostchat/ghostchat.db'
MEDIA_DIR = '/var/www/ghostsocial/media'
MAX_AGE_HOURS = 48

def main():
    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row
    rows = c.execute(
        f"SELECT id, media FROM soc_posts WHERE kind='miniska' "
        f"AND (strftime('%s','now') - strftime('%s', created_at)) > {MAX_AGE_HOURS * 3600}"
    ).fetchall()
    if not rows:
        print("nothing to delete")
        return
    ids = [r['id'] for r in rows]
    print(f"deleting {len(ids)} miniska(s): {ids}")
    # Удаляем файлы
    removed_files = 0
    for r in rows:
        if not r['media']:
            continue
        try:
            for m in json.loads(r['media']):
                fname = (m.get('url') or '').split('/')[-1]
                if not fname:
                    continue
                fp = os.path.join(MEDIA_DIR, fname)
                if os.path.exists(fp):
                    try:
                        os.remove(fp)
                        removed_files += 1
                    except Exception as e:
                        print(f"  ! file {fname}: {e}", file=sys.stderr)
        except Exception as e:
            print(f"  ! media parse {r['id']}: {e}", file=sys.stderr)
    print(f"removed {removed_files} file(s)")
    # Удаляем связанные данные
    placeholders = ",".join("?" * len(ids))
    c.execute(f"DELETE FROM soc_reactions WHERE post_id IN ({placeholders})", ids)
    c.execute(f"DELETE FROM soc_comments WHERE post_id IN ({placeholders})", ids)
    c.execute(f"DELETE FROM soc_notifications WHERE post_id IN ({placeholders})", ids)
    c.execute(f"DELETE FROM soc_polls WHERE post_id IN ({placeholders})", ids)
    c.execute(f"DELETE FROM soc_poll_votes WHERE post_id IN ({placeholders})", ids)
    c.execute(f"DELETE FROM soc_posts WHERE id IN ({placeholders})", ids)
    c.commit()
    c.close()
    print("done")

if __name__ == '__main__':
    main()
