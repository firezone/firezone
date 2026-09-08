#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow"]
# ///
"""Turn the clients' screenshot galleries into store-ready PNGs."""

import struct
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

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
# The menus' own corner radius, measured from the captures.
MENU_CORNER_RADIUS = 12
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


# Rows per deflate block. A block boundary is where a change stops rippling.
ROWS_PER_BLOCK = 16


def png_chunk(kind: bytes, data: bytes) -> bytes:
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


def write_rgb(path: Path, image: Image.Image) -> None:
    """Write `image` as an RGB PNG whose deflate stream is byte-aligned every few rows.

    A deflate block is not byte-aligned, so with an ordinary encoder one changed row
    shifts every bit after it and the whole file differs. Flushing the stream every
    `ROWS_PER_BLOCK` rows keeps a change local to its block, which is what lets git
    store a re-render as a small delta against the previous one.
    """
    pixels = np.asarray(image.convert("RGB"), dtype=np.uint8)
    height, width, _ = pixels.shape
    # PNG filter type 1 (Sub): each byte minus the byte one pixel to its left.
    left = np.concatenate([np.zeros((height, 1, 3), np.uint8), pixels[:, :-1]], axis=1)
    filtered = (pixels - left).reshape(height, width * 3)
    scanlines = np.concatenate([np.full((height, 1), 1, np.uint8), filtered], axis=1)

    compressor = zlib.compressobj(9)
    stream = bytearray()
    for row in range(0, height, ROWS_PER_BLOCK):
        stream += compressor.compress(scanlines[row : row + ROWS_PER_BLOCK].tobytes())
        stream += compressor.flush(zlib.Z_SYNC_FLUSH)
    stream += compressor.flush(zlib.Z_FINISH)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", bytes(stream))
        + png_chunk(b"IEND", b"")
    )


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


def framed(
    shape: Image.Image,
    panels: list[tuple[Image.Image, Image.Image, Image.Image]],
    appearance: str,
) -> Image.Image:
    """The `panels` on the store canvas, bordered, with one shadow under `shape`.

    Each panel is a picture with the masks that clip it: the border comes from the
    outer one and the panel itself from the inner, so an edge and a corner never
    sample the capture's own boundary pixels. One shadow rather than one each,
    because a panel standing over another does not cast onto it.
    """
    canvas = Image.new("RGB", MAC_SIZE, MAC_BACKGROUND)

    shadow = Image.new("L", MAC_SIZE, 0)
    shadow.paste(
        shape.point(lambda value: round(value * MAC_SHADOW_OPACITY)), MAC_SHADOW_OFFSET
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(MAC_SHADOW_BLUR))
    canvas = Image.composite(Image.new("RGB", MAC_SIZE, (0, 0, 0)), canvas, shadow)

    border = Image.new("RGB", MAC_SIZE, MAC_BORDER[appearance])

    for content, outer, inner in panels:
        canvas = Image.composite(border, canvas, outer)
        canvas = Image.composite(content, canvas, inner)

    return canvas


def placed(mask: Image.Image, at: tuple[int, int]) -> Image.Image:
    """`mask` on a canvas-sized one, at `at`."""
    full = Image.new("L", MAC_SIZE, 0)
    full.paste(mask, at)

    return full


def centred(size: tuple[int, int]) -> tuple[int, int]:
    return ((MAC_SIZE[0] - size[0]) // 2, (MAC_SIZE[1] - size[1]) // 2)


def panel(
    capture: Image.Image, at: tuple[int, int], radius: int
) -> tuple[Image.Image, Image.Image, Image.Image]:
    """`capture` placed at `at`, with the masks that clip it to a rounded rectangle."""
    content = Image.new("RGB", MAC_SIZE)
    content.paste(repainted_edge(capture.convert("RGB"), radius), at)

    return (
        content,
        placed(rounded_mask(capture.size, radius), at),
        placed(rounded_mask(capture.size, radius - 1, inset=1), at),
    )


def frame_window(capture: Image.Image, radius: int, appearance: str) -> Image.Image:
    """The window on the store canvas: clipped, bordered and with a shadow."""
    window = panel(capture, centred(capture.size), radius)

    return framed(window[1], [window], appearance)


def frame_menus(capture: Image.Image, appearance: str) -> Image.Image:
    """The menus on the store canvas, clipped, bordered and with a shadow.

    The capture holds the panels where they stood on the screen, so the picture keeps
    how they meet: the one in front covers the border of the one behind it.
    """
    origin = centred(capture.size)
    panels = [
        panel(capture.crop(box), (origin[0] + box[0], origin[1] + box[1]), MENU_CORNER_RADIUS)
        for box in menus(capture)
    ]
    shape = panels[0][1]

    for _, outer, _ in panels[1:]:
        shape = ImageChops.lighter(shape, outer)

    return framed(shape, panels, appearance)


def menus(capture: Image.Image) -> list[tuple[int, int, int, int]]:
    """The rectangle each menu covers, left to right.

    A menu's extent only changes across its corners, and by at most their radius, so
    a bigger change is where one menu ends and the next begins. One that ends where
    the next begins is standing behind it and reaches under it, far enough that its
    corners do too.
    """
    drawn = np.asarray(capture.convert("RGBA"))[:, :, 3] > 0
    boxes: list[tuple[int, int, int, int]] = []

    for x, column in enumerate(drawn.T):
        rows = np.flatnonzero(column)
        if not rows.size:
            continue

        top, bottom = int(rows[0]), int(rows[-1]) + 1
        last = boxes[-1] if boxes else None

        if (
            last
            and abs(top - last[1]) <= MENU_CORNER_RADIUS
            and abs(bottom - last[3]) <= MENU_CORNER_RADIUS
        ):
            boxes[-1] = (last[0], min(last[1], top), x + 1, max(last[3], bottom))
        else:
            if last and last[2] == x:
                boxes[-1] = (last[0], last[1], x + MENU_CORNER_RADIUS, last[3])

            boxes.append((x, top, x + 1, bottom))

    if not boxes:
        raise RuntimeError("A menu capture holds no menus")

    return boxes


def prepare_macos(directory: Path) -> None:
    if directory.name not in MAC_CORNER_RADIUS:
        raise RuntimeError(f"No window corner radius is known for macOS {directory.name}")

    for path in screenshots(directory):
        with Image.open(path) as image:
            screen, appearance = path.stem.rsplit("-", 1)

            if screen == "menu":
                write_rgb(path, frame_menus(image, appearance))
                continue

            if image.size == MAC_SIZE:
                write_rgb(path, image)
                continue

            if image.width > MAC_SIZE[0] or image.height > MAC_SIZE[1]:
                relative = path.relative_to(REPO_ROOT)
                raise RuntimeError(f"{relative} does not fit on a {MAC_SIZE} canvas")

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
