#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Put back re-rendered screenshots that no one could tell apart.

Several things move pixels without anything having changed. Antialiased text does
not round a subpixel the same way twice. A control drawn on a material composites
at one of two levels a few steps apart. And the compositor draws a window's edge,
and the corner arcs of the menus and highlights inside it, against whatever lies
behind them.

Nobody can see any of it, but git can, and left alone it puts a re-render commit
on every pull request that touches the clients.

A render is judged against the commit the clients built, which on a pull request
is its merge commit rather than the branch. A screen that main re-rendered after
the branch was cut looks different from the branch's copy and the same as main's,
and the branch's copy is what stays.
"""

import argparse
import subprocess
import sys
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageChops

# A difference nobody can see is thin: a channel that rounds the other way, or a
# corner arc drawn a shade differently. A difference worth keeping covers whole
# glyphs and whole controls. Averaging over a block tells the two apart where the
# largest step in the picture cannot: two pixels on a menu's corner reach 15 steps
# while the menu is untouched, and a date that really changed reaches 246 across
# an area no larger.
#
# Over every re-render this gallery has produced, a block of invisible wobble
# averages at most 2 and the smallest real change averages 8.
BLOCK = 8
BLOCK_TOLERANCE = 4


def committed(revision: str, path: str) -> bytes | None:
    """The file as `revision` has it, or None for one that it does not carry."""
    result = subprocess.run(
        ["git", "show", f"{revision}:{path}"], capture_output=True, check=False
    )

    return result.stdout if result.returncode == 0 else None


def looks_the_same(path: str, before: bytes) -> bool:
    """Whether the re-render at `path` is one nobody could tell from `before`."""
    with Image.open(BytesIO(before)) as old, Image.open(path) as new:
        if old.size != new.size:
            return False

        difference = ImageChops.difference(old.convert("RGB"), new.convert("RGB"))
        red, green, blue = difference.split()
        # Per pixel the channel that moved furthest, then the mean of each block.
        worst = ImageChops.lighter(ImageChops.lighter(red, green), blue)
        blocks = worst.resize(
            (max(1, worst.width // BLOCK), max(1, worst.height // BLOCK)),
            Image.Resampling.BOX,
        )

    return blocks.getextrema()[1] <= BLOCK_TOLERANCE


def listed(*arguments: str) -> list[str]:
    """The paths a git command prints, one per line."""
    return subprocess.run(
        ["git", *arguments], capture_output=True, text=True, check=True
    ).stdout.split()


def main(baseline: str, directories: list[str]) -> int:
    # A screen that main added after the branch was cut arrives as a file HEAD
    # does not track, and would otherwise be committed as the branch's own.
    changed = listed("diff", "--name-only", "--", *directories) + listed(
        "ls-files", "--others", "--exclude-standard", "--", *directories
    )

    restored = []
    for path in changed:
        if not path.endswith(".png"):
            continue

        before = committed(baseline, path)
        if before is None or not looks_the_same(path, before):
            continue

        ours = committed("HEAD", path)
        if ours is None:
            Path(path).unlink()
        else:
            Path(path).write_bytes(ours)
        restored.append(path)

    for path in restored:
        print(f"Unchanged to the eye, kept as committed: {path}")

    print(f"{len(restored)} of {len(changed)} re-rendered images were put back.")

    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--baseline",
        default="HEAD",
        help="the commit whose pictures a render is judged against",
    )
    parser.add_argument("directories", nargs="+")
    arguments = parser.parse_args()

    sys.exit(main(arguments.baseline, arguments.directories))
