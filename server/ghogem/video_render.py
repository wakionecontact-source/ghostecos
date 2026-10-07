from __future__ import annotations

import io
import json
import math
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

import cairosvg
from PIL import Image, ImageColor

import image_render

MAX_SCENES = 12
MAX_LAYERS = 10
MAX_TOTAL_DURATION_SECONDS = 30.0
MAX_ANIMATED_DURATION_SECONDS = 15.0
MIN_SCENE_DURATION_SECONDS = 0.35
MAX_SCENE_DURATION_SECONDS = 12.0
MIN_FPS = 12
MAX_FPS = 30
MAX_ANIMATED_FPS = 24
MAX_VIDEO_PIXELS = 2_200_000
MAX_SCENE_SVG_CHARS = 120_000
MAX_TOTAL_SVG_CHARS = 520_000
MAX_TRANSITION_SECONDS = 1.5
MAX_KEYFRAMES = 16
MAX_SPEED = 5000.0
MAX_SHAKE = 24.0

ALLOWED_TRANSITIONS = {
    "fade",
    "dissolve",
    "wipeleft",
    "wiperight",
    "wipeup",
    "wipedown",
    "slideleft",
    "slideright",
    "slideup",
    "slidedown",
    "zoomin",
    "fadeblack",
    "fadewhite",
}

ALLOWED_EASING = {
    "linear",
    "ease_in",
    "ease_out",
    "ease_in_out",
}


def _clean_base_name(value: str) -> str:
    value = Path(str(value or "")).stem
    value = re.sub(r"[^0-9A-Za-zА-Яа-я_-]+", "_", value).strip("._-")
    return value[:64] or f"video_{int(time.time())}"


def _validate_video_dimensions(width: int, height: int) -> tuple[int, int]:
    width, height = image_render._validate_dimensions(width, height)
    if width * height > MAX_VIDEO_PIXELS:
        raise ValueError(
            "Для видео слишком большое разрешение; используй до 1080×1920, "
            "1920×1080 или сопоставимое по площади."
        )
    width -= width % 2
    height -= height % 2
    return max(width, 64), max(height, 64)


def _safe_float(value, default: float = 0.0) -> float:
    try:
        out = float(value)
    except (TypeError, ValueError):
        return float(default)
    if not math.isfinite(out):
        return float(default)
    return out


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _parse_background(value: str) -> tuple[int, int, int, int]:
    raw = str(value or "#000000").strip()
    if len(raw) > 40:
        raw = "#000000"
    try:
        return ImageColor.getcolor(raw, "RGBA")
    except Exception:
        raise ValueError("неверный background; используй CSS-цвет вроде #101018")


def _scene_png(svg: str, width: int, height: int) -> bytes:
    svg = str(svg or "").strip()
    if not svg:
        raise ValueError("пустой SVG сцены")
    if len(svg) > MAX_SCENE_SVG_CHARS:
        raise ValueError(
            f"SVG одной сцены слишком большой: максимум {MAX_SCENE_SVG_CHARS} символов"
        )
    normalized = image_render._normalize_svg(svg, width, height)
    unsafe = image_render._validate_svg(normalized)
    if unsafe:
        raise ValueError(f"небезопасный SVG: {unsafe}")
    return cairosvg.svg2png(
        bytestring=normalized.encode("utf-8"),
        output_width=width,
        output_height=height,
    )


def _scene_rgba(svg: str, width: int, height: int) -> Image.Image:
    return Image.open(io.BytesIO(_scene_png(svg, width, height))).convert("RGBA")


def _normalized_scene(scene: dict, index: int) -> dict:
    if not isinstance(scene, dict):
        raise ValueError(f"сцена {index + 1} должна быть объектом")
    svg = str(scene.get("svg") or "")
    try:
        duration = float(scene.get("duration") or 2.0)
    except (TypeError, ValueError):
        raise ValueError(f"неверная длительность сцены {index + 1}")
    if not (MIN_SCENE_DURATION_SECONDS <= duration <= MAX_SCENE_DURATION_SECONDS):
        raise ValueError(
            f"длительность сцены {index + 1} должна быть "
            f"{MIN_SCENE_DURATION_SECONDS}..{MAX_SCENE_DURATION_SECONDS} сек"
        )

    transition = str(scene.get("transition") or "fade").strip().lower()
    if transition == "cut":
        transition = "fade"
        transition_duration = 0.02
    else:
        if transition not in ALLOWED_TRANSITIONS:
            raise ValueError(
                f"неизвестный переход сцены {index + 1}: {transition}"
            )
        try:
            transition_duration = float(
                scene.get("transition_duration")
                if scene.get("transition_duration") is not None
                else 0.35
            )
        except (TypeError, ValueError):
            raise ValueError(f"неверная длительность перехода сцены {index + 1}")
        transition_duration = max(
            0.05, min(transition_duration, MAX_TRANSITION_SECONDS)
        )

    return {
        "svg": svg,
        "duration": duration,
        "transition": transition,
        "transition_duration": transition_duration,
    }


