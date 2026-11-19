#!/usr/bin/env python3
# Идемпотентный патч nginx-конфига: отдать /bank/giveaway/ из
# /var/www/bank/giveaway/index.html отдельным точным location, не трогая
# SPA-блок банка (его try_files $uri /bank/index.html не отдаёт index из
# подкаталога). Без $uri/ — чтобы не словить 403 на листинге директории.
import sys

PATH = "/etc/nginx/sites-enabled/ghostchat"
ANCHOR = "    location = /bank { return 301 /bank/$is_args$args; }"
BLOCK = ANCHOR + "\n" + (
    "    location = /bank/giveaway  { return 301 /bank/giveaway/$is_args$args; }\n"
    "    location = /bank/giveaway/ {\n"
    "        root /var/www;\n"
    "        try_files /bank/giveaway/index.html =404;\n"
    "        add_header Cache-Control \"no-store\" always;\n"
    "    }"
)

with open(PATH, encoding="utf-8") as f:
    s = f.read()

if "location = /bank/giveaway/" in s:
    print("ALREADY_PATCHED")
    sys.exit(0)
if ANCHOR not in s:
    print("ANCHOR_NOT_FOUND")
    sys.exit(2)

with open(PATH, "w", encoding="utf-8") as f:
    f.write(s.replace(ANCHOR, BLOCK, 1))
print("PATCHED")
