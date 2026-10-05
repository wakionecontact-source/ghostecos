"""Build the GhostChat app-avatar set from a supplied image.

The source image is never overwritten.  The external background is removed
with a colour-distance alpha mask, so the transparent avatar and Android
notification icon stay lossless PNGs.  Every appearance variant uses the
same shape, size and position; only restrained colour palettes change.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageChops


SIZE = 1024
VARIANT_COUNT = 20

# Background/ghost pairs. The first two keep the requested monochrome
# examples; the remaining variants use visibly different, restrained colours
# that stay readable in a small circular crop. There are no neon gradients.
PALETTES = (
    ((0, 0, 0), (255, 255, 255)),
    ((255, 255, 255), (0, 0, 0)),
    ((19, 34, 56), (217, 231, 242)),
    ((54, 76, 99), (232, 241, 246)),
    ((18, 62, 67), (216, 238, 232)),
    ((62, 106, 104), (240, 241, 232)),
    ((30, 69, 53), (220, 235, 217)),
    ((85, 99, 74), (241, 232, 212)),
    ((59, 39, 72), (233, 221, 242)),
    ((107, 79, 104), (241, 225, 230)),
    ((83, 45, 53), (240, 217, 218)),
    ((131, 74, 67), (244, 225, 210)),
    ((74, 53, 43), (241, 221, 208)),
    ((120, 92, 73), (240, 225, 202)),
    ((103, 81, 42), (240, 230, 188)),
    ((138, 93, 71), (244, 226, 210)),
    ((30, 79, 92), (213, 236, 239)),
    ((48, 59, 104), (221, 227, 247)),
    ((45, 49, 54), (228, 182, 175)),
    ((85, 106, 119), (217, 229, 234)),
)

# The original supplied avatar occupies slot 01. Replace the old nineteenth
# colour slot with it, while keeping the twentieth colour as the final slot.
COLOR_PALETTES = PALETTES[:18] + PALETTES[19:]


def _background_colour(image: Image.Image) -> tuple[int, int, int]:
    pixels = image.load()
    samples = []
    step = max(1, min(image.size) // 32)
    for x in range(0, image.width, step):
        samples.append(pixels[x, 0])
        samples.append(pixels[x, image.height - 1])
    for y in range(0, image.height, step):
        samples.append(pixels[0, y])
        samples.append(pixels[image.width - 1, y])
    return tuple(sorted(channel)[len(samples) // 2] for channel in zip(*samples))


def _remove_background(image: Image.Image) -> tuple[Image.Image, Image.Image]:
    background = _background_colour(image)
    flat_background = Image.new("RGB", image.size, background)
    distance = ImageChops.difference(image, flat_background).convert("L")

    # Background compression/lighting variation is tiny in the supplied
    # image.  A short feather keeps the original ghost edge smooth while all
    # pixels close to the purple background become fully transparent.
    low, high = 18, 58
    alpha = distance.point(
        lambda value: 0
        if value <= low
        else 255
        if value >= high
        else round((value - low) * 255 / (high - low))
    )
    rgba = image.copy()
    rgba.putalpha(alpha)

    # The white ghost is the foreground.  Purple eyes and mouth are cutouts,
    # not a second coloured foreground, which makes the generated variants
    # clean two-colour marks on their chosen background.
    luminance = image.convert("L")
    white_shape = luminance.point(lambda value: 255 if value >= 150 else 0)
    body_mask = ImageChops.multiply(alpha, white_shape)
    return rgba, body_mask


def _save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True, compress_level=9)


def _variant(
    body_mask: Image.Image,
    palette: tuple[tuple[int, int, int], tuple[int, int, int]],
) -> Image.Image:
    background, foreground = palette
    result = Image.new("RGB", (SIZE, SIZE), background)
    layer = Image.new("RGB", body_mask.size, foreground)
    # Every variant uses the exact same source mask and placement. Only the
    # two colours differ, so choosing an avatar never changes its silhouette.
    result.paste(layer, (0, 0), body_mask)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--asset-dir", type=Path, required=True)
    parser.add_argument("--notification", type=Path, required=True)
    parser.add_argument("--android-avatar-dir", type=Path)
    args = parser.parse_args()

    source = Image.open(args.source).convert("RGB")
    if source.size != (SIZE, SIZE):
        source = source.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    transparent, body_mask = _remove_background(source)

    _save(transparent, args.asset_dir / "app_avatar_source.png")

    # Slot 01 is the supplied original image, encoded losslessly as PNG after
    # the source JPEG has been decoded. The transparent version above remains
    # the source for the notification icon and is not shown as a launcher tile.
    _save(source, args.asset_dir / "app_avatar_01.png")
    if args.android_avatar_dir is not None:
        _save(source, args.android_avatar_dir / "app_avatar_01.png")

    for index, palette in enumerate(COLOR_PALETTES, start=1):
        variant = _variant(body_mask, palette)
        slot = index + 1
        _save(variant, args.asset_dir / f"app_avatar_{slot:02d}.png")
        if args.android_avatar_dir is not None:
            _save(
                variant,
                args.android_avatar_dir / f"app_avatar_{slot:02d}.png",
            )

    notification_mask = body_mask.resize((192, 192), Image.Resampling.LANCZOS)
    notification = Image.new("RGBA", (192, 192), (255, 255, 255, 0))
    notification.putalpha(notification_mask)
    _save(notification, args.notification)

    print(
        f"generated original plus {len(COLOR_PALETTES)} colour variants, "
        "transparent source and notification icon"
    )
    print(f"background colour: {_background_colour(source)}")


if __name__ == "__main__":
    main()
