#!/usr/bin/env python3
# gen_font.py - 从 FONT16.BIN（ROM 8x16 字体 dump）生成 8x8 字体表，
#               插入 HWSCOPE.ASM 的 FONT_DATA_BEGIN/END 标记之间。
# 背景：int 10h AX=1130h 在 DOSBox 下会破坏显示状态（M1 实测），
#       故改为编译期内置字体，运行时零 BIOS 依赖。
import pathlib
import re
import sys

TESTS = pathlib.Path(__file__).resolve().parent
ROOT = TESTS.parent
SRC = ROOT / "src" / "HWSCOPE.ASM"
FONT16 = TESTS / "FONT16.BIN"  # 优先用工作区内副本
if not FONT16.exists():
    FONT16 = pathlib.Path(r"D:\cache\hwscope_run\FONT16.BIN")

NCHARS = 128  # ASCII 0-127

# 8x16 字体的字形实际占 rows 2..11（共 10 行，rows 0-1 与 12-15 为空白）。
# ⚠️ 不可直接取"上半 8 行"（rows 0-7）：字母的底横/底弧/连接全在 rows 8-11，
#    会被丢掉——屏幕上所有字母只剩上半截（O 显示成 ∩、U 显示成 ||、
#    E 与 F 因底部差异被丢而变得完全相同）。数字因形状居上曾碰巧完整，
#    导致只查"有像素"的测试数期无法发现（2026-10-23 实测教训）。
# 正解：10 行 -> 8 行最近邻重采样（round(i*9/7)+2），保住顶行与底行。
ROW_MAP = (2, 3, 5, 6, 7, 8, 10, 11)


def gen_lines(data: bytes) -> list:
    lines = ["    FONT8X8 LABEL BYTE"]
    for ch in range(NCHARS):
        row = [data[ch * 16 + r] for r in ROW_MAP]
        hexes = ",".join(f"0{b:02X}H" for b in row)
        cc = chr(ch) if 32 <= ch < 127 else " "
        lines.append(f"    DB {hexes}    ; {ch:3d} '{cc}'")
    return lines


def main() -> int:
    if not FONT16.exists():
        print(f"[gen_font] FATAL: {FONT16} 不存在，请先运行 DUMPFNT dump 字体")
        return 1
    data = FONT16.read_bytes()
    if len(data) < NCHARS * 16:
        print(f"[gen_font] FATAL: 字体文件过小: {len(data)}")
        return 1
    lines = gen_lines(data)
    text = SRC.read_text(encoding="utf-8")
    pat = re.compile(r"( *; FONT_DATA_BEGIN\n).*?( *; FONT_DATA_END\n)", re.S)
    if not pat.search(text):
        print("[gen_font] FATAL: HWSCOPE.ASM 中找不到 FONT_DATA 标记")
        return 1
    body = "\n".join(lines) + "\n"
    text = pat.sub(lambda m: m.group(1) + body + m.group(2), text, count=1)
    SRC.write_text(text, encoding="utf-8")
    print(f"[gen_font] 已插入 {NCHARS} 字符 8x8 字体表 -> {SRC}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
