#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Turn the clients' screenshot galleries into store-ready PNGs."""

from io import BytesIO
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

REPO_ROOT = Path(__file__).resolve().parent.parent

IPHONE_SIZES = {
    (1260, 2736),
    (1290, 2796),
    (1320, 2868),
}
IPAD_SIZES = {
    (2048, 2732),
    (2064, 2752),
}
MAC_SIZE = (1440, 900)
ANDROID_SIZE = (1080, 1920)
MAC_BACKGROUND = (30, 30, 30)

# The windows' own corner radii, so the store image keeps their shape. Measured
# from the captures: macOS 26 rounds its settings window more than the main one.
MAC_CORNER_RADIUS = {
    "15": {"main": 10, "settings": 10},
    "26": {"main": 15, "settings": 26},
}
MAIN_WINDOW_SCREENS = {"first-time", "grant-vpn"}
# WindowServer draws the window's edge, and a hairline along its corner arcs,
# against whatever is behind them, and not the same way twice. A band this wide
# inside the edge is repainted from the window's own colours further in, and gets
# a hairline of its own.
MAC_EDGE = 5
MAC_BORDER = {"light": (0xD9, 0xD9, 0xD9), "dark": (0x63, 0x63, 0x63)}
MAC_SHADOW_OFFSET = (0, 50)
MAC_SHADOW_BLUR = 35
MAC_SHADOW_OPACITY = 0.6


def screenshots(directory: Path) -> list[Path]:
    paths = sorted(directory.glob("*.png"))
    if not paths:
        raise RuntimeError(f"No screenshots found in {directory.relative_to(REPO_ROOT)}")

    return paths


def write_rgb(path: Path, image: Image.Image) -> None:
    output = BytesIO()
    image.convert("RGB").save(output, format="PNG")
    path.write_bytes(output.getvalue())


def prepare_ios(directory: Path, accepted_sizes: set[tuple[int, int]]) -> None:
    accepted_orientations = accepted_sizes | {
        (height, width) for width, height in accepted_sizes
    }

    for path in screenshots(directory):
        with Image.open(path) as image:
            if image.size not in accepted_orientations:
                relative = path.relative_to(REPO_ROOT)
                raise RuntimeError(f"{relative} has unsupported dimensions {image.size}")

            write_rgb(path, image)


