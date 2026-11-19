#!/usr/bin/env python3
"""
split.py — механический split монолитного HTML на:
  static/style.css   — содержимое первого inline <style>
  static/app.js      — содержимое первого inline <script> (без src)
  index.html         — обёртка с <link rel="stylesheet"> и <script src>

Дополнительно:
  - инжектит <link rel="stylesheet" href="/liquid.css"> и <script src="/liquid.js" defer>
  - НЕ трогает внешние <script src="..."> (mesh.js, dialog.js остаются как есть)
  - сохраняет порядок: первым подключается liquid.css, потом локальный style.css
  - сохраняет порядок JS: mesh.js, dialog.js, liquid.js (defer), app.js

Usage:
  python split.py <input.html> <out_dir> [--mount /mount/path]

  --mount задаёт URL-префикс для static (по умолчанию /static).
"""
import re
import sys
import os
import argparse


def split_html(input_path: str, out_dir: str, mount: str = "/static") -> dict:
    with open(input_path, "r", encoding="utf-8") as f:
        html = f.read()

    os.makedirs(os.path.join(out_dir, "static"), exist_ok=True)

    # 1) вытаскиваем первый inline <style>...</style>
    style_re = re.compile(r"<style\b[^>]*>(.*?)</style>", re.DOTALL | re.IGNORECASE)
    m_style = style_re.search(html)
    css_count = 0
    if m_style:
        css = m_style.group(1).strip("\n")
        css_path = os.path.join(out_dir, "static", "style.css")
        with open(css_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(css)
        css_count = len(css.splitlines())
        html = html[: m_style.start()] + html[m_style.end():]

    # 2) вытаскиваем первый inline <script> БЕЗ src
    script_re = re.compile(
        r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", re.DOTALL | re.IGNORECASE
    )
    m_script = script_re.search(html)
    js_count = 0
    if m_script:
        js = m_script.group(1).strip("\n")
        js_path = os.path.join(out_dir, "static", "app.js")
        with open(js_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(js)
        js_count = len(js.splitlines())
        html = html[: m_script.start()] + html[m_script.end():]

    # 3) собираем ссылки чтобы вставить в правильное место
    base_static = mount.rstrip("/")
    link_css = f'<link rel="stylesheet" href="{base_static}/style.css">'
    link_liquid_css = '<link rel="stylesheet" href="/liquid.css">'
    script_app = f'<script src="{base_static}/app.js" defer></script>'
    script_liquid = '<script src="/liquid.js" defer></script>'

    # 3a) вставляем style.css ПЕРВЫМ, liquid.css ПОСЛЕДНИМ (чтобы liquid
    #     мог переопределять конкретные селекторы стиля).
    if "</head>" in html:
        inject = f"  {link_css}\n  {link_liquid_css}\n"
        html = html.replace("</head>", inject + "</head>", 1)

    # 3b) вставляем app.js перед </body>; liquid.js идёт первым (defer сохраняет порядок)
    if "</body>" in html:
        inject = f"  {script_liquid}\n  {script_app}\n"
        html = html.replace("</body>", inject + "</body>", 1)
    else:
        html += "\n" + script_liquid + "\n" + script_app + "\n"

    # 3c) записываем итоговый HTML
    out_html = os.path.join(out_dir, "index.html")
    with open(out_html, "w", encoding="utf-8", newline="\n") as f:
        f.write(html)

    return {
        "html_lines": len(html.splitlines()),
        "css_lines": css_count,
        "js_lines": js_count,
        "html_path": out_html,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("input")
    p.add_argument("out_dir")
    p.add_argument("--mount", default="/static",
                   help="URL prefix for css/js (default /static)")
    args = p.parse_args()
    info = split_html(args.input, args.out_dir, args.mount)
    print(f"split: html={info['html_lines']} css={info['css_lines']} js={info['js_lines']}")
    print(f"  out: {info['html_path']}")


if __name__ == "__main__":
    main()
