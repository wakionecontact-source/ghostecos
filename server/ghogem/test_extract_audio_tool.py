import asyncio
import os
import subprocess
import tempfile
from pathlib import Path

import media_services_v2
import storage_v2

def make_video(path: str, with_audio: bool):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
           "-f", "lavfi", "-i", "color=c=black:s=160x120:d=1"]
    if with_audio:
        cmd += ["-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-shortest", "-c:v", "libx264", "-c:a", "aac"]
    else:
        cmd += ["-c:v", "libx264", "-an"]
    cmd.append(path)
    subprocess.run(cmd, check=True, timeout=30)

async def main():
    with tempfile.TemporaryDirectory(prefix="ghogem-extract-test-") as root:
        class FakeAI:
            USERS_DIR = os.path.join(root, "users")
        source = os.path.join(root, "sample.mp4")
        make_video(source, True)
        saved = await media_services_v2.extract_audio_to_media(
            FakeAI, 12345, False, source, filename="voice_from_video.ogg"
        )
        assert not saved.get("error"), saved
        assert saved["name"].endswith(".ogg"), saved
        audio_path = storage_v2.temp_path(
            FakeAI.USERS_DIR, 12345, saved["name"], "media"
        )
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=codec_type",
             "-of", "default=noprint_wrappers=1:nokey=1", audio_path],
            text=True, capture_output=True, timeout=10,
        )
        assert probe.returncode == 0 and "audio" in probe.stdout, probe.stderr

        silent = os.path.join(root, "silent.mp4")
        make_video(silent, False)
        rejected = await media_services_v2.extract_audio_to_media(
            FakeAI, 12345, False, silent
        )
        assert rejected.get("error") and "нет звуковой дорожки" in rejected["error"]
        print("PASS: video audio extracted to owned temporary media")
        print("PASS: silent video rejected cleanly")

asyncio.run(main())
