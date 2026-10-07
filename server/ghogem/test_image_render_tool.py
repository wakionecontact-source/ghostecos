import tempfile
from pathlib import Path
import image_render

class FakeAI:
    MAX_CHAT_STORAGE_BYTES = 20 * 1024 * 1024
    def __init__(self, root): self.root = root
    def _safe_path(self, user_id, chat_id, name):
        p = Path(self.root) / str(user_id) / str(chat_id) / "files" / name
        p.parent.mkdir(parents=True, exist_ok=True)
        return str(p)
    def _storage_write_bytes(self, user_id, chat_id, path, data, **kwargs):
        Path(path).write_bytes(data)
        return ""

svg = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 480">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="#7c3aed"/><stop offset="1" stop-color="#111827"/>
</linearGradient></defs>
<rect width="720" height="480" rx="42" fill="url(#g)"/>
<circle cx="585" cy="90" r="110" fill="#fff" opacity=".08"/>
<text x="60" y="220" font-family="sans-serif" font-size="72" font-weight="700" fill="white">GhoGemo</text>
<text x="64" y="275" font-family="sans-serif" font-size="28" fill="#ddd">лёгкая псевдогенерация</text>
</svg>"""

with tempfile.TemporaryDirectory(prefix="ghogemo-image-test-") as root:
    fake = FakeAI(root)
    result = image_render.generate_image(fake, 1, "test", svg=svg, filename="visual_test", width=720, height=480)
    assert not result.get("error"), result
    image = Path(root) / "1" / "test" / "files" / result["name"]
    source = Path(root) / "1" / "test" / "files" / result["source_name"]
    assert image.exists() and image.stat().st_size > 1000, result
    assert source.exists(), result
    print("PASS", result)
