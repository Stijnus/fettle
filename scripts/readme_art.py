#!/usr/bin/env python3
"""Build the visual assets used by README.md.

Two kinds of output, both derived from the app itself:

  screenshots  Frame the raw --ui-preview captures in a macOS window with a
               traffic-light title bar, rounded corners and a soft shadow.
  brand        Draw the hero banner, the GitHub social preview (1280x640) and
               the logo lockups from the app icon.

Usage:
  python3 scripts/readme_art.py screenshots <raw-dir> <out-dir>
  python3 scripts/readme_art.py brand <icon.png> <out-dir>

The raw captures come from `scripts/capture_screenshots.sh`, which drives the
hidden --ui-preview mode. Nothing here touches the app bundle.
"""

from __future__ import annotations

import math
import os
import sys
from dataclasses import dataclass

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# ---------------------------------------------------------------- palette ---
MIDNIGHT = (7, 31, 29)
DEEP_TEAL = (12, 59, 55)
TEAL = (31, 181, 154)
MINT = (91, 232, 176)
INK = (14, 27, 26)
WHITE = (255, 255, 255)
WARM_PAPER = (246, 245, 243)

SF = "/System/Library/Fonts/SFNS.ttf"
SF_ROUNDED = "/System/Library/Fonts/SFNSRounded.ttf"


def font(size: int, weight: str = "Regular", rounded: bool = False) -> ImageFont.FreeTypeFont:
    path = SF_ROUNDED if rounded else SF
    face = ImageFont.truetype(path, size)
    try:
        face.set_variation_by_name(weight)
    except Exception:
        pass
    return face


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def shadow_for(size: tuple[int, int], radius: int, blur: int, offset: tuple[int, int], alpha: int) -> Image.Image:
    """A blurred silhouette used as the window's drop shadow."""
    pad = blur * 3
    canvas = Image.new("L", (size[0] + pad * 2, size[1] + pad * 2), 0)
    layer = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(layer).rounded_rectangle(
        [pad + offset[0], pad + offset[1], pad + offset[0] + size[0], pad + offset[1] + size[1]],
        radius=radius,
        fill=alpha,
    )
    canvas = layer.filter(ImageFilter.GaussianBlur(blur))
    return canvas, pad


@dataclass
class WindowSpec:
    name: str
    source: str
    title: str | None = "Fettle"
    width: int = 1600
    titlebar: bool = True
    crop_bottom: int | None = None
    radius_pt: float = 10.0
    titlebar_pt: float = 28.0
    menu_popover: bool = False
    sidebar: bool = True


WINDOWS: list[WindowSpec] = [
    WindowSpec("overview", "overview.png", None, 1760, crop_bottom=1408),
    WindowSpec("mac-health", "mac-health.png", "Fettle"),
    WindowSpec("cpu", "cpu.png", "Fettle"),
    WindowSpec("memory", "memory.png", "Fettle"),
    WindowSpec("disk-health", "disk-health.png", "Fettle"),
    WindowSpec("battery", "battery.png", "Fettle"),
    WindowSpec("network", "network.png", "Fettle"),
    WindowSpec("activity", "activity.png", "Fettle"),
    WindowSpec("disk-cleanup", "disk-cleanup.png", "Fettle"),
    WindowSpec("maintenance", "maintenance.png", "Fettle"),
    WindowSpec("uninstaller", "uninstaller.png", "Fettle"),
    WindowSpec("app-updater", "app-updater.png", "Fettle"),
    WindowSpec("app-updater-review", "app-updater-review.png", None, 1200, titlebar=False, radius_pt=8, sidebar=False),
    WindowSpec("extensions", "extensions.png", "Fettle"),
    WindowSpec("login-items", "login-items.png", "Fettle"),
    WindowSpec("privacy", "privacy.png", "Fettle"),
    WindowSpec("sleep-power", "sleep-power.png", "Fettle"),
    WindowSpec("security", "security.png", "Fettle"),
    WindowSpec("permanent-delete", "permanent-delete.png", "Fettle"),
    WindowSpec("settings", "settings.png", "Settings", 1200, sidebar=False),
    WindowSpec("menu-bar", "menu-bar.png", None, 520, titlebar=False, menu_popover=True, sidebar=False),
]


