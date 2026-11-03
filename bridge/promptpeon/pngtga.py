"""Turning a PNG into a TGA the game can read, with nothing but the standard library. The PNG is untrusted."""
from __future__ import annotations

import struct
import zlib

from . import settings


class ImageError(Exception):
    """A plain reason an image can't be previewed."""


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def decode_png(data: bytes) -> tuple[int, int, int, list]:
    """Read a PNG with the standard library: width, height, colour type, rows of channels.

    Untrusted input. The size is checked before anything is unpacked, and unpacking stops at
    what the header promised, so a tiny file can't expand into all of memory.
    """
    if data[:8] != PNG_SIGNATURE:
        raise ImageError("not a PNG")
    position, chunks, header, palette, alpha = 8, [], None, None, None
    while position + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[position:position + 8])
        chunk = data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", chunk[:13])
        elif kind == b"PLTE":
            palette = chunk
        elif kind == b"tRNS":
            alpha = chunk
        elif kind == b"IDAT":
            chunks.append(chunk)
        elif kind == b"IEND":
            break
    if header is None:
        raise ImageError("a broken PNG")
    width, height, depth, colour, _, _, interlace = header
    if width == 0 or height == 0 or width * height > settings.MAX_IMAGE_PIXELS:
        raise ImageError("too big to preview")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None or interlace or depth not in (8, 16) or (colour == 3 and depth != 8):
        raise ImageError("an unusual PNG format")
    step = channels * depth // 8
    stride = width * step
    expected = (stride + 1) * height
    try:
        raw = zlib.decompressobj().decompress(b"".join(chunks), expected + 1)
    except zlib.error as error:
        raise ImageError("a broken PNG") from error
    if len(raw) != expected:
        raise ImageError("a broken PNG")
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(step, stride):
                line[i] = (line[i] + line[i - step]) & 255
        elif kind == 2:
            line = bytearray((a + b) & 255 for a, b in zip(line, previous))
        elif kind == 3:
            for i in range(stride):
                left = line[i - step] if i >= step else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 255
        elif kind == 4:
            for i in range(stride):
                a = line[i - step] if i >= step else 0
                b = previous[i]
                c = previous[i - step] if i >= step else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif kind != 0:
            raise ImageError("a broken PNG")
        rows.append(line)
        previous = line
    return width, height, colour, _png_pixels(rows, width, colour, depth, step, palette, alpha)


def _png_pixels(rows, width, colour, depth, step, palette, alpha):
    """A function giving (r, g, b, a) at a pixel, whatever the PNG's colour type."""
    wide = depth == 16
    def pixel(x: int, y: int) -> tuple[int, int, int, int]:
        line, at = rows[y], x * step
        if colour == 6:
            if wide:
                return line[at], line[at + 2], line[at + 4], line[at + 6]
            return line[at], line[at + 1], line[at + 2], line[at + 3]
        if colour == 2:
            if wide:
                return line[at], line[at + 2], line[at + 4], 255
            return line[at], line[at + 1], line[at + 2], 255
        if colour == 3:
            index = line[at]
            if not palette or index * 3 + 2 >= len(palette):
                return 0, 0, 0, 255
            opacity = alpha[index] if alpha and index < len(alpha) else 255
            return palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2], opacity
        if colour == 4:
            grey, opacity = line[at], line[at + (2 if wide else 1)]
            return grey, grey, grey, opacity
        return line[at], line[at], line[at], 255
    return pixel


def png_to_tga(data: bytes, max_side: int = settings.PREVIEW_MAX_SIDE) -> tuple[bytes, int, int]:
    """A PNG as an uncompressed TGA the game can read, no larger than max_side."""
    width, height, _, pixel = decode_png(data)
    scale = min(1.0, max_side / max(width, height))
    out_width, out_height = max(1, round(width * scale)), max(1, round(height * scale))
    head = bytearray(18)
    head[2] = 2
    head[12:14] = struct.pack("<H", out_width)
    head[14:16] = struct.pack("<H", out_height)
    head[16], head[17] = 32, 8
    body = bytearray(out_width * out_height * 4)
    position = 0
    # TGA rows run bottom to top. Four samples per pixel keeps small text readable.
    for out_y in range(out_height - 1, -1, -1):
        y1 = min(height - 1, int((out_y + 0.25) * height / out_height))
        y2 = min(height - 1, int((out_y + 0.75) * height / out_height))
        for out_x in range(out_width):
            x1 = min(width - 1, int((out_x + 0.25) * width / out_width))
            x2 = min(width - 1, int((out_x + 0.75) * width / out_width))
            a, b, c, d = pixel(x1, y1), pixel(x2, y1), pixel(x1, y2), pixel(x2, y2)
            body[position] = (a[2] + b[2] + c[2] + d[2]) >> 2
            body[position + 1] = (a[1] + b[1] + c[1] + d[1]) >> 2
            body[position + 2] = (a[0] + b[0] + c[0] + d[0]) >> 2
            body[position + 3] = (a[3] + b[3] + c[3] + d[3]) >> 2
            position += 4
    return bytes(head) + bytes(body), out_width, out_height


def blank_tga() -> bytes:
    head = bytearray(18)
    head[2] = 2
    head[12:14] = struct.pack("<H", 8)
    head[14:16] = struct.pack("<H", 8)
    head[16], head[17] = 32, 8
    return bytes(head) + bytes(8 * 8 * 4)
