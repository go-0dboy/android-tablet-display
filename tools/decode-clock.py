#!/usr/bin/env python3
"""
Decode the latencyclock block row from a screenshot of the tablet.

The clock draws a leading white marker block followed by 22 bits as black or
white blocks. This finds the row, reads the bits, and prints the encoded
millisecond value. Comparing that against the time the screenshot was taken
gives end-to-end latency without anyone having to read digits off an image.

    ./tools/decode-clock.py shot.png [--taken-at-ms 1234567890123]

Needs Pillow:  python3 -m pip install --user Pillow
"""
import sys
import argparse

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required:  python3 -m pip install --user Pillow")

BIT_COUNT = 22


def decode(path):
    """Return the encoded value, or None if the clock is not visible."""
    image = Image.open(path).convert("L")
    width, height = image.size
    pixels = image.load()

    # Scan for the block row rather than assuming where it landed: the client
    # may letterbox, scale, or crop the stream, and the row's position moves
    # with it. Two scan lines must agree before a value is accepted, which
    # rules out a stray white rectangle in the desktop wallpaper.
    previous = None
    for y in range(2, height - 2, max(1, height // 400)):
        value = decode_row(pixels, width, y)
        if value is None:
            previous = None
            continue
        if previous is not None and previous == value:
            return value
        previous = value
    return None


def decode_row(pixels, width, y):
    block_width = width / (BIT_COUNT + 2)

    def sample(index):
        """Average the middle of block `index` to shrug off codec ringing."""
        start = int(block_width * index + block_width * 0.3)
        end = int(block_width * index + block_width * 0.7)
        if end <= start or end > width:
            return None
        total = sum(pixels[x, y] for x in range(start, end))
        return total / (end - start)

    marker = sample(0)
    if marker is None or marker < 140:
        # No white marker block here: this is not the clock row.
        return None

    value = 0
    for bit in range(BIT_COUNT):
        level = sample(bit + 1)
        if level is None:
            return None
        value = (value << 1) | (1 if level > 128 else 0)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--taken-at-ms", type=int,
                        help="wall-clock ms when the screenshot was taken")
    args = parser.parse_args()

    value = decode(args.image)
    if value is None:
        print("clock not found in the image")
        return 1

    print(f"encoded={value}")
    if args.taken_at_ms is not None:
        wrapped = args.taken_at_ms & ((1 << BIT_COUNT) - 1)
        span = 1 << BIT_COUNT
        delta = (wrapped - value) % span
        # The counter wraps, so a frame drawn slightly *after* the reference
        # time comes back as a huge positive number. Fold the top half of the
        # range to negative, which is what it actually means.
        if delta > span // 2:
            delta -= span
        print(f"latency_ms={delta}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
