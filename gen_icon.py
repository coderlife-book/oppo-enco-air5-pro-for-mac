#!/usr/bin/env python3
"""生成 EncoBattery 的图标（EncoBattery.icns）。

深色圆角方块 + 一对白色耳机，纯几何绘制，不依赖 SF Symbols。
需要 Pillow：python3 -m pip install pillow
用法：python3 gen_icon.py
"""

import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 1024 * 4  # 先在 4 倍尺寸上画，最后缩下来当抗锯齿
HERE = Path(__file__).resolve().parent

BG_TOP = (62, 74, 92)
BG_BOTTOM = (22, 26, 34)
EARBUD = (255, 255, 255)


def squircle_mask(size: int, radius_ratio: float = 0.2237) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * radius_ratio)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return mask


def vertical_gradient(size: int, top, bottom) -> Image.Image:
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        grad.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return grad.resize((size, size), Image.BILINEAR)


def earbud_layer(px: int, angle: float, flip: bool) -> Image.Image:
    """一只耳机：椭圆耳塞 + 向下的柄。px 是画布尺寸。"""
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    cx = px / 2
    head_cy = px * 0.36
    head_rx = px * 0.152
    head_ry = px * 0.182
    stem_top = head_cy + head_ry * 0.42
    stem_bottom = px * 0.845
    stem_x = cx + (px * 0.05 if flip else -px * 0.05)
    w_top = px * 0.125
    w_bot = px * 0.092

    # 柄：上粗下细的圆头柱
    d.polygon(
        [
            (stem_x - w_top / 2, stem_top),
            (stem_x + w_top / 2, stem_top),
            (stem_x + w_bot / 2, stem_bottom - w_bot / 2),
            (stem_x - w_bot / 2, stem_bottom - w_bot / 2),
        ],
        fill=EARBUD,
    )
    d.ellipse(
        [stem_x - w_bot / 2, stem_bottom - w_bot, stem_x + w_bot / 2, stem_bottom],
        fill=EARBUD,
    )
    # 耳塞主体
    d.ellipse(
        [cx - head_rx, head_cy - head_ry, cx + head_rx, head_cy + head_ry],
        fill=EARBUD,
    )
    # 出声口的浅色凹陷：给耳朵一个视觉焦点（不要纯白大色块）
    notch_r = px * 0.066
    notch_x = cx + (-px * 0.06 if flip else px * 0.06)
    notch_y = head_cy - px * 0.025
    d.ellipse(
        [notch_x - notch_r, notch_y - notch_r * 0.8, notch_x + notch_r, notch_y + notch_r * 0.8],
        fill=(88, 98, 116, 60),
    )
    return layer.rotate(angle, resample=Image.BICUBIC, center=(cx, head_cy))


def build(size: int = S) -> Image.Image:
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    body = vertical_gradient(size, BG_TOP, BG_BOTTOM).convert("RGBA")

    # 顶部一层柔光，避免大色块死板
    glow = Image.new("L", (size, size), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-size * 0.25, -size * 0.55, size * 1.25, size * 0.55], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.06))
    body = Image.composite(Image.new("RGBA", (size, size), (255, 255, 255, 60)), body, glow)

    icon.paste(body, (0, 0), squircle_mask(size))

    # 两只耳机，一左一右微外八
    bud_px = int(size * 0.62)
    left = earbud_layer(bud_px, angle=8, flip=False)
    right = earbud_layer(bud_px, angle=-8, flip=True)
    y = int(size * 0.19)
    icon.alpha_composite(left, (int(size * 0.035), y))
    icon.alpha_composite(right, (int(size * 0.345), y))

    # 内描边，让边缘和浅色背景分开一点
    stroke = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stroke)
    inset = max(2, int(size * 0.006))
    sd.rounded_rectangle(
        [inset, inset, size - inset, size - inset],
        radius=int(size * 0.2237) - inset,
        outline=(255, 255, 255, 26),
        width=max(2, int(size * 0.004)),
    )
    icon.alpha_composite(stroke)
    return icon


def main() -> None:
    master = build()
    iconset = HERE / "EncoBattery.iconset"
    iconset.mkdir(exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            px = base * scale
            img = master.resize((px, px), Image.LANCZOS)
            img.save(iconset / f"icon_{base}x{base}{suffix}.png")

    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(HERE / "EncoBattery.icns")],
        check=True,
    )
    master.resize((512, 512), Image.LANCZOS).save(HERE / "screenshots" / "icon.png")
    print("wrote EncoBattery.icns")


if __name__ == "__main__":
    main()
