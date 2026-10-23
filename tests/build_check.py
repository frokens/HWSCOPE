#!/usr/bin/env python3
# build_check.py - 无头快速构建检查：只汇编+链接三变体，不运行
# 用法：D:\Python313\python.exe build_check.py
import pathlib
import re
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"
RUN = pathlib.Path(r"D:\cache\hwscope_build")
MASM_TOOLS = pathlib.Path(r"D:\masm-tools")
DOSBOX = pathlib.Path(r"D:\dosbox\DOSBox.exe")

# 1. 生成变体
r = subprocess.run([sys.executable, str(TESTS / "mkvariants.py")],
                   capture_output=True, text=True, errors="replace")
print(r.stdout.strip())
if r.returncode != 0:
    print(r.stderr)
    sys.exit("mkvariants FAILED")

# 2. 布置运行目录（与 gen_conf 扁平结构一致）
if RUN.exists():
    shutil.rmtree(RUN)
RUN.mkdir(parents=True)
for name in ("HWSCOPE.ASM", "HWV.ASM", "HWD.ASM"):
    src = (ROOT / "src" / name) if name == "HWSCOPE.ASM" else (ROOT / "_tmp_extract" / name)
    shutil.copy2(src, RUN / name)

bat_lines = [
    "@echo off",
    "d:",
    "path=%path%;c:\\",
    "if not exist src\\nul md src",
    "copy HWSCOPE.ASM src\\HWSCOPE.ASM >nul",
    "copy HWV.ASM src\\HWV.ASM >nul",
    "copy HWD.ASM src\\HWD.ASM >nul",
    "cd src",
    "masm HWSCOPE; > b_s.log",
    "link HWSCOPE; >> b_s.log",
    "masm HWV; > b_v.log",
    "link HWV; >> b_v.log",
    "masm HWD; > b_d.log",
    "link HWD; >> b_d.log",
    "echo BUILD-DONE > ..\\done.log",
]
(RUN / "BUILD.BAT").write_bytes(
    ("\r\n".join(bat_lines) + "\r\n").encode("ascii"))

conf = [
    "[sdl]",
    "output=surface",
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
    "call d:\\build.bat",
    "exit",
    "",
]
(RUN / "build.conf").write_text("\n".join(conf), encoding="ascii")

# 3. 无头启动（SDL dummy 驱动，不弹窗口）
env_paths = dict(__import__("os").environ)
env_paths["SDL_VIDEODRIVER"] = "dummy"
env_paths["SDL_AUDIODRIVER"] = "dummy"
t0 = time.time()
proc = subprocess.Popen([str(DOSBOX), "-conf", str(RUN / "build.conf")],
                        env=env_paths)
done = RUN / "done.log"
while time.time() - t0 < 60:
    if done.exists():
        break
    if proc.poll() is not None:
        break
    time.sleep(0.5)
try:
    proc.wait(timeout=15)
except subprocess.TimeoutExpired:
    proc.kill()
print(f"[build_check] elapsed={time.time() - t0:.1f}s done={done.exists()}")

# 4. 检查构建日志
fail = False
for tag in ("s", "v", "d"):
    log = RUN / "src" / f"b_{tag}.log"
    txt = log.read_text(errors="replace") if log.exists() else "(missing)"
    exe = RUN / "src" / f"{'HWSCOPE' if tag == 's' else 'HW' + tag.upper()}.EXE"
    err = [l for l in txt.splitlines()
           if "error" in l.lower()
           and not re.match(r"\s*\d+\s+(Warning|Severe)\s+Errors\s*$", l, re.I)]
    print(f"[{tag}] exe={'Y' if exe.exists() else 'N'} err_lines={len(err)}")
    if err or not exe.exists():
        fail = True
        print("---- log ----")
        print(txt[-2000:])
sys.exit(1 if fail else 0)
