import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Resources/Assets.xcassets"
DOCS = ROOT / "docs"
NAME = "PIXELMIRROR"
SIGNATURE = "REFFWU"
FONT_PATH = "/System/Library/Fonts/Optima.ttc"
FONT_SIZE = 46
TRACKING = 16
SIZE = 2048
SCALE = 2
INNER = (176, 176, 1872, 1872)
INNER_RADIUS = 392
FRAME = 132
OUTER = (INNER[0] - FRAME, INNER[1] - FRAME, INNER[2] + FRAME, INNER[3] + FRAME)
OUTER_RADIUS = INNER_RADIUS + FRAME
FRAMES = {
    "dark": ((26, 26, 28), (128, 128, 134, 255), 60),
}
POINTS = [16, 32, 128, 256, 512]
BACKGROUND = ((86, 214, 182), (20, 150, 152))


def blank():
    return Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))


def polygon_mask(points):
    mask = Image.new("L", (SIZE * SCALE, SIZE * SCALE), 0)
    ImageDraw.Draw(mask).polygon([(x * SCALE, y * SCALE) for x, y in points], fill=255)
    return mask.resize((SIZE, SIZE), Image.LANCZOS)


def rounded_mask(box, radius):
    mask = Image.new("L", (SIZE * SCALE, SIZE * SCALE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [value * SCALE for value in box], radius=radius * SCALE, fill=255
    )
    return mask.resize((SIZE, SIZE), Image.LANCZOS)


def rounded(points, radii, steps=12):
    result = []
    for index, corner in enumerate(points):
        corner = np.array(corner, float)
        before = np.array(points[index - 1], float) - corner
        after = np.array(points[(index + 1) % len(points)], float) - corner
        reach = min(radii[index], np.linalg.norm(before) / 2, np.linalg.norm(after) / 2)
        start = corner + before / np.linalg.norm(before) * reach
        end = corner + after / np.linalg.norm(after) * reach
        for t in np.linspace(0, 1, steps):
            point = (1 - t) ** 2 * start + 2 * (1 - t) * t * corner + t**2 * end
            result.append(tuple(point))
    return result


def fill(source, mask):
    if isinstance(source, tuple):
        source = Image.new("RGBA", (SIZE, SIZE), source)
    layer = blank()
    layer.paste(source.convert("RGBA"), (0, 0), mask)
    return layer


def vertical_gradient(top, bottom, start, end):
    ramp = np.linspace(0, 1, end - start)[:, None]
    rows = np.array(top) * (1 - ramp) + np.array(bottom) * ramp
    strip = np.repeat(rows[:, None, :], SIZE, axis=1).astype(np.uint8)
    image = Image.new("RGB", (SIZE, SIZE), tuple(top))
    image.paste(Image.fromarray(strip), (0, start))
    return image


def face():
    """Two phones, one behind the other: the real one and its frosted-glass twin on the Mac."""
    canvas = vertical_gradient(BACKGROUND[0], BACKGROUND[1], INNER[1], INNER[3]).convert("RGBA")
    back = (625, 420, 1217, 1420)
    front = (830, 628, 1422, 1628)
    radius = 92

    # Soft shadows lift both phones off the background.
    for box, alpha, blur in ((back, 70, 36), (front, 90, 44)):
        shadow = fill((0, 40, 48, alpha), rounded_mask(box, radius)).filter(ImageFilter.GaussianBlur(blur))
        canvas = Image.alpha_composite(canvas, shadow.transform((SIZE, SIZE), Image.AFFINE, (1, 0, 0, 0, 1, -22)))

    # The phone itself: solid, deep, no detail.
    canvas = Image.alpha_composite(
        canvas, fill(vertical_gradient((6, 112, 124), (2, 62, 92), back[1], back[3]), rounded_mask(back, radius)))

    # Its mirror image: tinted glass that lets the phone behind show through.
    glass = vertical_gradient((178, 255, 232), (58, 226, 214), front[1], front[3]).convert("RGBA")
    glass.putalpha(165)
    canvas = Image.alpha_composite(canvas, fill(glass, rounded_mask(front, radius)))
    rim = blank()
    ImageDraw.Draw(rim).rounded_rectangle(front, radius=radius, outline=(214, 255, 244, 210), width=6)
    canvas = Image.alpha_composite(canvas, rim)

    # What makes it Android: a punch-hole camera and a thin gesture bar.
    marks = blank()
    draw = ImageDraw.Draw(marks)
    cx = (front[0] + front[2]) // 2
    draw.ellipse((cx - 19, front[1] + 46, cx + 19, front[1] + 84), fill=(6, 70, 80, 230))
    draw.rounded_rectangle((cx - 96, front[3] - 54, cx + 96, front[3] - 40), radius=7, fill=(226, 255, 248, 235))
    return Image.alpha_composite(canvas, marks)


def ring_point(distance, box, radius):
    x0, y0, x1, y1 = box
    width, height = x1 - x0 - 2 * radius, y1 - y0 - 2 * radius
    arc = math.pi * radius / 2
    segments = [
        ("line", (x0 + radius + width / 2, y0), (x1 - radius, y0), width / 2),
        ("arc", (x1 - radius, y0 + radius), -90, 0, arc),
        ("line", (x1, y0 + radius), (x1, y1 - radius), height),
        ("arc", (x1 - radius, y1 - radius), 0, 90, arc),
        ("line", (x1 - radius, y1), (x0 + radius, y1), width),
        ("arc", (x0 + radius, y1 - radius), 90, 180, arc),
        ("line", (x0, y1 - radius), (x0, y0 + radius), height),
        ("arc", (x0 + radius, y0 + radius), 180, 270, arc),
        ("line", (x0 + radius, y0), (x0 + radius + width / 2, y0), width / 2),
    ]
    distance %= sum(segment[-1] for segment in segments)
    for segment in segments:
        if distance <= segment[-1]:
            share = distance / segment[-1]
            if segment[0] == "line":
                (ax, ay), (bx, by) = segment[1], segment[2]
                angle = math.degrees(math.atan2(by - ay, bx - ax))
                return ax + (bx - ax) * share, ay + (by - ay) * share, angle
            (cx, cy), start, end = segment[1], segment[2], segment[3]
            angle = math.radians(start + (end - start) * share)
            x, y = cx + radius * math.cos(angle), cy + radius * math.sin(angle)
            return x, y, math.degrees(angle) + 90
        distance -= segment[-1]
    raise ValueError("distance outside the frame")


def engrave(canvas, text, position, color, upright):
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE * SCALE)
    inset = FRAME / 2
    box = (OUTER[0] + inset, OUTER[1] + inset, OUTER[2] - inset, OUTER[3] - inset)
    radius = (OUTER_RADIUS + INNER_RADIUS) / 2
    perimeter = (
        2 * (box[2] - box[0] - 2 * radius)
        + 2 * (box[3] - box[1] - 2 * radius)
        + 2 * math.pi * radius
    )
    widths = [font.getlength(letter) / SCALE for letter in text]
    total = sum(widths) + TRACKING * (len(text) - 1)
    direction = -1 if upright else 1
    cursor = position * perimeter - direction * total / 2
    layer = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
    for letter, width in zip(text, widths):
        x, y, angle = ring_point(cursor + direction * width / 2, box, radius)
        if upright:
            angle += 180
        side = FONT_SIZE * 2 * SCALE
        glyph = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        ImageDraw.Draw(glyph).text(
            (side / 2, side / 2), letter, font=font, fill=color, anchor="mm"
        )
        glyph = glyph.rotate(-angle, resample=Image.BICUBIC)
        layer.alpha_composite(
            glyph, (int(x * SCALE - side / 2), int(y * SCALE - side / 2))
        )
        cursor += direction * (width + TRACKING)
    return Image.alpha_composite(canvas, layer.resize((SIZE, SIZE), Image.LANCZOS))