def _eased(value: float, easing: str) -> float:
    value = _clamp(value, 0.0, 1.0)
    if easing == "ease_in":
        return value * value
    if easing == "ease_out":
        return 1.0 - (1.0 - value) * (1.0 - value)
    if easing == "ease_in_out":
        return 2.0 * value * value if value < 0.5 else 1.0 - ((-2.0 * value + 2.0) ** 2) / 2.0
    return value


def _normalize_keyframes(
    raw_frames,
    *,
    duration: float,
    base: dict,
    camera: bool = False,
) -> list[dict]:
    if not raw_frames:
        return []
    if not isinstance(raw_frames, list) or len(raw_frames) > MAX_KEYFRAMES:
        raise ValueError(f"keyframes: максимум {MAX_KEYFRAMES}")
    allowed = ("x", "y", "zoom", "rotation") if camera else (
        "x", "y", "scale", "rotation", "opacity"
    )
    frames = []
    carry = dict(base)
    for index, raw in enumerate(raw_frames):
        if not isinstance(raw, dict):
            raise ValueError(f"keyframe {index + 1} должен быть объектом")
        t = _safe_float(raw.get("t"), -1.0)
        if not 0.0 <= t <= duration:
            raise ValueError(f"keyframe {index + 1}: t должен быть 0..duration")
        frame = {"t": t}
        for key in allowed:
            if raw.get(key) is not None:
                carry[key] = _safe_float(raw.get(key), carry.get(key, 0.0))
            frame[key] = carry.get(key, base.get(key, 0.0))
        frame["easing"] = str(raw.get("easing") or "").strip().lower()
        if frame["easing"] and frame["easing"] not in ALLOWED_EASING:
            raise ValueError(f"keyframe {index + 1}: неизвестный easing")
        frames.append(frame)
    frames.sort(key=lambda item: item["t"])
    if not frames or frames[0]["t"] > 0:
        first = {"t": 0.0, **base, "easing": ""}
        frames.insert(0, first)
    if frames[-1]["t"] < duration:
        last = dict(frames[-1])
        last["t"] = duration
        last["easing"] = ""
        frames.append(last)
    return frames


def _normalize_motion(raw: dict | None, *, duration: float, camera: bool = False) -> dict:
    raw = raw if isinstance(raw, dict) else {}
    if camera:
        base = {
            "x": _safe_float(raw.get("x"), 0.0),
            "y": _safe_float(raw.get("y"), 0.0),
            "zoom": _clamp(_safe_float(raw.get("zoom"), 1.0), 0.5, 2.0),
            "rotation": _clamp(_safe_float(raw.get("rotation"), 0.0), -45.0, 45.0),
        }
        result = {
            **base,
            "velocity_x": _clamp(_safe_float(raw.get("velocity_x"), 0.0), -MAX_SPEED, MAX_SPEED),
            "velocity_y": _clamp(_safe_float(raw.get("velocity_y"), 0.0), -MAX_SPEED, MAX_SPEED),
            "zoom_velocity": _clamp(_safe_float(raw.get("zoom_velocity"), 0.0), -1.0, 1.0),
            "rotation_speed": _clamp(_safe_float(raw.get("rotation_speed"), 0.0), -180.0, 180.0),
            "shake": _clamp(_safe_float(raw.get("shake"), 0.0), 0.0, MAX_SHAKE),
            "shake_frequency": _clamp(_safe_float(raw.get("shake_frequency"), 2.0), 0.1, 12.0),
            "easing": str(raw.get("easing") or "linear").strip().lower(),
        }
    else:
        base = {
            "x": _safe_float(raw.get("x"), 0.0),
            "y": _safe_float(raw.get("y"), 0.0),
            "scale": _clamp(_safe_float(raw.get("scale"), 1.0), 0.1, 4.0),
            "rotation": _clamp(_safe_float(raw.get("rotation"), 0.0), -360.0, 360.0),
            "opacity": _clamp(_safe_float(raw.get("opacity"), 1.0), 0.0, 1.0),
        }
        result = {
            **base,
            "velocity_x": _clamp(_safe_float(raw.get("velocity_x"), 0.0), -MAX_SPEED, MAX_SPEED),
            "velocity_y": _clamp(_safe_float(raw.get("velocity_y"), 0.0), -MAX_SPEED, MAX_SPEED),
            "scale_velocity": _clamp(_safe_float(raw.get("scale_velocity"), 0.0), -2.0, 2.0),
            "rotation_speed": _clamp(_safe_float(raw.get("rotation_speed"), 0.0), -720.0, 720.0),
            "repeat_x": bool(raw.get("repeat_x", False)),
            "repeat_y": bool(raw.get("repeat_y", False)),
            "easing": str(raw.get("easing") or "linear").strip().lower(),
        }
    if result["easing"] not in ALLOWED_EASING:
        raise ValueError("неизвестный easing")
    result["keyframes"] = _normalize_keyframes(
        raw.get("keyframes"),
        duration=duration,
        base=base,
        camera=camera,
    )
    return result


