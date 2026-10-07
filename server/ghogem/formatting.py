"""
Хелперы форматирования: Markdown → Telegram HTML,
починка незакрытых тегов, нарезка длинных сообщений.
"""

import re


def _escape_html(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def _fix_unmatched_tags(html: str) -> str:
    """Убирает незакрытые/лишние HTML-теги, которые ломают parse_mode=HTML."""
    simple_tags = ["b", "i", "u", "s", "code", "pre", "blockquote"]

    for tag in simple_tags:
        open_tag = f"<{tag}>"
        close_tag = f"</{tag}>"
        # варианты с атрибутами для pre/code
        open_re = re.compile(rf"<{tag}(?:\s[^>]*)?>", re.IGNORECASE)

        opens = len(open_re.findall(html))
        closes = html.lower().count(close_tag)

        # Удаляем лишние открывающие с конца
        while opens > closes:
            matches = list(open_re.finditer(html))
            if not matches:
                break
            last = matches[-1]
            html = html[: last.start()] + html[last.end() :]
            opens -= 1

        # Удаляем лишние закрывающие с начала
        while closes > opens:
            pos = html.lower().find(close_tag)
            if pos == -1:
                break
            html = html[:pos] + html[pos + len(close_tag) :]
            closes -= 1

    # <a href="...">
    a_open_pattern = r'<a\s+href="[^"]*">'
    a_close = "</a>"
    a_opens = len(re.findall(a_open_pattern, html, flags=re.IGNORECASE))
    a_closes = html.lower().count(a_close)

    while a_opens > a_closes:
        matches = list(re.finditer(a_open_pattern, html, flags=re.IGNORECASE))
        if not matches:
            break
        last = matches[-1]
        html = html[: last.start()] + html[last.end() :]
        a_opens -= 1

    while a_closes > a_opens:
        pos = html.lower().find(a_close)
        if pos == -1:
            break
        html = html[:pos] + html[pos + len(a_close) :]
        a_closes -= 1

    # Выкидываем любые оставшиеся битые куски вида <что-то без >
    # но не трогаем нормальные теги
    return html


def markdown_to_telegram_html(text: str) -> str:
    """Базовый Markdown → Telegram HTML + чистка think-тегов."""

    # Удаляем think/reasoning блоки
    text = re.sub(
        r"<(?:think|thinking|thought|reasoning)>(.*?)(?:</(?:think|thinking|thought|reasoning)>|$)",
        "",
        text,
        flags=re.DOTALL | re.IGNORECASE,
    )
    text = re.sub(
        r"</?(?:think|thinking|thought|reasoning)[^>]*>",
        "",
        text,
        flags=re.IGNORECASE,
    )

    # Прячем code blocks
    code_blocks = []

    def _stash_block(m):
        code_blocks.append((m.group(1) or "", m.group(2)))
        return f"\x00BLOCK{len(code_blocks) - 1}\x00"

    text = re.sub(r"```(\w*)\n?(.*?)```", _stash_block, text, flags=re.DOTALL)

    # Прячем inline code
    inline_codes = []

    def _stash_inline(m):
        inline_codes.append(m.group(1))
        return f"\x00INLINE{len(inline_codes) - 1}\x00"

    text = re.sub(r"`([^`\n]+?)`", _stash_inline, text)

    # Экранируем остальной текст
    text = _escape_html(text)

    # Жирный
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"__(.+?)__", r"<b>\1</b>", text)

    # Списки
    text = re.sub(r"^[ \t]*[-*+]\s+", "• ", text, flags=re.MULTILINE)

    # Курсив
    text = re.sub(r"(?<!\*)\*([^*\n]+?)\*(?!\*)", r"<i>\1</i>", text)
    text = re.sub(r"(?<!_)_([^_\n]+?)_(?!_)", r"<i>\1</i>", text)

    # Заголовки
    text = re.sub(r"^#{1,6}\s*(.+)$", r"<b>\1</b>", text, flags=re.MULTILINE)

    # Ссылки
    text = re.sub(
        r"\[([^\]]+)\]\((https?://[^\s)]+)\)",
        r'<a href="\2">\1</a>',
        text,
    )

    # Цитаты
    text = re.sub(
        r"^&gt;\s?(.+)$",
        r"<blockquote>\1</blockquote>",
        text,
        flags=re.MULTILINE,
    )

    # Возвращаем inline code
    for i, code in enumerate(inline_codes):
        text = text.replace(
            f"\x00INLINE{i}\x00",
            f"<code>{_escape_html(code)}</code>",
        )

    # Возвращаем code blocks
    for i, (lang, code) in enumerate(code_blocks):
        escaped = _escape_html(code.strip("\n"))
        if lang:
            block_html = f'<pre><code class="language-{lang}">{escaped}</code></pre>'
        else:
            block_html = f"<pre>{escaped}</pre>"
        text = text.replace(f"\x00BLOCK{i}\x00", block_html)

    text = _fix_unmatched_tags(text)
    return text.strip()


def strip_all_html(text: str) -> str:
    """Полностью убрать HTML-теги (fallback при ошибке парсинга)."""
    text = re.sub(r"<[^>]+>", "", text)
    return (
        text.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
    )


def split_text(text: str, limit: int = 3500) -> list[str]:
    """Режет длинный текст по абзацам/строкам."""
    if len(text) <= limit:
        return [text]

    parts = []
    remaining = text
    while len(remaining) > limit:
        split_at = remaining.rfind("\n\n", 0, limit)
        if split_at == -1:
            split_at = remaining.rfind("\n", 0, limit)
        if split_at == -1:
            split_at = remaining.rfind(" ", 0, limit)
        if split_at == -1:
            split_at = limit
        parts.append(remaining[:split_at].rstrip())
        remaining = remaining[split_at:].lstrip()
    if remaining:
        parts.append(remaining)
    return parts
