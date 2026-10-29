"""生成 App 图标：蓝色圆角方块 + 白色取景框 + 中间的选区。
用法: python3 scripts/make_icon.py  → Resources/AppIcon.png (1024) 与 AppIcon.icns
"""
from pathlib import Path
from PIL import Image, ImageDraw

SS = 4                      # 超采样倍数，最后缩小抗锯齿
S = 1024 * SS
OUT = Path(__file__).resolve().parent.parent / "Resources"


def u(v):
    return int(v * SS)


def gradient(size, top, bottom):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS 风格的圆角底板（1024 画布中留 100 边距）
    x0, x1 = u(100), u(924)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([x0, x0, x1, x1], radius=u(185), fill=255)
    img.paste(gradient((S, S), (88, 160, 255), (40, 92, 230)), (0, 0), mask)

    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)

    # 取景框的四个角
    a, b, L, W = u(260), u(764), u(130), u(44)
    for (cx, cy, sx, sy) in [(a, a, 1, 1), (b, a, -1, 1), (a, b, 1, -1), (b, b, -1, -1)]:
        d.rounded_rectangle(sorted_box(cx, cy, cx + sx * L, cy + sy * W), radius=W // 2, fill=white)
        d.rounded_rectangle(sorted_box(cx, cy, cx + sx * W, cy + sy * L), radius=W // 2, fill=white)

    # 中间的选区
    d.rounded_rectangle([u(380), u(400), u(644), u(624)], radius=u(24), fill=white)

    out = img.resize((1024, 1024), Image.LANCZOS)
    OUT.mkdir(parents=True, exist_ok=True)
    out.save(OUT / "AppIcon.png")
    out.save(OUT / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("已生成", OUT / "AppIcon.png", OUT / "AppIcon.icns")


def sorted_box(x0, y0, x1, y1):
    return [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]


if __name__ == "__main__":
    main()