def _normalized_layer(layer: dict, index: int, *, duration: float) -> dict:
    if not isinstance(layer, dict):
        raise ValueError(f"слой {index + 1} должен быть объектом")
    svg = str(layer.get("svg") or "").strip()
    if not svg:
        raise ValueError(f"слой {index + 1}: пустой svg")
    if len(svg) > MAX_SCENE_SVG_CHARS:
        raise ValueError(f"слой {index + 1}: SVG слишком большой")
    motion = _normalize_motion(layer.get("motion"), duration=duration, camera=False)
    return {
        "name": str(layer.get("name") or f"layer_{index + 1}")[:60],
        "svg": svg,
        "z": int(_clamp(_safe_float(layer.get("z"), index), -100, 100)),
        "motion": motion,
    }


def _props_at(motion: dict, t: float, *, camera: bool = False) -> dict:
    keys = ("x", "y", "zoom", "rotation") if camera else (
        "x", "y", "scale", "rotation", "opacity"
    )
    props = {key: float(motion.get(key, 0.0)) for key in keys}
    frames = motion.get("keyframes") or []
    if frames:
        left, right = frames[0], frames[-1]
        for idx in range(len(frames) - 1):
            if frames[idx]["t"] <= t <= frames[idx + 1]["t"]:
                left, right = frames[idx], frames[idx + 1]
                break
        span = max(1e-9, float(right["t"]) - float(left["t"]))
        amount = _clamp((t - float(left["t"])) / span, 0.0, 1.0)
        easing = str(left.get("easing") or motion.get("easing") or "linear")
        amount = _eased(amount, easing)
        for key in keys:
            a = float(left.get(key, props[key]))
            b = float(right.get(key, a))
            props[key] = a + (b - a) * amount

    props["x"] = props.get("x", 0.0) + float(motion.get("velocity_x", 0.0)) * t
    props["y"] = props.get("y", 0.0) + float(motion.get("velocity_y", 0.0)) * t
    props["rotation"] = props.get("rotation", 0.0) + float(motion.get("rotation_speed", 0.0)) * t
    if camera:
        props["zoom"] = _clamp(
            props.get("zoom", 1.0) + float(motion.get("zoom_velocity", 0.0)) * t,
            0.5,
            2.0,
        )
    else:
        props["scale"] = _clamp(
            props.get("scale", 1.0) + float(motion.get("scale_velocity", 0.0)) * t,
            0.1,
            4.0,
        )
        props["opacity"] = _clamp(props.get("opacity", 1.0), 0.0, 1.0)
    return props


def _with_opacity(image: Image.Image, opacity: float) -> Image.Image:
    if opacity >= 0.999:
        return image
    if opacity <= 0.001:
        return Image.new("RGBA", image.size, (0, 0, 0, 0))
    out = image.copy()
    alpha = out.getchannel("A")
    alpha = alpha.point(lambda p: int(p * opacity))
    out.putalpha(alpha)
    return out


