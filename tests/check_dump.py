#!/usr/bin/env python3
# check_dump.py - DUMP.BIN（A000 显存转储，64000 字节）字节断言
import pathlib

# 屏幕标签的预期文本（x, y, 期望字符串）——端到端文本渲染断言用：
# 用字体表反向解码屏幕单元格，逐字符比对。这能抓住"字形损坏"类 bug
# （如 2026-10-23 的 F 渲染成 E——只查"区域有像素"的断言发现不了）
# M7r 新布局（2026-10-23 排版重构）：3x2 双列，行 y=78/94/110
SCREEN_TEXTS = [
    (20, 44, "HWSCOPE"),
    (20, 78, "CPU OPS/S:"),
    (170, 78, "FPU FLOPS:"),
    (20, 94, "MEM KB:"),
    (170, 94, "RAM BW:"),
    (20, 110, "VRAM BW:"),
    (170, 110, "DISK KB/S:"),
    (20, 132, "ESC=EXIT ANY KEY=REMEASURE"),
    (20, 153, "RAM"),
    (20, 161, "VRAM"),
]


def decode_texts(data: bytes, font: dict) -> list:
    """用字体表把屏幕标签行解码成字符串（单元格与字体条目精确匹配）"""
    out = []
    for x0, y, expected in SCREEN_TEXTS:
        chars = []
        for i in range(len(expected)):
            vals = tuple(
                sum(1 << (7 - b) for b in range(8)
                    if data[(y + r) * 320 + x0 + i * 8 + b])
                for r in range(8))
            if not any(vals):
                chars.append(" ")
                continue
            hit = [c for c, fv in font.items() if fv == vals]
            chars.append(chr(hit[0]) if hit else "?")
        out.append((x0, y, expected, "".join(chars)))
    return out


