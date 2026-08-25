#!/usr/bin/env python3
"""Put back re-rendered screenshots that no one could tell apart.

Text is drawn with antialiasing, and the machine that draws it does not always
round a subpixel the same way twice, so a re-render can differ from what is
committed by a single value in a channel. Nobody can see that, but git can, and
left alone it puts a re-render commit on every pull request that touches the
clients. An image whose every pixel is within `TOLERANCE` of the committed one
is treated as the same image and restored.
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops

# One step of a channel. Two is already visible on a flat background.
TOLERANCE = 1


def committed(path: str) -> bytes | None:
    """The file as HEAD has it, or None for one that HEAD does not carry."""
    result = subprocess.run(
        ["git", "show", f"HEAD:{path}"], capture_output=True, check=False
    )

    return result.stdout if result.returncode == 0 else None


def within_tolerance(path: str, before: bytes) -> bool:
    from io import BytesIO

    with Image.open(BytesIO(before)) as old, Image.open(path) as new:
        if old.size != new.size:
            return False

        difference = ImageChops.difference(old.convert("RGB"), new.convert("RGB"))
        extremes = difference.getextrema()

    return all(high <= TOLERANCE for _, high in extremes)


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
        if before is None or not within_tolerance(path, before):
            continue

        Path(path).write_bytes(before)
        restored.append(path)

    for path in restored:
        print(f"Unchanged to the eye, kept as committed: {path}")

    print(f"{len(restored)} of {len(changed)} re-rendered images were put back.")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
