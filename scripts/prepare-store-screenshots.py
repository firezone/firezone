#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Turn the clients' screenshot galleries into store-ready PNGs."""

from io import BytesIO
from pathlib import Path

from PIL import Image

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


def prepare_macos(directory: Path) -> None:
    for path in screenshots(directory):
        with Image.open(path) as image:
            if image.size == MAC_SIZE:
                write_rgb(path, image)
                continue

            if image.width > MAC_SIZE[0] or image.height > MAC_SIZE[1]:
                relative = path.relative_to(REPO_ROOT)
                raise RuntimeError(f"{relative} does not fit on a {MAC_SIZE} canvas")

            canvas = Image.new("RGB", MAC_SIZE, MAC_BACKGROUND)
            foreground = image.convert("RGBA")
            position = (
                (MAC_SIZE[0] - foreground.width) // 2,
                (MAC_SIZE[1] - foreground.height) // 2,
            )
            canvas.paste(foreground, position, foreground)
            write_rgb(path, canvas)


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