def check_dump(path: pathlib.Path, font: dict = None) -> dict:
    res = {
        "size": 0, "size_ok": False,
        "nonzero": 0, "nonzero_ok": False,
        "has_bars": False, "colors_found": [],
        "white_px": 0, "yellow_px": 0,
        "text_ok": False, "num_ok": False,
        "text_zone_nz": 0, "num_zone_nz": 0,
        "text_zone_ok": False, "num_zone_ok": False,
        "cpu_zone_nz": 0, "cpu_zone_ok": False,
        "fpu_zone_nz": 0, "fpu_zone_ok": False,
        "disk_zone_nz": 0, "disk_zone_ok": False,
        "mem_zone_nz": 0, "mem_zone_ok": False,
        "rambw_zone_nz": 0, "rambw_zone_ok": False,
        "vrambw_zone_nz": 0, "vrambw_zone_ok": False,
        "ram_bar_end": -1, "ram_bar_ok": False,
        "vram_bar_end": -1, "vram_bar_ok": False,
        "frame_px": 0, "frame_ok": False,
        "status_zone_nz": 0, "status_zone_ok": False,
        "demo_leftover": -1, "demo_erased_ok": False,
        "screen_text_bad": [], "screen_text_ok": None,
    }
    if not path.exists():
        return res
    data = path.read_bytes()
    res["size"] = len(data)
    res["size_ok"] = len(data) == 64000

    colors: dict = {}
    for b in data:
        colors[b] = colors.get(b, 0) + 1

    nonzero = sum(c for v, c in colors.items() if v != 0)
    res["nonzero"] = nonzero
    # 阈值按 M7r 排版标定：细条 1728 + 边框 906 + 双迷你条 ~630 + 全部
    # 文本与数值（白/黄/浅灰字形）合计约 6400；空白屏约 0，取 5000 分隔
    res["nonzero_ok"] = nonzero > 5000

    # M0 测试图案：三条彩色细条（M7r 起 96x6 并排，每色 576 像素）
    found = [c for c in (10, 11, 12) if colors.get(c, 0) > 400]
    res["colors_found"] = found
    res["has_bars"] = len(found) == 3

    # M1：白色文本 "HWSCOPE" + 黄色 32 位数字 4294967295
    res["white_px"] = colors.get(15, 0)
    res["yellow_px"] = colors.get(14, 0)
    res["text_ok"] = res["white_px"] > 100
    res["num_ok"] = res["yellow_px"] > 100

    def zone_nonzero(y0, y1, x0, x1):
        n = 0
        for y in range(y0, y1):
            base = y * 320
            for x in range(x0, x1):
                if data[base + x] != 0:
                    n += 1
        return n

    def bar_end(y0, y1, color, x0=20, x1=319):
        # 条带区域内该颜色最后出现的 x（端点）；不存在返回 -1
        end = -1
        for y in range(y0, y1):
            base = y * 320
            for x in range(x1 - 1, x0 - 1, -1):
                if data[base + x] == color:
                    if x > end:
                        end = x
                    break
        return end

    # 屏幕布局（8px 行高，M7r 排版重构）：M1 y=44/58，
    # 指标行 y=78/94/110（左列标签 x=20 数值 x=104，右列标签 x=170 数值 x=254），
    # 状态行 y=132，迷你条 y=154/162（高 5），边框 y=32..178
    res["text_zone_nz"] = zone_nonzero(44, 52, 20, 104)
    res["num_zone_nz"] = zone_nonzero(58, 66, 20, 104)
    res["text_zone_ok"] = res["text_zone_nz"] > 60
    res["num_zone_ok"] = res["num_zone_nz"] > 60

    # M2：CPU 基准值区域（y=78..86, x=104..160）
    res["cpu_zone_nz"] = zone_nonzero(78, 86, 104, 160)
    res["cpu_zone_ok"] = res["cpu_zone_nz"] > 60

    # M4：FPU 基准值区域（y=78..86, x=254..320）
    res["fpu_zone_nz"] = zone_nonzero(78, 86, 254, 320)
    res["fpu_zone_ok"] = res["fpu_zone_nz"] > 60

    # M5：磁盘读吞吐值区域（y=110..118, x=254..320）
    res["disk_zone_nz"] = zone_nonzero(110, 118, 254, 320)
    res["disk_zone_ok"] = res["disk_zone_nz"] > 60

    # M3：三行数值区域（左列 x=104..160；RAM 值在右列 x=254..320）
    res["mem_zone_nz"] = zone_nonzero(94, 102, 104, 160)
    res["mem_zone_ok"] = res["mem_zone_nz"] > 60
    res["rambw_zone_nz"] = zone_nonzero(94, 102, 254, 320)
    res["rambw_zone_ok"] = res["rambw_zone_nz"] > 60
    res["vrambw_zone_nz"] = zone_nonzero(110, 118, 104, 160)
    res["vrambw_zone_ok"] = res["vrambw_zone_nz"] > 60

    # M3：迷你条端点（RAM y=154..158 色9；VRAM y=162..166 色13）
    # 端点存在性在此验证；"与数值成比例"由 run_tests.py 结合 hwv.log 值断言
    res["ram_bar_end"] = bar_end(154, 159, 9)
    res["ram_bar_ok"] = res["ram_bar_end"] >= 20
    res["vram_bar_end"] = bar_end(162, 167, 13)
    res["vram_bar_ok"] = res["vram_bar_end"] >= 20

    # M6：仪表盘边框（色 8 深灰 1px 矩形：上下 2x303 + 左右 2x85 = 776px）
    res["frame_px"] = colors.get(8, 0)
    res["frame_ok"] = res["frame_px"] > 500

    # M6：状态行（y=132, x=20 起，浅灰 7，26 字符 208px 宽）
    res["status_zone_nz"] = zone_nonzero(132, 140, 20, 240)
    res["status_zone_ok"] = res["status_zone_nz"] > 60

    # M6：演示高亮擦除校验——六个 '>' 亮黄(14) 8x8 区在转储时应全黑
    # （DEMO_HIGHLIGHT 用 FILLRECT 涂黑擦除；空格字形无像素画不出擦除）
    # M7r 新布局：左列 x=8，右列 x=158，行 y=78/94/110
    demo_zones = [(78, 86, 8, 16), (78, 86, 158, 166),
                  (94, 102, 8, 16), (94, 102, 158, 166),
                  (110, 118, 8, 16), (110, 118, 158, 166)]
    res["demo_leftover"] = sum(
        1 for (y0, y1, x0, x1) in demo_zones
        for y in range(y0, y1) for x in range(x0, x1)
        if data[y * 320 + x] == 14)
    res["demo_erased_ok"] = res["demo_leftover"] == 0

    # 屏幕标签端到端断言（需传入字体表）：逐字符解码比对，
    # 抓住"字形损坏/缺半截/字符渲染错"类 bug（F 变 E 即属此类）
    if font:
        decoded = decode_texts(data, font)
        res["screen_text_bad"] = [
            f"({x},{y}) expect={e!r} got={g!r}"
            for (x, y, e, g) in decoded if e != g]
        res["screen_text_ok"] = not res["screen_text_bad"]
    return res


if __name__ == "__main__":
    import sys
    print(check_dump(pathlib.Path(sys.argv[1])))