def _transform_layer(image: Image.Image, props: dict) -> tuple[Image.Image, int, int]:
    width, height = image.size
    scale = float(props.get("scale", 1.0))
    rotation = float(props.get("rotation", 0.0))
    opacity = float(props.get("opacity", 1.0))
    transformed = image

    if abs(scale - 1.0) > 0.002:
        new_size = (
            max(1, int(round(width * scale))),
            max(1, int(round(height * scale))),
        )
        transformed = transformed.resize(new_size, Image.Resampling.BICUBIC)
    if abs(rotation) > 0.02:
        transformed = transformed.rotate(
            rotation,
            resample=Image.Resampling.BICUBIC,
            expand=True,
        )
    if opacity < 0.999:
        transformed = _with_opacity(transformed, opacity)

    x = int(round((width - transformed.width) / 2.0 + float(props.get("x", 0.0))))
    y = int(round((height - transformed.height) / 2.0 + float(props.get("y", 0.0))))
    return transformed, x, y


def _paste_repeating(
    canvas: Image.Image,
    image: Image.Image,
    x: int,
    y: int,
    *,
    repeat_x: bool,
    repeat_y: bool,
) -> None:
    period_x = max(1, image.width)
    period_y = max(1, image.height)
    xs = [x]
    ys = [y]
    if repeat_x:
        base_x = x % period_x
        xs = [base_x - period_x, base_x, base_x + period_x]
    if repeat_y:
        base_y = y % period_y
        ys = [base_y - period_y, base_y, base_y + period_y]
    for px in xs:
        for py in ys:
            canvas.alpha_composite(image, dest=(int(px), int(py)))


def _apply_camera(
    frame: Image.Image,
    background: tuple[int, int, int, int],
    motion: dict,
    t: float,
) -> Image.Image:
    props = _props_at(motion, t, camera=True)
    shake = float(motion.get("shake", 0.0))
    freq = float(motion.get("shake_frequency", 2.0))
    shake_x = shake * math.sin(2.0 * math.pi * freq * t)
    shake_y = shake * 0.7 * math.cos(2.0 * math.pi * freq * 1.37 * t)

    zoom = float(props.get("zoom", 1.0))
    rotation = float(props.get("rotation", 0.0))
    transformed = frame
    if abs(zoom - 1.0) > 0.002:
        transformed = transformed.resize(
            (
                max(1, int(round(frame.width * zoom))),
                max(1, int(round(frame.height * zoom))),
            ),
            Image.Resampling.BICUBIC,
        )
    if abs(rotation) > 0.02:
        transformed = transformed.rotate(
            -rotation,
            resample=Image.Resampling.BICUBIC,
            expand=True,
        )

    output = Image.new("RGBA", frame.size, background)
    x = int(round(
        (frame.width - transformed.width) / 2.0
        - float(props.get("x", 0.0))
        + shake_x
    ))
    y = int(round(
        (frame.height - transformed.height) / 2.0
        - float(props.get("y", 0.0))
        + shake_y
    ))
    output.alpha_composite(transformed, dest=(x, y))
    return output


def _render_animated_video(
    *,
    output_path: Path,
    layers: list[dict],
    duration: float,
    width: int,
    height: int,
    fps: int,
    background: tuple[int, int, int, int],
    camera: dict,
) -> None:
    rendered_layers = []
    for layer in sorted(layers, key=lambda item: item["z"]):
        rendered_layers.append((layer, _scene_rgba(layer["svg"], width, height)))

    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "-s", f"{width}x{height}",
        "-r", str(fps),
        "-i", "-",
        "-an",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "23",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        str(output_path),
    ]
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    total_frames = max(1, int(round(duration * fps)))
    try:
        assert proc.stdin is not None
        for frame_index in range(total_frames):
            t = min(duration, frame_index / float(fps))
            frame = Image.new("RGBA", (width, height), background)
            for layer, layer_image in rendered_layers:
                props = _props_at(layer["motion"], t, camera=False)
                transformed, x, y = _transform_layer(layer_image, props)
                _paste_repeating(
                    frame,
                    transformed,
                    x,
                    y,
                    repeat_x=bool(layer["motion"].get("repeat_x")),
                    repeat_y=bool(layer["motion"].get("repeat_y")),
                )
            frame = _apply_camera(frame, background, camera, t)
            proc.stdin.write(frame.convert("RGB").tobytes())
        proc.stdin.close()
        proc.stdin = None
        stderr = proc.stderr.read() if proc.stderr is not None else b""
        returncode = proc.wait(timeout=120)
        if returncode != 0 or not output_path.is_file():
            detail = stderr.decode("utf-8", errors="replace")[-700:]
            raise RuntimeError(detail or "ffmpeg не создал MP4")
    except Exception:
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except Exception:
            pass
        try:
            proc.kill()
        except Exception:
            pass
        raise