def frame_window(spec: WindowSpec, raw_dir: str, out_dir: str) -> None:
    content = Image.open(os.path.join(raw_dir, spec.source)).convert("RGB")
    if spec.crop_bottom:
        content = content.crop((0, 0, content.width, min(spec.crop_bottom, content.height)))

    points_w = content.width / 2.0
    scale = spec.width / points_w
    target = (spec.width, round(content.height * spec.width / content.width))
    content = content.resize(target, Image.LANCZOS)

    radius = round(spec.radius_pt * scale)
    title_h = round(spec.titlebar_pt * scale) if spec.titlebar else 0
    total = (target[0], target[1] + title_h)

    window = Image.new("RGBA", total, (0, 0, 0, 0))
    draw = ImageDraw.Draw(window)

    sidebar_w = 0
    if spec.titlebar and spec.sidebar:
        # Follow the app's full-height sidebar into the title bar.
        probe_y = max(2, content.height // 40)
        for x in range(1, content.width // 2):
            if abs(sum(content.getpixel((x, probe_y))) - sum(content.getpixel((0, probe_y)))) > 90:
                sidebar_w = round(x * total[0] / content.width)
                break
        sidebar_fill = content.getpixel((4, probe_y)) + (255,)
        ribbon_fill = content.getpixel((min(content.width - 4, sidebar_w + 120) if sidebar_w else content.width // 4, probe_y)) + (255,)
        draw.rectangle([0, 0, sidebar_w, title_h], fill=sidebar_fill)
        draw.rectangle([sidebar_w, 0, total[0], title_h], fill=ribbon_fill)
        draw.line([(sidebar_w, 0), (sidebar_w, title_h)], fill=(0, 0, 0, 26), width=max(1, round(scale)))
        draw.line([(sidebar_w, title_h), (total[0], title_h)], fill=(0, 0, 0, 20), width=1)

    if spec.titlebar:
        if not sidebar_w:
            draw.rectangle([0, 0, total[0], title_h], fill=WARM_PAPER + (255,))
            draw.line([(0, title_h), (total[0], title_h)], fill=(0, 0, 0, 22), width=1)
        radius_light = round(6 * scale)
        gap = round(8 * scale)
        cx = round(20 * scale) + radius_light
        cy = title_h // 2
        for i, color in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            x = cx + i * (radius_light * 2 + gap)
            draw.ellipse([x - radius_light, cy - radius_light, x + radius_light, cy + radius_light], fill=color + (255,))
            draw.ellipse(
                [x - radius_light, cy - radius_light, x + radius_light, cy + radius_light],
                outline=(0, 0, 0, 26),
                width=max(1, round(scale)),
            )
        if spec.title and not sidebar_w:
            title_font = font(round(13 * scale), "Semibold")
            bbox = draw.textbbox((0, 0), spec.title, font=title_font)
            draw.text(
                ((total[0] - (bbox[2] - bbox[0])) / 2, (title_h - (bbox[3] - bbox[1])) / 2 - bbox[1]),
                spec.title,
                font=title_font,
                fill=(70, 70, 70, 235),
            )

    window.paste(content, (0, title_h))

    mask = rounded_mask(total, radius)
    window.putalpha(mask)

    # Hairline border so the window edge stays visible on white.
    if not spec.menu_popover:
        border = Image.new("RGBA", total, (0, 0, 0, 0))
        ImageDraw.Draw(border).rounded_rectangle(
            [0, 0, total[0] - 1, total[1] - 1], radius=radius, outline=(0, 0, 0, 30), width=max(1, round(scale))
        )
        window = Image.alpha_composite(window, Image.composite(border, Image.new("RGBA", total, (0, 0, 0, 0)), mask))

    blur = max(6, round(16 * scale / 2))
    shadow, pad = shadow_for(total, radius, blur, (0, round(10 * scale)), 90 if not spec.menu_popover else 70)

    canvas = Image.new("RGBA", (total[0] + pad * 2, total[1] + pad * 2), (0, 0, 0, 0))
    shadow_rgba = Image.new("RGBA", canvas.size, (10, 25, 23, 0))
    shadow_rgba.putalpha(shadow)
    canvas = Image.alpha_composite(canvas, shadow_rgba)
    canvas.paste(window, (pad, pad), window)

    canvas.save(os.path.join(out_dir, f"{spec.name}.webp"), "WEBP", quality=90, method=6)
    print(f"  {spec.name}.webp  {canvas.width}x{canvas.height}")


# ------------------------------------------------------------------ brand ---
def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    w, h = size
    grad = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        grad.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return grad.resize((w, h), Image.BILINEAR)


def teal_canvas(size: tuple[int, int]) -> Image.Image:
    w, h = size
    base = vertical_gradient(size, (6, 27, 25), (13, 62, 56)).convert("RGBA")

    glow = Image.new("L", size, 0)
    ImageDraw.Draw(glow).ellipse(
        [round(w * 0.45), -round(h * 0.55), round(w * 1.25), round(h * 1.15)], fill=110
    )
    glow = glow.filter(ImageFilter.GaussianBlur(round(h * 0.12)))
    tint = Image.new("RGBA", size, (64, 224, 186, 255))
    base = Image.alpha_composite(base, Image.composite(tint, Image.new("RGBA", size, (0, 0, 0, 0)), glow))

    # Faint dotted grid, like a technical drawing.
    dots = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(dots)
    step = max(18, round(h / 26))
    for y in range(step, h, step):
        for x in range(step, w, step):
            d.ellipse([x - 1, y - 1, x + 1, y + 1], fill=(255, 255, 255, 18))
    return Image.alpha_composite(base, dots)


def paste_icon(canvas: Image.Image, icon_path: str, box: tuple[int, int, int, int]) -> None:
    icon = Image.open(icon_path).convert("RGBA")
    icon = icon.resize((box[2], box[3]), Image.LANCZOS)
    glow = Image.new("RGBA", (box[2] * 2, box[3] * 2), (0, 0, 0, 0))
    silhouette = rounded_mask((box[2], box[3]), round(box[2] * 0.22))
    shadow = Image.new("RGBA", glow.size, (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (box[2], box[3]), (2, 40, 36, 170)), (box[2] // 2, box[3] // 2), silhouette)
    shadow = shadow.filter(ImageFilter.GaussianBlur(round(box[2] * 0.10)))
    canvas.alpha_composite(shadow, (box[0] - box[2] // 2, box[1] - box[3] // 4))
    canvas.alpha_composite(icon, (box[0], box[1]))


def chips(canvas: Image.Image, items: list[str], origin: tuple[int, int], size: int, gap: int = 18) -> int:
    """Glass pills drawn on their own layer, then composited so alpha blends."""
    f = font(size, "Medium")
    x, y = origin
    pad_x, pad_y = round(size * 0.7), round(size * 0.4)
    h = size + pad_y * 2
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for text in items:
        bbox = d.textbbox((0, 0), text, font=f)
        w = bbox[2] - bbox[0] + pad_x * 2
        d.rounded_rectangle([x, y, x + w, y + h], radius=h // 2, fill=(255, 255, 255, 34), outline=(255, 255, 255, 84), width=2)
        d.text((x + pad_x, y + pad_y - bbox[1]), text, font=f, fill=(222, 246, 240, 255))
        x += w + gap
    canvas.alpha_composite(layer)
    return x


def make_logo(icon_path: str, out_dir: str) -> None:
    for suffix, word_fill in [("", INK + (255,)), ("-white", WHITE + (255,))]:
        icon_size = 220
        word = font(150, "Semibold")
        draw = ImageDraw.Draw(Image.new("RGBA", (10, 10)))
        bbox = draw.textbbox((0, 0), "Fettle", font=word)
        w = icon_size + round(icon_size * 0.26) + (bbox[2] - bbox[0])
        h = icon_size
        canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        canvas.alpha_composite(Image.open(icon_path).convert("RGBA").resize((icon_size, icon_size), Image.LANCZOS), (0, 0))
        d = ImageDraw.Draw(canvas)
        d.text(
            (icon_size + round(icon_size * 0.26), (h - (bbox[3] - bbox[1])) / 2 - bbox[1] - round(icon_size * 0.02)),
            "Fettle",
            font=word,
            fill=word_fill,
        )
        canvas.save(os.path.join(out_dir, f"logo{suffix}.png"), optimize=True)
        print(f"  logo{suffix}.png  {canvas.width}x{canvas.height}")


def make_social(icon_path: str, out_dir: str) -> None:
    W, H = 1280, 640
    canvas = teal_canvas((W, H))
    paste_icon(canvas, icon_path, (84, 152, 168, 168))

    d = ImageDraw.Draw(canvas)
    d.text((286, 150), "Fettle", font=font(136, "Bold"), fill=WHITE + (255,))
    d.text((292, 316), "Care for your Mac, calmly.", font=font(46, "Medium"), fill=(184, 236, 225, 255))
    d.text(
        (292, 392),
        "Cleanup · Uninstaller · App updates · Privacy · Live Mac Health",
        font=font(27, "Regular"),
        fill=(150, 209, 196, 255),
    )
    chips(canvas, ["Local-first", "Apple silicon", "macOS 14+"], (292, 462), 24)
    d.text((84, 560), "github.com/Stijnus/fettle", font=font(26, "Medium"), fill=(150, 209, 196, 255))

    canvas.convert("RGB").save(os.path.join(out_dir, "social-preview.png"), optimize=True)
    print(f"  social-preview.png  {W}x{H}")


def make_hero(icon_path: str, overview_path: str, out_dir: str) -> None:
    W, H = 2000, 760
    canvas = teal_canvas((W, H))

    paste_icon(canvas, icon_path, (120, 132, 148, 148))
    d = ImageDraw.Draw(canvas)
    d.text((112, 306), "Fettle", font=font(128, "Bold"), fill=WHITE + (255,))
    d.text((118, 462), "Care for your Mac, calmly.", font=font(50, "Medium"), fill=(190, 240, 229, 255))
    chips(canvas, ["Local-first", "Read-only scans", "Apple silicon"], (118, 556), 26)

    window = Image.open(overview_path).convert("RGBA")
    target_h = 640
    scale = target_h / window.height
    window = window.resize((round(window.width * scale), target_h), Image.LANCZOS)

    # Let the window bleed off the right edge.
    x = 1040
    y = 80
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    glow.paste(Image.new("RGBA", window.size, (3, 44, 40, 190)), (x + 10, y + 26), window.split()[-1])
    glow = glow.filter(ImageFilter.GaussianBlur(40))
    canvas = Image.alpha_composite(canvas, glow)
    canvas.alpha_composite(window, (x, y))

    canvas.convert("RGB").save(os.path.join(out_dir, "hero.png"), optimize=True)
    print(f"  hero.png  {W}x{H}")


def main() -> None:
    if len(sys.argv) < 4:
        print(__doc__)
        raise SystemExit(2)
    mode, src, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out_dir, exist_ok=True)

    if mode == "screenshots":
        for spec in WINDOWS:
            path = os.path.join(src, spec.source)
            if not os.path.exists(path):
                print(f"  skip {spec.name}: {spec.source} missing")
                continue
            frame_window(spec, src, out_dir)
    elif mode == "brand":
        icon = src
        make_logo(icon, out_dir)
        make_social(icon, out_dir)
        shots = sys.argv[4] if len(sys.argv) > 4 else os.path.join(out_dir, "screenshots")
        hero_source = os.path.join(shots, "overview.webp")
        if os.path.exists(hero_source):
            make_hero(icon, hero_source, out_dir)
        else:
            print("  skip hero: frame overview.webp first")
    else:
        print(f"unknown mode {mode}")
        raise SystemExit(2)


if __name__ == "__main__":
    main()
