"""生成 iOS AppIcon 全套 PNG（1024 主图 + 各尺寸），放进 Assets.xcassets。
设计：深色渐变底 + 三个源色圆点（绿/橙/红 = 北京/淘宝/京东）+ 等宽大字时间 + 琥珀色毫秒
"""
import json
import os

from PIL import Image, ImageDraw, ImageFont

OUT = r"C:\Users\Administrator\Documents\deepseek-harness\default-workspace\timefloat\ios\TimeFloat\Assets.xcassets"
MASTER = 1024

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\consolab.ttf",   # Consolas Bold（等宽，和 App 里一致）
    r"C:\Windows\Fonts\courbd.ttf",
    r"C:\Windows\Fonts\arialbd.ttf",
]


def load_font(size):
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def make_master():
    img = Image.new("RGB", (MASTER, MASTER), (10, 12, 16))
    d = ImageDraw.Draw(img)

    # 1) 垂直渐变底：偏蓝的深灰 → 近黑
    top = (0x1E, 0x25, 0x31)
    bot = (0x0A, 0x0C, 0x10)
    for y in range(MASTER):
        t = y / (MASTER - 1)
        d.line([(0, y), (MASTER, y)],
               fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))

    # 2) 三个源色圆点（绿=北京 / 橙=淘宝 / 红=京东）
    colors = [(0x34, 0xC7, 0x59), (0xFF, 0x6A, 0x00), (0xE1, 0x25, 0x1B)]
    cy, rad, gap = 262, 44, 164
    cx = MASTER // 2
    for i, c in enumerate(colors):
        x = cx + (i - 1) * gap
        d.ellipse([x - rad, cy - rad, x + rad, cy + rad], fill=c)

    # 3) 等宽大字时间（自动缩放到不超过 800px 宽）
    txt = "18:11"
    size = 300
    f_big = load_font(size)
    while True:
        bbox = d.textbbox((0, 0), txt, font=f_big)
        w = bbox[2] - bbox[0]
        if w <= 820 or size <= 120:
            break
        size -= 10
        f_big = load_font(size)

    x = (MASTER - w) // 2 - bbox[0]
    y = 452 - bbox[1]
    d.text((x, y), txt, font=f_big, fill=(0xFF, 0xFF, 0xFF))
    bottom = y + bbox[1] + (bbox[3] - bbox[1])

    # 4) 琥珀色毫秒（强调"毫秒级"）
    f_ms = load_font(132)
    ms = ".312"
    b2 = d.textbbox((0, 0), ms, font=f_ms)
    w2 = b2[2] - b2[0]
    x2 = (MASTER - w2) // 2 - b2[0]
    y2 = bottom + 34 - b2[1]
    d.text((x2, y2), ms, font=f_ms, fill=(0xFF, 0xC1, 0x07))

    # 5) 底部一道细的琥珀色横线点缀
    d.rounded_rectangle([MASTER // 2 - 150, 902, MASTER // 2 + 150, 914], radius=6,
                        fill=(0xFF, 0x6A, 0x00))
    return img


def main():
    appicon = os.path.join(OUT, "AppIcon.appiconset")
    os.makedirs(appicon, exist_ok=True)

    master = make_master()
    master.save(os.path.join(appicon, "icon-1024.png"))

    # iPhone / iPad / App Store 经典全套
    specs = [
        ("iphone", "20x20", 2, 40), ("iphone", "20x20", 3, 60),
        ("iphone", "29x29", 2, 58), ("iphone", "29x29", 3, 87),
        ("iphone", "40x40", 2, 80), ("iphone", "40x40", 3, 120),
        ("iphone", "60x60", 2, 120), ("iphone", "60x60", 3, 180),
        ("ipad", "20x20", 1, 20), ("ipad", "20x20", 2, 40),
        ("ipad", "29x29", 1, 29), ("ipad", "29x29", 2, 58),
        ("ipad", "40x40", 1, 40), ("ipad", "40x40", 2, 80),
        ("ipad", "76x76", 1, 76), ("ipad", "76x76", 2, 152),
        ("ipad", "83.5x83.5", 2, 167),
        ("ios-marketing", "1024x1024", 1, 1024),
    ]

    images = []
    seen = {}
    for idiom, size, scale, px in specs:
        name = "icon-%s-%s@%dx.png" % (idiom, size.replace(".", "_"), scale)
        if px in seen:
            name = seen[px]
        else:
            master.resize((px, px), Image.LANCZOS).save(os.path.join(appicon, name))
            seen[px] = name
        images.append({"size": size, "idiom": idiom, "filename": name, "scale": "%dx" % scale})

    with open(os.path.join(appicon, "Contents.json"), "w", encoding="utf-8") as f:
        json.dump({"images": images,
                   "info": {"version": 1, "author": "xcode"}}, f, ensure_ascii=False, indent=2)

    with open(os.path.join(OUT, "Contents.json"), "w", encoding="utf-8") as f:
        json.dump({"info": {"version": 1, "author": "xcode"}}, f, ensure_ascii=False, indent=2)

    files = sorted(os.listdir(appicon))
    print("生成到:", appicon)
    print("文件数:", len(files))
    for n in files[:6]:
        print("   ", n, os.path.getsize(os.path.join(appicon, n)), "bytes")
    print("    ...")
    print("主图尺寸:", master.size, "模式:", master.mode)


if __name__ == "__main__":
    main()
