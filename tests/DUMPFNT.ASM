; DUMPFNT.ASM - 一次性工具：从 ROM dump 8x8 字体到 FONT8X8.BIN
; 用途：为 HWSCOPE 生成内置字体数据（规避 int 10h 1130h 在 DOSBox 的不稳定性）
STACK SEGMENT STACK
    DW 128 DUP(?)
STACK ENDS
DATA SEGMENT
    FNAME DB 'FONT16.BIN', 0
    FONTSEG_S DW 0
DATA ENDS
CODE SEGMENT
    ASSUME CS:CODE, DS:DATA, SS:STACK
START:
    MOV AX, DATA
    MOV DS, AX
    MOV AX, 1130H
    MOV BH, 06H                 ; ROM 8x16 字体（VGA 标准）
    INT 10H                     ; ES:BP = 字体指针
    MOV FONTSEG_S, ES           ; 先存段（供后面用）
    LEA DX, FNAME
    MOV AH, 3CH
    XOR CX, CX
    INT 21H                     ; 创建文件
    JC FAIL
    MOV BX, AX                  ; 句柄
    PUSH DS
    MOV DS, FONTSEG_S           ; DS = 字体段
    MOV DX, BP                  ; DX = 字体偏移
    MOV CX, 4096                ; 256 字符 x 16 字节
    MOV AH, 40H
    INT 21H                     ; 写字体数据
    POP DS
    MOV AH, 3EH
    INT 21H                     ; 关闭
FAIL:
    MOV AX, 4C00H
    INT 21H
CODE ENDS
    END START
