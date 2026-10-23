#!/usr/bin/env python3
# fix_testdisk.py - 整体重写 TEST_DISK：修复 TD_FAIL 标号位于正常下落路径的
# 结构性错误（写成功后直落清理，测量循环不可达），并移除诊断插桩。
# 失败路径到 TD_CLEAN 约 250B：条件短跳不可达，统一改用
# "短条件跳跳过 + 无条件 JMP（MASM 自动升级近跳）"两步模式。
import pathlib
import re

ASM = pathlib.Path(__file__).resolve().parents[1] / "src" / "HWSCOPE.ASM"
text = ASM.read_text(encoding="utf-8")

NEW_PROC = """TEST_DISK PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    ; ---- 创建/截断 DISK.BIN ----
    LEA DX, F_DISK
    MOV AH, 3CH                  ; create（CX=0 普通属性）
    XOR CX, CX
    INT 21H                      ; AX = 句柄；CF=1 失败（只读/磁盘满）
    JNC TD_C1OK
    JMP TD_CLEAN                 ; 创建失败：RES 保持 0，无害清理后退出
TD_C1OK:
    MOV DISK_H, AX
    ; ---- 写 64KB（2 x 32KB，源自 RB_BUF；短写视为失败）----
    MOV BX, DISK_H
    MOV AH, 40H
    MOV CX, 32768
    LEA DX, RB_BUF
    INT 21H                      ; AX = 实写字节数
    CMP AX, 32768
    JE  TD_W1OK
    JMP TD_CLEAN
TD_W1OK:
    MOV BX, DISK_H
    MOV AH, 40H
    MOV CX, 32768
    LEA DX, RB_BUF
    INT 21H
    CMP AX, 32768
    JE  TD_W2OK
    JMP TD_CLEAN
TD_W2OK:
    ; ---- 自适应读基准 ----
    MOV RETRY_CNT, 0
TD_ATTEMPT:
    CALL GET_TICK
    MOV T0_LO, AX
    MOV T0_HI, DX
    MOV BP, DISK_REPS
TD_PASS:
    MOV BX, DISK_H               ; seek 到文件头（AH=42h, AL=0, 偏移 0）
    MOV AX, 4200H
    XOR CX, CX
    XOR DX, DX
    INT 21H
    MOV BX, DISK_H               ; 读第 1 块 32KB
    MOV AH, 3FH
    MOV CX, 32768
    LEA DX, RB_BUF
    INT 21H                      ; AX = 实读字节数
    CMP AX, 32768
    JE  TD_R1OK
    JMP TD_CLEAN                 ; 短读：环境异常，放弃测量（RES=0）
TD_R1OK:
    MOV BX, DISK_H               ; 读第 2 块 32KB
    MOV AH, 3FH
    MOV CX, 32768
    LEA DX, RB_BUF
    INT 21H
    CMP AX, 32768
    JE  TD_R2OK
    JMP TD_CLEAN
TD_R2OK:
    DEC BP
    JNZ TD_PASS
    CALL GET_TICK
    SUB AX, T0_LO
    SBB DX, T0_HI                ; DX:AX = 经过 ticks
    MOV BX, AX                   ; BX = ticks
    TEST BX, BX
    JZ  TD_RETRY                 ; ticks=0：量程翻倍重测
    CMP BX, 12
    JB  TD_RETRY                 ; 窗口 <12 tick：量化误差 >8%，翻倍重测
    JMP TD_CALC
TD_RETRY:
    CMP RETRY_CNT, 2
    JAE TD_CALC                  ; 重试次数用尽：按当前窗口计算
    INC RETRY_CNT
    MOV AX, DISK_REPS
    SHL AX, 1                    ; 重复次数翻倍
    CMP AX, 32768                ; 上限 8192x4 = 32768 轮（=2GB）
    JBE TD_SET_REPS
    MOV AX, 32768
TD_SET_REPS:
    MOV DISK_REPS, AX
    JMP TD_ATTEMPT
TD_CALC:
    MOV TICK_TMP, BX             ; 保存 ticks
    MOV AX, DISK_REPS
    MOV DX, AX
    XOR AX, AX                   ; DX:AX = DISK_REPS x 65536（总字节数，
                                ; <=0x80000000；65536 放不进 16 位立即数，
                                ; 故用 DX=reps/AX=0 等价构造）
    MOV BX, TICK_TMP             ; 除数 = ticks
    TEST BX, BX
    JZ  TD_CLEAN                 ; 防呆：ticks=0 时保持原结果
    CALL DIV32_16                ; DX:AX = bytes/tick
    MOV CX, 10
    CALL SHR32                   ; >>1024 -> KB/tick
    MOV BX, 18
    MUL BX                       ; DX:AX = KB/tick x 18 = KB/s
    MOV RES_DSK_LO, AX
    MOV RES_DSK_HI, DX
TD_CLEAN:
    MOV BX, DISK_H               ; 关闭文件
    MOV AH, 3EH
    INT 21H
    LEA DX, F_DISK               ; 删除临时文件（失败可忽略）
    MOV AH, 41H
    INT 21H
TD_RET:
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
TEST_DISK ENDP"""

# 替换 TEST_DISK PROC .. TEST_DISK ENDP 整段
pat = re.compile(r"TEST_DISK PROC.*?TEST_DISK ENDP", re.S)
m = pat.search(text)
assert m, "TEST_DISK proc not found"
text = pat.sub(lambda _: NEW_PROC, text, count=1)

# 删除诊断字符串
for line in (
    "    DBG_DC     DB '[D] create=$'      ; 诊断：create 返回句柄/错误码\n",
    "    DBG_DW     DB '[D] write=$'       ; 诊断：write 返回字节数\n",
    "    DBG_DR     DB '[D] read=$'        ; 诊断：短读时实读字节数\n",
    "    DBG_DS     DB '[D] seek=$'        ; 诊断：首轮 seek 后位置\n",
    "    DBG_DT     DB '[D] ticks=$'       ; 诊断：读基准窗口 ticks\n",
):
    assert line in text, f"diag string missing: {line!r}"
    text = text.replace(line, "", 1)

ASM.write_text(text, encoding="utf-8")
print("TEST_DISK rewritten; diag strings removed")
