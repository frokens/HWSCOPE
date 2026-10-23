#!/usr/bin/env python3
# gen_conf.py - 生成 DOSBox 自动化测试环境（扁平化版）
# 策略：
#   1. 纯 ASCII 路径 D:\cache\hwscope_run 规避中文挂载问题（风险 R11）
#   2. 扁平结构：运行根直接放 ASM/BAT，去掉 _tmp_extract 长目录名
#      （DOS shell 对 >8 字符长目录名 cd 不稳定，见 M0 调试记录）
#   3. autoexec 只留 mount + CALL RUNALL.BAT，全部逻辑进 BAT
#      （autoexec 多行链存在竞态，cd 后命令可能丢失）
#   4. 无头模式（默认）：conf 不带窗口相关输出设置，配合 SDL_VIDEODRIVER=
#      dummy 全程不弹窗；屏幕内容靠 DUMP.BIN -> PNG（dump2png.py）核对
# 用法：gen_conf.py [--window]   （--window 才弹窗，供人工查看仪表盘）
# 产出：
#   D:\cache\hwscope_run\   - 运行根（RUNALL.BAT + 四 ASM + src/ + logs/）
#   D:\cache\hwscope_run\test.conf
#   tests/env.json - 主机侧路径信息
import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"
RUN = pathlib.Path(r"D:\cache\hwscope_run")
MASM_TOOLS = pathlib.Path(r"D:\masm-tools")

HEADLESS = "--window" not in sys.argv


def copy_tree() -> None:
    if RUN.exists():
        shutil.rmtree(RUN)
    RUN.mkdir(parents=True)
    # 主源码（提交版）
    shutil.copy2(ROOT / "src" / "HWSCOPE.ASM", RUN / "HWSCOPE.ASM")
    # 变体源码（mkvariants 已生成）
    for name in ("HWV.ASM", "HWD.ASM"):
        shutil.copy2(ROOT / "_tmp_extract" / name, RUN / name)
    # 冒烟加载器（INT 16H 钩 + EXEC，无头驱动提交版交互主循环）
    shutil.copy2(TESTS / "KEYHOOK.ASM", RUN / "KEYHOOK.ASM")
    # DOS 侧批处理（LF -> CRLF：DOSBox COMMAND 解析 LF-only BAT 会错乱）
    bat = (TESTS / "RUNALL.BAT").read_bytes()
    bat = bat.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    (RUN / "RUNALL.BAT").write_bytes(bat)


def write_conf() -> None:
    conf = RUN / "test.conf"
    lines = [
        "[sdl]",
    ]
    if HEADLESS:
        # 无头：不开窗口、不指定输出后端（由 SDL_VIDEODRIVER=dummy 决定）
        pass
    else:
        lines += ["output=opengl", "windowresolution=1024x640"]
    lines += [
        "",
        "[dosbox]",
        "memsize=16",
        "",
        "[cpu]",
        "core=normal",
        "cycles=auto",
        "",
        "[autoexec]",
        f"mount c {MASM_TOOLS}",
        f"mount d {RUN}",
        "call d:\\runall.bat",
        "exit",
        "",
    ]
    conf.write_text("\n".join(lines), encoding="ascii")
    print(f"[gen_conf] conf={conf} headless={HEADLESS}")


def write_env() -> None:
    env = {
        "mode": "flat",
        "headless": HEADLESS,
        "run_root": str(RUN),
        "src_dir": str(RUN / "src"),
        "logs_dir": str(RUN / "logs"),
    }
    (TESTS / "env.json").write_text(
        json.dumps(env, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[gen_conf] run_root={RUN}")


if __name__ == "__main__":
    copy_tree()
    write_conf()
    write_env()
