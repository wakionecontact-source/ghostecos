from __future__ import annotations

import io
import os
import re
import time
from pathlib import Path

import cairosvg
from PIL import Image

MAX_SVG_CHARS = 220_000
MAX_PIXELS = 8_500_000
MIN_SIDE = 64
MAX_WIDTH = 2560
MAX_HEIGHT = 4096


def _clean_base_name(value: str) -> str:
    value = Path(str(value or "")).stem
    value = re.sub(r"[^0-9A-Za-zА-Яа-я_-]+", "_", value).strip("._-")
    return value[:64] or f"image_{int(time.time())}"


def _validate_dimensions(width: int, height: int) -> tuple[int, int]:
    width = int(width or 1080)
    height = int(height or 1080)
    if not (MIN_SIDE <= width <= MAX_WIDTH):
        raise ValueError(f"width должен быть {MIN_SIDE}..{MAX_WIDTH}")
    if not (MIN_SIDE <= height <= MAX_HEIGHT):
        raise ValueError(f"height должен быть {MIN_SIDE}..{MAX_HEIGHT}")
    if width * height > MAX_PIXELS:
        raise ValueError("Слишком большой холст")
    return width, height
def _validate_svg(svg: str) -> str | None:
    lowered = svg.lower()
    forbidden = (
        "<!doctype", "<!entity", "<script", "<foreignobject",
        "javascript:", "file://",
    )
    for token in forbidden:
        if token in lowered:
            return f"запрещённый фрагмент SVG: {token}"

    # URL references are allowed only for embedded data: resources.
    for match in re.finditer(r"url\s*\(([^)]*)\)", svg, flags=re.I):
        value = match.group(1).strip().strip("'\"")
        if value and not value.startswith(("#", "data:")):
            return "внешние url() в SVG запрещены"

    for match in re.finditer(r"(?:href|xlink:href)\s*=\s*['\"]([^'\"]+)['\"]", svg, flags=re.I):
        value = match.group(1).strip()
        if value and not value.startswith(("#", "data:")):
            return "внешние href в SVG запрещены"
    return None


def _normalize_svg(svg: str, width: int, height: int) -> str:
    svg = svg.strip()
    if not svg.startswith("<svg"):
        raise ValueError("нужен полный SVG с корневым <svg>")

    if not re.search(r"\bviewBox\s*=", svg[:1200], flags=re.I):
        svg = re.sub(
            r"<svg\b",
            f'<svg viewBox="0 0 {width} {height}"',
            svg,
            count=1,
            flags=re.I,
        )
    return svg
def generate_image(
    ai,
    user_id: int,
    chat_id: str,
    *,
    svg: str,
    filename: str = "",
    width: int = 1080,
    height: int = 1080,
    image_format: str = "png",
    quality: int = 92,
) -> dict:
    svg = str(svg or "")
    if not svg.strip():
        return {"error": "❌ SVG пуст."}
    if len(svg) > MAX_SVG_CHARS:
        return {"error": f"❌ SVG слишком большой: максимум {MAX_SVG_CHARS} символов."}

    try:
        width, height = _validate_dimensions(width, height)
        svg = _normalize_svg(svg, width, height)
    except (TypeError, ValueError) as exc:
        return {"error": f"❌ {exc}"}

    unsafe = _validate_svg(svg)
    if unsafe:
        return {"error": f"❌ Небезопасный SVG: {unsafe}."}

    image_format = str(image_format or "png").lower()
    if image_format == "jpg":
        image_format = "jpeg"
    if image_format not in {"png", "jpeg", "webp"}:
        return {"error": "❌ format должен быть png, jpeg или webp."}
    try:
        quality = max(30, min(int(quality or 92), 100))
    except (TypeError, ValueError):
        quality = 92

    base = _clean_base_name(filename)
    ext = "jpg" if image_format == "jpeg" else image_format
    image_name = f"{base}.{ext}"
    svg_name = f"{base}.svg"
    try:
        png_bytes = cairosvg.svg2png(
            bytestring=svg.encode("utf-8"),
            output_width=width,
            output_height=height,
        )

        if image_format == "png":
            image_bytes = png_bytes
        else:
            with Image.open(io.BytesIO(png_bytes)) as image:
                if image_format == "jpeg":
                    if image.mode in ("RGBA", "LA"):
                        background = Image.new("RGB", image.size, "white")
                        background.paste(image, mask=image.getchannel("A"))
                        image = background
                    else:
                        image = image.convert("RGB")
                output = io.BytesIO()
                image.save(
                    output,
                    format="JPEG" if image_format == "jpeg" else "WEBP",
                    quality=quality,
                    optimize=True,
                )
                image_bytes = output.getvalue()

        image_path = ai._safe_path(user_id, chat_id, image_name)
        error = ai._storage_write_bytes(
            user_id, chat_id, image_path, image_bytes,
            area="chat", overwrite=True, max_file_size=ai.MAX_CHAT_STORAGE_BYTES,
        )
        if error:
            return {"error": error}

        svg_path = ai._safe_path(user_id, chat_id, svg_name)
        svg_error = ai._storage_write_bytes(
            user_id, chat_id, svg_path, svg.encode("utf-8"),
            area="chat", overwrite=True, max_file_size=ai.MAX_CHAT_STORAGE_BYTES,
        )

        return {
            "name": image_name,
            "source_name": svg_name if not svg_error else None,
            "source_warning": svg_error or "",
            "size": len(image_bytes),
            "width": width,
            "height": height,
            "format": image_format,
        }
    except Exception as exc:
        return {"error": f"❌ Рендер изображения: {type(exc).__name__}: {str(exc)[:220]}"}