def rounded_mask(size: tuple[int, int], radius: int, inset: int = 0) -> Image.Image:
    """An antialiased rounded rectangle, `inset` pixels in from every edge."""
    scale = 4
    width, height = size
    mask = Image.new("L", (width * scale, height * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (
            inset * scale,
            inset * scale,
            (width - inset) * scale - 1,
            (height - inset) * scale - 1,
        ),
        radius=radius * scale,
        fill=255,
    )

    return mask.resize(size, Image.Resampling.BOX)


def repainted_edge(window: Image.Image, radius: int) -> Image.Image:
    """The window with its outer band redrawn from the colours just inside it.

    Each edge is stretched from the line `MAC_EDGE` pixels in; each corner square
    is filled from a point on the same edge past the arc, where the titlebar or
    the window body is plain.
    """
    width, height = window.size
    edge = MAC_EDGE
    inside = window.crop((edge, edge, width - edge, height - edge))
    nearest = Image.Resampling.NEAREST

    filled = window.copy()
    top = inside.crop((0, 0, inside.width, 1))
    bottom = inside.crop((0, inside.height - 1, inside.width, inside.height))
    left = inside.crop((0, 0, 1, inside.height))
    right = inside.crop((inside.width - 1, 0, inside.width, inside.height))
    filled.paste(top.resize((inside.width, edge), nearest), (edge, 0))
    filled.paste(bottom.resize((inside.width, edge), nearest), (edge, height - edge))
    filled.paste(left.resize((edge, inside.height), nearest), (0, edge))
    filled.paste(right.resize((edge, inside.height), nearest), (width - edge, edge))

    corners = {
        (0, 0): (radius, edge),
        (width - radius, 0): (width - 1 - radius, edge),
        (0, height - radius): (radius, height - 1 - edge),
        (width - radius, height - radius): (
            width - 1 - radius,
            height - 1 - edge,
        ),
    }
    for (x, y), source in corners.items():
        filled.paste(window.getpixel(source), (x, y, x + radius, y + radius))

    kept = rounded_mask(window.size, radius - edge, inset=edge)

    return Image.composite(window, filled, kept)


def frame_window(capture: Image.Image, radius: int, appearance: str) -> Image.Image:
    """The window on the store canvas: clipped, bordered and with a shadow.

    Painted in layers over an opaque canvas, so the edge and the corners come from
    the masks alone and never sample the capture's own boundary pixels.
    """
    outer = rounded_mask(capture.size, radius)
    inner = rounded_mask(capture.size, radius - 1, inset=1)
    position = (
        (MAC_SIZE[0] - capture.width) // 2,
        (MAC_SIZE[1] - capture.height) // 2,
    )

    def placed(mask: Image.Image, offset: tuple[int, int] = (0, 0)) -> Image.Image:
        full = Image.new("L", MAC_SIZE, 0)
        full.paste(mask, (position[0] + offset[0], position[1] + offset[1]))
        return full

    canvas = Image.new("RGB", MAC_SIZE, MAC_BACKGROUND)

    shadow = placed(
        outer.point(lambda value: round(value * MAC_SHADOW_OPACITY)), MAC_SHADOW_OFFSET
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(MAC_SHADOW_BLUR))
    canvas = Image.composite(Image.new("RGB", MAC_SIZE, (0, 0, 0)), canvas, shadow)

    border = Image.new("RGB", MAC_SIZE, MAC_BORDER[appearance])
    canvas = Image.composite(border, canvas, placed(outer))

    window = Image.new("RGB", MAC_SIZE)
    window.paste(repainted_edge(capture.convert("RGB"), radius), position)
    return Image.composite(window, canvas, placed(inner))


def prepare_macos(directory: Path) -> None:
    if directory.name not in MAC_CORNER_RADIUS:
        raise RuntimeError(f"No window corner radius is known for macOS {directory.name}")

    for path in screenshots(directory):
        with Image.open(path) as image:
            if image.size == MAC_SIZE:
                write_rgb(path, image)
                continue

            if image.width > MAC_SIZE[0] or image.height > MAC_SIZE[1]:
                relative = path.relative_to(REPO_ROOT)
                raise RuntimeError(f"{relative} does not fit on a {MAC_SIZE} canvas")

            screen, appearance = path.stem.rsplit("-", 1)
            window = "main" if screen in MAIN_WINDOW_SCREENS else "settings"
            radius = MAC_CORNER_RADIUS[directory.name][window]
            write_rgb(path, frame_window(image, radius, appearance))


def prepare_android(directory: Path) -> None:
    for path in screenshots(directory):
        with Image.open(path) as image:
            if image.size != ANDROID_SIZE:
                relative = path.relative_to(REPO_ROOT)
                raise RuntimeError(f"{relative} has unsupported dimensions {image.size}")

            write_rgb(path, image)


def main() -> None:
    prepare_ios(REPO_ROOT / "swift/apple/screenshots/ios/iphone", IPHONE_SIZES)
    prepare_ios(REPO_ROOT / "swift/apple/screenshots/ios/ipad", IPAD_SIZES)

    macos_root = REPO_ROOT / "swift/apple/screenshots/macos"
    macos_directories = sorted(path for path in macos_root.iterdir() if path.is_dir())
    if not macos_directories:
        raise RuntimeError("No macOS screenshot directories found")

    for directory in macos_directories:
        prepare_macos(directory)

    prepare_android(REPO_ROOT / "kotlin/android/screenshots")


if __name__ == "__main__":
    main()
