#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Put back re-rendered screenshots that no one could tell apart.

Two things move pixels without anything having changed. Antialiased text does not
round a subpixel the same way twice, so a channel moves by one wherever text is
drawn. And a control drawn on a material composites at one of two levels a few
steps apart, uniformly across the whole of itself: iOS 26 draws the navigation
bar's back button that way, and it settles on either 35 or 38 in the dark
appearance. macOS composites the window title against the titlebar's material
the same way, a further 13 steps apart.

Nobody can see either, but git can, and left alone they put a re-render commit on
every pull request that touches the clients.
"""

import subprocess
import sys
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageChops

# One step of a channel. Two is already visible on a flat background.
EDGE_TOLERANCE = 1

# What a material's two levels span, and how much of the picture one control
# drawn on it covers. The back button measures 5 steps across 0.42% of the
# screen and the macOS window title 13 steps across 0.19%, so both leave room
# without reaching a change worth seeing.
PATCH_TOLERANCE = 14
PATCH_FRACTION = 0.01


def committed(path: str) -> bytes | None:
    """The file as HEAD has it, or None for one that HEAD does not carry."""
    result = subprocess.run(
        ["git", "show", f"HEAD:{path}"], capture_output=True, check=False
    )

    return result.stdout if result.returncode == 0 else None


def looks_the_same(path: str, before: bytes) -> bool:
    """Whether the re-render at `path` is one nobody could tell from `before`."""
    with Image.open(BytesIO(before)) as old, Image.open(path) as new:
        if old.size != new.size:
            return False

        difference = ImageChops.difference(old.convert("RGB"), new.convert("RGB"))
        pixels = difference.width * difference.height
        red, green, blue = difference.split()
        # Per pixel, the channel that moved furthest. `getextrema` reports each
        # channel over the whole picture, which cannot say how much of it moved.
        worst = ImageChops.lighter(ImageChops.lighter(red, green), blue)
        counts = worst.histogram()

    steps = max((value for value, count in enumerate(counts) if count), default=0)
    moved = sum(counts[1:])

    if steps <= EDGE_TOLERANCE:
        return True

    return steps <= PATCH_TOLERANCE and moved <= PATCH_FRACTION * pixels


def main(directories: list[str]) -> int:
    changed = subprocess.run(
        ["git", "diff", "--name-only", "--", *directories],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()

    restored = []
    for path in changed:
        if not path.endswith(".png"):
            continue

        before = committed(path)
        if before is None or not looks_the_same(path, before):
            continue

        Path(path).write_bytes(before)
        restored.append(path)

    for path in restored:
        print(f"Unchanged to the eye, kept as committed: {path}")

    print(f"{len(restored)} of {len(changed)} re-rendered images were put back.")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