def _render_slideshow_video(
    *,
    output_path: Path,
    normalized: list[dict],
    width: int,
    height: int,
    fps: int,
    temp_dir: Path,
) -> float:
    input_paths: list[Path] = []
    for index, scene in enumerate(normalized):
        png = _scene_png(scene["svg"], width, height)
        path = temp_dir / f"scene_{index:02d}.png"
        path.write_bytes(png)
        input_paths.append(path)

    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
    for scene, path in zip(normalized, input_paths):
        cmd += [
            "-loop", "1",
            "-framerate", str(fps),
            "-t", f"{scene['duration']:.3f}",
            "-i", str(path),
        ]

    chains: list[str] = []
    for i in range(len(normalized)):
        chains.append(
            f"[{i}:v]fps={fps},format=yuv420p,"
            f"settb=AVTB,setpts=PTS-STARTPTS[v{i}]"
        )

    if len(normalized) == 1:
        final_label = "v0"
        actual_duration = normalized[0]["duration"]
    else:
        current = "v0"
        current_duration = normalized[0]["duration"]
        for i in range(1, len(normalized)):
            scene = normalized[i]
            transition_duration = min(
                scene["transition_duration"],
                max(0.02, current_duration - 0.02),
                max(0.02, scene["duration"] - 0.02),
            )
            offset = max(0.0, current_duration - transition_duration)
            out_label = f"x{i}"
            chains.append(
                f"[{current}][v{i}]xfade="
                f"transition={scene['transition']}:"
                f"duration={transition_duration:.3f}:"
                f"offset={offset:.3f}[{out_label}]"
            )
            current = out_label
            current_duration += scene["duration"] - transition_duration
        final_label = current
        actual_duration = current_duration

    cmd += [
        "-filter_complex", ";".join(chains),
        "-map", f"[{final_label}]",
        "-an",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "23",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        "-t", f"{actual_duration:.3f}",
        str(output_path),
    ]

    completed = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        check=False,
    )
    if completed.returncode != 0 or not output_path.is_file():
        detail = completed.stderr.decode("utf-8", errors="replace")[-500:]
        raise RuntimeError(detail or "ffmpeg не создал MP4")
    return actual_duration


