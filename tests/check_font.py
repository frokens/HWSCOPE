#!/usr/bin/env python3
# check_font.py - HWSCOPE.ASM 内置 FONT8X8 字体表的结构完整性断言
#
# 背景（2026-10-23 实测 bug）：字体表曾直接切取 ROM 8x16 字体的"上半 8 行"，
#   而 8x16 字形实际占 rows 2-11——字母的底横/底弧/连接全部丢失：
#   O 显示成 ∩、U 显示成 ||、C 只剩顶弧、E 与 F 因底部差异被丢而完全同形、
#   Q=O、g=q。数字因形状居上而碰巧完整，导致只查"区域有像素 >60"和
#   "数字值正确"的屏幕断言全部通过——用户看到"文字只显示一半"。
#   本检查从源码结构上封死该 bug 类：字母底行必须有内容（字形完整）、
#   可打印字符不允许重复（除已知可接受对）、E 必须区别于 F、数字必须互异。
import pathlib
import re

# 已知可接受的重复对（8x16->8x8 重采样的低影响产物，均不在屏幕标签中）：
#   ',' 与 '.'：逗号尾部在重采样中丢失，8px 下两者均为两点，视觉可接受
#   'g' 与 'q'：小写下降沿字母，尾部丢失；屏幕标签全为大写+数字，不使用
ALLOWED_DUP_PAIRS = [frozenset({",", "."}), frozenset({"g", "q"})]


def parse_font(src_path: pathlib.Path) -> dict:
    """从 HWSCOPE.ASM 解析 FONT8X8 表 -> {ascii: (8 个字节)}"""
    text = src_path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"; FONT_DATA_BEGIN\n(.*?); FONT_DATA_END", text, re.S)
    if not m:
        return {}
    font = {}
    for line in m.group(1).splitlines():
        mm = re.match(r"\s*DB\s+(.*?)\s*;\s*(\d+)\s", line)
        if mm:
            vals = tuple(int(v.strip().rstrip("H"), 16)
                         for v in mm.group(1).split(","))
            if len(vals) == 8:
                font[int(mm.group(2))] = vals
    return font


def check_font(font: dict) -> dict:
    res = {
        "entries": len(font), "entries_ok": len(font) == 128,
        "dup_pairs": [], "dups_ok": False,
        "ef_distinct": False,
        "letters_bottom_bad": [], "letters_bottom_ok": False,
        "digits_bad": [], "digits_ok": False,
        "colon_ok": False, "dot_ok": False,
    }
    if len(font) != 128:
        return res

    # 1. 可打印字符（32-126）非空字形不得重复（白名单除外）
    groups: dict = {}
    for c in range(32, 127):
        v = font.get(c)
        if v and any(v):
            groups.setdefault(v, []).append(chr(c))
    bad_dups = []
    for chars in groups.values():
        if len(chars) > 1:
            pair = frozenset(chars)
            if pair not in ALLOWED_DUP_PAIRS:
                bad_dups.append("/".join(sorted(chars)))
    res["dup_pairs"] = bad_dups
    res["dups_ok"] = not bad_dups

    # 2. E 必须区别于 F（上半 8 行切取事故的直接症状）
    res["ef_distinct"] = font[69] != font[70]

    # 3. 26 个大写字母底行必须有内容（底横/底弧/连接存在的结构性证据）
    res["letters_bottom_bad"] = [
        chr(c) for c in range(65, 91) if font[c][7] == 0]
    res["letters_bottom_ok"] = not res["letters_bottom_bad"]

    # 4. 数字 0-9 必须互异且非空
    digits = [font[48 + i] for i in range(10)]
    res["digits_bad"] = [
        str(i) for i, v in enumerate(digits)
        if not any(v) or digits.count(v) > 1]
    res["digits_ok"] = not res["digits_bad"]

    # 5. 冒号必须有两个点行（标签 "CPU OPS/S:" 等依赖）；小数点必须非空
    colon = font[58]
    res["colon_ok"] = sum(1 for b in colon if b) >= 2
    res["dot_ok"] = any(font[46])
    return res


if __name__ == "__main__":
    import sys
    src = pathlib.Path(
        r"D:\17404\Desktop\汇编语言程序设计\src\HWSCOPE.ASM")
    if len(sys.argv) > 1:
        src = pathlib.Path(sys.argv[1])
    f = parse_font(src)
    r = check_font(f)
    for k, v in r.items():
        print(f"{k}: {v}")
    ok = (r["entries_ok"] and r["dups_ok"] and r["ef_distinct"]
          and r["letters_bottom_ok"] and r["digits_ok"]
          and r["colon_ok"] and r["dot_ok"])
    print("FONT-CHECK:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