def framed(content, style):
    frame_color, text_color, rim_alpha = FRAMES[style]
    outer = rounded_mask(OUTER, OUTER_RADIUS)
    canvas = fill((*frame_color, 255), outer)
    canvas = Image.alpha_composite(
        canvas, fill(content, rounded_mask(INNER, INNER_RADIUS))
    )
    rim = blank()
    ImageDraw.Draw(rim).rounded_rectangle(
        INNER, radius=INNER_RADIUS, outline=(255, 255, 255, rim_alpha), width=4
    )
    canvas = Image.alpha_composite(canvas, rim)
    canvas = engrave(canvas, NAME, 0.875, text_color, False)
    canvas = engrave(canvas, SIGNATURE, 0.375, text_color, True)
    shadow = fill((0, 0, 0, 85), outer).filter(ImageFilter.GaussianBlur(42))
    shadow = shadow.transform((SIZE, SIZE), Image.AFFINE, (1, 0, 0, 0, 1, -20))
    return Image.alpha_composite(shadow, canvas)


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def main():
    content = face()
    icons = {style: framed(content, style) for style in FRAMES}
    info = {"author": "xcode", "version": 1}
    appicon = ASSETS / "AppIcon.appiconset"
    appicon.mkdir(parents=True, exist_ok=True)
    images = []
    for point in POINTS:
        for scale in (1, 2):
            name = f"icon_{point}x{point}{'@2x' if scale == 2 else ''}.png"
            pixels = point * scale
            icons["dark"].resize((pixels, pixels), Image.LANCZOS).save(appicon / name)
            images.append(
                {
                    "filename": name,
                    "idiom": "mac",
                    "scale": f"{scale}x",
                    "size": f"{point}x{point}",
                }
            )
    write_json(appicon / "Contents.json", {"images": images, "info": info})
    DOCS.mkdir(exist_ok=True)
    icons["dark"].resize((512, 512), Image.LANCZOS).save(DOCS / "icon.png")


if __name__ == "__main__":
    main()
