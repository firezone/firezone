"""TEMPORARY: prints a PNG as text so a CI log can show what was rendered."""

import struct
import sys
import zlib

data = open(sys.argv[1], "rb").read()
position, pixels, palette = 8, b"", b""

while position < len(data):
    length, name = struct.unpack(">I4s", data[position:position + 8])
    chunk = data[position + 8:position + 8 + length]
    if name == b"IHDR":
        width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
    elif name == b"PLTE":
        palette = chunk
    elif name == b"IDAT":
        pixels += chunk
    position += 12 + length

if depth != 8 or interlace != 0:
    sys.exit(f"cannot sketch a {depth}-bit, interlace {interlace} image")

channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
stride = width * channels
raw = zlib.decompress(pixels)
rows, previous, at = [], bytearray(stride), 0

for _ in range(height):
    kind, at = raw[at], at + 1
    row, at = bytearray(raw[at:at + stride]), at + stride
    for x in range(stride):
        left = row[x - channels] if x >= channels else 0
        up = previous[x]
        corner = previous[x - channels] if x >= channels else 0
        if kind == 1:
            row[x] = (row[x] + left) & 255
        elif kind == 2:
            row[x] = (row[x] + up) & 255
        elif kind == 3:
            row[x] = (row[x] + ((left + up) >> 1)) & 255
        elif kind == 4:
            guess = left + up - corner
            distances = abs(guess - left), abs(guess - up), abs(guess - corner)
            nearest = left if distances[0] <= min(distances[1:]) else (
                up if distances[1] <= distances[2] else corner)
            row[x] = (row[x] + nearest) & 255
    rows.append(row)
    previous = row


def grey(row, x):
    start = x * channels
    if colour == 3:
        entry = row[start] * 3
        return sum(palette[entry:entry + 3]) // 3
    if colour in (0, 4):
        return row[start]
    return sum(row[start:start + 3]) // 3


ramp = " .:-=+*#%@"
# Two rows per line, because a character cell is about twice as tall as it is wide.
for y in range(0, height, 2):
    print("".join(ramp[(255 - grey(rows[y], x)) * len(ramp) // 256] for x in range(width)))
