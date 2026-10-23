#!/usr/bin/env python3
# dump2png.py - 把 HWV 转储的 A000 显存（64000 字节，320x200x256）
# 渲染成 PNG。无头模式下它就是"截图"：不弹 DOSBox 窗口也能核对屏幕。
# 调色板：VGA 默认 256 色（0-15 为 EGA 16 色，程序实际只用这些）
import pathlib
import sys

W, H = 320, 200
SCALE = 3  # 放大倍数（最近邻，便于肉眼核对）


def vga_palette() -> list:
    pal = []
    ega = [
        (0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170),
        (170, 0, 0), (170, 0, 170), (170, 85, 0), (170, 170, 170),
        (85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255),
        (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255),
    ]
    pal.extend(ega)
    # 16-31：灰度 ramp
    for i in range(16):
        v = i * 17
        pal.append((v, v, v))
    # 32-247：6x6x6 色彩立方（每级 0/51/102/153/204/255）
    levels = (0, 51, 102, 153, 204, 255)
    for r in levels:
        for g in levels:
            for b in levels:
                pal.append((r, g, b))
    # 248-255：黑
    for _ in range(8):
        pal.append((0, 0, 0))
    return pal[:256]


def render(dump: pathlib.Path, png: pathlib.Path) -> bool:
    from PIL import Image
    if not dump.exists():
        return False
    data = dump.read_bytes()
    if len(data) != W * H:
        return False
    pal = vga_palette()
    img = Image.new("RGB", (W, H))
    px = img.load()
    for i, b in enumerate(data):
        x, y = i % W, i // W
        px[x, y] = pal[b]
    if SCALE != 1:
        img = img.resize((W * SCALE, H * SCALE), Image.NEAREST)
    img.save(str(png))
    return True


if __name__ == "__main__":
    src = pathlib.Path(sys.argv[1])
    dst = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".png")
    ok = render(src, dst)
    print(f"[dump2png] {src} -> {dst} {'ok' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)