def generate_video(
    ai,
    user_id: int,
    chat_id: str,
    *,
    mode: str = "",
    scenes: list[dict] | None = None,
    layers: list[dict] | None = None,
    duration: float = 0,
    background: str = "#000000",
    camera: dict | None = None,
    filename: str = "",
    width: int = 1280,
    height: int = 720,
    fps: int = 24,
) -> dict:
    scenes = scenes or []
    layers = layers or []
    mode = str(mode or ("animated" if layers else "slideshow")).strip().lower()
    if mode not in {"animated", "slideshow"}:
        return {"error": "❌ mode должен быть animated или slideshow."}

    try:
        width, height = _validate_video_dimensions(width, height)
        fps = int(fps or 24)
        if not (MIN_FPS <= fps <= MAX_FPS):
            raise ValueError(f"fps должен быть {MIN_FPS}..{MAX_FPS}")
    except (TypeError, ValueError) as exc:
        return {"error": f"❌ {exc}"}

    base = _clean_base_name(filename)
    video_name = f"{base}.mp4"
    source_name = f"{base}.video.json"

    try:
        if mode == "slideshow":
            if not isinstance(scenes, list) or not scenes:
                return {"error": "❌ Для slideshow нужен непустой список scenes."}
            if len(scenes) > MAX_SCENES:
                return {"error": f"❌ Слишком много сцен: максимум {MAX_SCENES}."}
            normalized = [_normalized_scene(scene, i) for i, scene in enumerate(scenes)]
            total_svg_chars = sum(len(scene["svg"]) for scene in normalized)
            if total_svg_chars > MAX_TOTAL_SVG_CHARS:
                return {"error": f"❌ Суммарный SVG слишком большой: максимум {MAX_TOTAL_SVG_CHARS} символов."}
            nominal_duration = sum(scene["duration"] for scene in normalized)
            if nominal_duration > MAX_TOTAL_DURATION_SECONDS:
                return {"error": f"❌ Видео слишком длинное: максимум {MAX_TOTAL_DURATION_SECONDS:g} секунд."}

            with tempfile.TemporaryDirectory(prefix="ghogem-video-") as tmp:
                temp_dir = Path(tmp)
                output_path = temp_dir / video_name
                actual_duration = _render_slideshow_video(
                    output_path=output_path,
                    normalized=normalized,
                    width=width,
                    height=height,
                    fps=fps,
                    temp_dir=temp_dir,
                )
                video_bytes = output_path.read_bytes()

            source_payload = {
                "version": 2,
                "mode": "slideshow",
                "width": width,
                "height": height,
                "fps": fps,
                "duration": round(actual_duration, 3),
                "scenes": normalized,
            }
            item_count = len(normalized)

        else:
            if not isinstance(layers, list) or not layers:
                return {"error": "❌ Для animated нужен непустой список layers."}
            if len(layers) > MAX_LAYERS:
                return {"error": f"❌ Слишком много слоёв: максимум {MAX_LAYERS}."}
            duration = _safe_float(duration, 6.0)
            if not 0.5 <= duration <= MAX_ANIMATED_DURATION_SECONDS:
                return {
                    "error": (
                        f"❌ animated-видео: duration должен быть 0.5.."
                        f"{MAX_ANIMATED_DURATION_SECONDS:g} секунд."
                    )
                }
            if fps > MAX_ANIMATED_FPS:
                return {"error": f"❌ animated-видео: максимум {MAX_ANIMATED_FPS} FPS."}
            normalized_layers = [
                _normalized_layer(layer, i, duration=duration)
                for i, layer in enumerate(layers)
            ]
            total_svg_chars = sum(len(layer["svg"]) for layer in normalized_layers)
            if total_svg_chars > MAX_TOTAL_SVG_CHARS:
                return {"error": f"❌ Суммарный SVG слоёв слишком большой: максимум {MAX_TOTAL_SVG_CHARS} символов."}
            bg = _parse_background(background)
            normalized_camera = _normalize_motion(camera, duration=duration, camera=True)

            with tempfile.TemporaryDirectory(prefix="ghogem-video-") as tmp:
                output_path = Path(tmp) / video_name
                _render_animated_video(
                    output_path=output_path,
                    layers=normalized_layers,
                    duration=duration,
                    width=width,
                    height=height,
                    fps=fps,
                    background=bg,
                    camera=normalized_camera,
                )
                video_bytes = output_path.read_bytes()

            actual_duration = duration
            source_payload = {
                "version": 2,
                "mode": "animated",
                "width": width,
                "height": height,
                "fps": fps,
                "duration": round(duration, 3),
                "background": background,
                "camera": normalized_camera,
                "layers": normalized_layers,
            }
            item_count = len(normalized_layers)

        source_bytes = json.dumps(
            source_payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")

        video_path = ai._safe_path(user_id, chat_id, video_name)
        error = ai._storage_write_bytes(
            user_id,
            chat_id,
            video_path,
            video_bytes,
            area="chat",
            overwrite=True,
            max_file_size=ai.MAX_CHAT_STORAGE_BYTES,
        )
        if error:
            return {"error": error}

        source_path = ai._safe_path(user_id, chat_id, source_name)
        source_error = ai._storage_write_bytes(
            user_id,
            chat_id,
            source_path,
            source_bytes,
            area="chat",
            overwrite=True,
            max_file_size=ai.MAX_CHAT_STORAGE_BYTES,
        )

        return {
            "name": video_name,
            "source_name": source_name if not source_error else None,
            "source_warning": source_error or "",
            "size": len(video_bytes),
            "width": width,
            "height": height,
            "fps": fps,
            "duration": round(actual_duration, 2),
            "mode": mode,
            "items": item_count,
            "scenes": item_count if mode == "slideshow" else 0,
            "layers": item_count if mode == "animated" else 0,
        }
    except subprocess.TimeoutExpired:
        return {"error": "❌ Рендер видео занял слишком много времени."}
    except Exception as exc:
        return {
            "error": (
                f"❌ Рендер видео: {type(exc).__name__}: "
                f"{str(exc)[:320]}"
            )
        }
