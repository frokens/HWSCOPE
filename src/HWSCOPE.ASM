; HWSCOPE.ASM - 汇编硬件透视仪（DOSBox Hardware Scope）
; 功能：在 DOSBox 中测量六项硬件指标（CPU 整数 / FPU 浮点 / 内存容量 /
;       RAM 带宽 / VGA 显存带宽 / 磁盘读吞吐），并以 VGA 13h 图形仪表盘
;       （大数字 + 条形图）实时展示；支持按键交互与自动演示两种模式。
; 实现：MASM 5.00 单文件；测量（TEST_*）与渲染（UI_/DRAW_）彻底分离，
;       测量结果只写内存变量，便于调试变体在文本模式下自动化测试。
;
; 变体说明（由 _tmp_extract/tests/mkvariants.py 修改 VARIANT 行同源生成，
;           不要手工维护副本，避免行为漂移）：
;   VARIANT=0  提交版（本文件）：交互式图形程序，阻塞等待按键
;   VARIANT=1  验证版（_tmp_extract/HWV.ASM）：文本模式完成全部测量后切
;              VGA 渲染首屏，创建 HWRENDER 标记，等待按键或约 8 秒超时，
;              退出前把 A000 显存转储成 DUMP.BIN 并创建 HWDONE 标记，
;              同时把屏幕同源数值打进 trace，供主机侧自动断言
;   VARIANT=2  调试版（_tmp_extract/HWD.ASM）：文本模式，不切 VGA，
;              直接调用测量核心并打印 trace 行

VARIANT EQU 0

STACK SEGMENT STACK
    DW 128 DUP(?)
STACK ENDS

DATA SEGMENT
    ; ---- 变体标记文件名与 trace 字符串（ASCIIZ）----
IF VARIANT GE 1
    F_RENDER DB 'HWRENDER.$$$', 0     ; 首屏渲染完成标记（验证版）
    F_DUMP   DB 'DUMP.BIN', 0         ; 显存转储文件名（验证版）
    F_DONE   DB 'HWDONE.$$$', 0       ; 运行完成标记（验证/调试版）
    DBG_M3A  DB '[M3] mem_kb=$'       ; M3 trace：内存容量
    DBG_M3B  DB '[M3] ram_bw=$'       ; M3 trace：RAM 带宽（KB/s）
    DBG_M3C  DB '[M3] vram_bw=$'     ; M3 trace：显存带宽（KB/s）
    DBG_M4   DB '[M4] fpu_flops=$'    ; M4 trace：FPU 浮点基准（FLOPS）
    DBG_M5   DB '[M5] disk_kbs=$'     ; M5 trace：磁盘顺序读吞吐（KB/s）
    DBG_M6   DB '[M6] demo=ok', 0DH, 0AH, '$'  ; M6 trace：自动演示完成
    DBG_CRLF DB 0DH, 0AH, '$'         ; trace 行尾
ENDIF
IF VARIANT EQ 2
    DBG_BANNER DB 'HWSCOPE debug build VARIANT=2', 0DH, 0AH, '$'
    DBG_M0     DB '[M0] pipeline=text-mode-debug-ok', 0DH, 0AH, '$'
    DBG_M1     DB '[M1] font+text+dec32 pipeline=ok', 0DH, 0AH, '$'
    DBG_PRE1   DB '[M1] before-dec32', 0DH, 0AH, '$'
    DBG_M2A    DB '[M2] cpu_ops=$'
ENDIF
    DEC_X    DW 0                     ; SHOW_DEC32 当前 x（逐位右移）
    DEC_Y    DW 0                     ; SHOW_DEC32 y
    DEC_COLR DW 0                     ; SHOW_DEC32 颜色
    DEC_N    DW 0                     ; SHOW_DEC32 位数计数（内存槽，
                                      ; 避免被 DRAW_CHAR 的 CX 参数覆盖）
    STR_COLR DW 0                     ; DRAW_STR 颜色槽
    T0_LO    DW 0                     ; MEASURE_* 起始 tick 低字
    T0_HI    DW 0                     ; MEASURE_* 起始 tick 高字
    RES_CPU_LO DW 0                   ; CPU 基准：ops/sec（32 位）低字
    RES_CPU_HI DW 0                   ; CPU 基准：ops/sec 高字
    RES_FPU_LO DW 0                   ; M4：FPU 基准 FLOPS（32 位）低字
    RES_FPU_HI DW 0                   ; M4：FPU 基准 FLOPS 高字
    RES_DSK_LO DW 0                   ; M5：磁盘顺序读吞吐 KB/s（32 位）低字
    RES_DSK_HI DW 0                   ; M5：磁盘顺序读吞吐 KB/s 高字
    RES_MEM_KB DW 0                   ; M3：常规内存容量（KB，int 12h）
    RES_RAMBW_LO DW 0                 ; M3：RAM 带宽 KB/s（32 位）低字
    RES_RAMBW_HI DW 0                 ; M3：RAM 带宽 KB/s 高字
    RES_VRBW_LO DW 0                  ; M3：显存带宽 KB/s（32 位）低字
    RES_VRBW_HI DW 0                  ; M3：显存带宽 KB/s 高字
    RETRY_CNT DW 0                    ; 带宽测试自适应重试计数（0..2）
    TICK_TMP  DW 0                    ; 带宽测试 ticks 暂存（16 位槽）
    RB_REPS  DW 448                   ; RAMBW 重复次数（16384B×448≈7MB；
                                      ; AH=48h 分配在本环境恒失败，故用
                                      ; 静态缓冲；窗口<12tick 自动翻倍重测，
                                      ; 上限 1792 次≈28MB。主环境 2.8MB/s
                                     ; 下窗口≈45tick，量化误差<2.3%）
    VB_REPS  DW 112                   ; VRAMBW 重复次数（64000B×112≈7MB；
                                      ; 自适应规则同 RB_REPS，上限 448 次）
    DISK_REPS DW 2048                 ; M5：磁盘读重复次数（64KB×2048=128MB 初始；
                                      ; 窗口<12tick 翻倍重测，最多 2 次，上限 32768。
                                      ; DOSBox 文件读走宿主页缓存但 int 21h 分发
                                      ; 有开销，主环境约 48MB/s → 窗口≈48tick）
    DISK_H    DW 0FFFFH             ; M5：测试文件句柄槽（INT 21h 不保证保留
                                      ; 全部寄存器，句柄经内存槽传递最稳；
                                      ; 初值 0FFFFH = 无效句柄，创建失败时
                                      ; 的清理操作close(0FFFFh)必为无害报错）
    TXT_M2   DB 'CPU OPS/S:', 0       ; M2 屏幕标签
    TXT_M4   DB 'FPU FLOPS:', 0       ; M4 屏幕标签
    TXT_M5   DB 'DISK KB/S:', 0       ; M5 屏幕标签
    F_DISK   DB 'DISK.BIN', 0         ; M5：磁盘测试临时文件（当前目录，测完删除；
                                      ; 提交版同样自建自删，不依赖外部文件）
    TXT_STATUS DB 'ESC=EXIT ANY KEY=REMEASURE', 0  ; M6：状态行（提交版交互提示）
    TXT_MEAS DB 'MEASURING...', 0DH, 0AH, '$'      ; M6：交互循环测量提示（文本模式）
    DEMO_PTS DW 8, 78                 ; M6 演示高亮位（x,y 六对，按测量顺序：
    DW 158, 78                        ;   CPU/FPU 行1、MEM/RAM 行2、VRAM/DISK 行3；
    DW 8, 94                          ;   左列 x=8，右列 x=158，行 y=78/94/110）
    DW 158, 94
    DW 8, 110
    DW 158, 110
    TXT_M3A  DB 'MEM KB:', 0          ; M3 屏幕标签
    TXT_M3B  DB 'RAM BW:', 0
    TXT_M3C  DB 'VRAM BW:', 0
    TXT_BAR1 DB 'RAM', 0              ; M7r：迷你条标签（色与条一致：蓝 9）
    TXT_BAR2 DB 'VRAM', 0             ; M7r：迷你条标签（色与条一致：洋红 13）
    DIV_TMP  DW 0                     ; 32 位除法低字暂存
    TXT_M1   DB 'HWSCOPE', 0          ; M1 测试文本
    ; ---- 内置 8x8 字体表（由 _tmp_extract/tests/gen_font.py 从 ROM 8x16
    ;      字体重采样生成：字形占 rows 2-11 共 10 行，最近邻压到 8 行；
    ;      勿手改以下两标记之间的内容，改字体请改 gen_font.py 后重跑）----
    ; FONT_DATA_BEGIN
    FONT8X8 LABEL BYTE
    DB 000H,000H,000H,000H,000H,000H,000H,000H    ;   0 ' '
    DB 07EH,081H,081H,081H,0BDH,099H,081H,07EH    ;   1 ' '
    DB 07EH,0FFH,0FFH,0FFH,0C3H,0E7H,0FFH,07EH    ;   2 ' '
    DB 000H,000H,0FEH,0FEH,0FEH,0FEH,038H,010H    ;   3 ' '
    DB 000H,000H,038H,07CH,0FEH,07CH,010H,000H    ;   4 ' '
    DB 000H,018H,03CH,0E7H,0E7H,0E7H,018H,03CH    ;   5 ' '
    DB 000H,018H,07EH,0FFH,0FFH,07EH,018H,03CH    ;   6 ' '
    DB 000H,000H,000H,018H,03CH,03CH,000H,000H    ;   7 ' '
    DB 0FFH,0FFH,0FFH,0E7H,0C3H,0C3H,0FFH,0FFH    ;   8 ' '
    DB 000H,000H,03CH,066H,042H,042H,03CH,000H    ;   9 ' '
    DB 0FFH,0FFH,0C3H,099H,0BDH,0BDH,0C3H,0FFH    ;  10 ' '
    DB 01EH,00EH,032H,078H,0CCH,0CCH,0CCH,078H    ;  11 ' '
    DB 03CH,066H,066H,066H,03CH,018H,018H,018H    ;  12 ' '
    DB 03FH,033H,030H,030H,030H,030H,0F0H,0E0H    ;  13 ' '
    DB 07FH,063H,063H,063H,063H,063H,0E7H,0E6H    ;  14 ' '
    DB 000H,018H,0DBH,03CH,0E7H,03CH,018H,018H    ;  15 ' '
    DB 0C0H,0E0H,0F8H,0FEH,0F8H,0F0H,0C0H,080H    ;  16 ' '
    DB 006H,00EH,03EH,0FEH,03EH,01EH,006H,002H    ;  17 ' '
    DB 018H,03CH,018H,018H,018H,07EH,018H,000H    ;  18 ' '
    DB 066H,066H,066H,066H,066H,066H,066H,066H    ;  19 ' '
    DB 07FH,0DBH,0DBH,07BH,01BH,01BH,01BH,01BH    ;  20 ' '
    DB 0C6H,060H,06CH,0C6H,0C6H,06CH,00CH,0C6H    ;  21 ' '
    DB 000H,000H,000H,000H,000H,0FEH,0FEH,0FEH    ;  22 ' '
    DB 018H,03CH,018H,018H,018H,07EH,018H,07EH    ;  23 ' '
    DB 018H,03CH,018H,018H,018H,018H,018H,018H    ;  24 ' '
    DB 018H,018H,018H,018H,018H,018H,03CH,018H    ;  25 ' '
    DB 000H,000H,018H,00CH,0FEH,00CH,000H,000H    ;  26 ' '
    DB 000H,000H,030H,060H,0FEH,060H,000H,000H    ;  27 ' '
    DB 000H,000H,000H,0C0H,0C0H,0C0H,000H,000H    ;  28 ' '
    DB 000H,000H,024H,066H,0FFH,066H,000H,000H    ;  29 ' '
    DB 000H,000H,038H,038H,07CH,07CH,0FEH,000H    ;  30 ' '
    DB 000H,000H,0FEH,07CH,07CH,038H,010H,000H    ;  31 ' '
    DB 000H,000H,000H,000H,000H,000H,000H,000H    ;  32 ' '
    DB 018H,03CH,03CH,018H,018H,018H,018H,018H    ;  33 '!'
    DB 066H,066H,000H,000H,000H,000H,000H,000H    ;  34 '"'
    DB 000H,06CH,0FEH,06CH,06CH,06CH,06CH,06CH    ;  35 '#'
    DB 07CH,0C6H,0C0H,07CH,006H,006H,0C6H,07CH    ;  36 '$'
    DB 000H,000H,0C6H,00CH,018H,030H,0C6H,086H    ;  37 '%'
    DB 038H,06CH,038H,076H,0DCH,0CCH,0CCH,076H    ;  38 '&'
    DB 030H,030H,000H,000H,000H,000H,000H,000H    ;  39 '''
    DB 00CH,018H,030H,030H,030H,030H,018H,00CH    ;  40 '('
    DB 030H,018H,00CH,00CH,00CH,00CH,018H,030H    ;  41 ')'
    DB 000H,000H,066H,03CH,0FFH,03CH,000H,000H    ;  42 '*'
    DB 000H,000H,018H,018H,07EH,018H,000H,000H    ;  43 '+'
    DB 000H,000H,000H,000H,000H,000H,018H,018H    ;  44 ','
    DB 000H,000H,000H,000H,0FEH,000H,000H,000H    ;  45 '-'
    DB 000H,000H,000H,000H,000H,000H,018H,018H    ;  46 '.'
    DB 000H,000H,006H,00CH,018H,030H,0C0H,080H    ;  47 '/'
    DB 03CH,066H,0C3H,0DBH,0DBH,0C3H,066H,03CH    ;  48 '0'
    DB 018H,038H,018H,018H,018H,018H,018H,07EH    ;  49 '1'
    DB 07CH,0C6H,00CH,018H,030H,060H,0C6H,0FEH    ;  50 '2'
    DB 07CH,0C6H,006H,03CH,006H,006H,0C6H,07CH    ;  51 '3'
    DB 00CH,01CH,06CH,0CCH,0FEH,00CH,00CH,01EH    ;  52 '4'
    DB 0FEH,0C0H,0C0H,0FCH,006H,006H,0C6H,07CH    ;  53 '5'
    DB 038H,060H,0C0H,0FCH,0C6H,0C6H,0C6H,07CH    ;  54 '6'
    DB 0FEH,0C6H,006H,00CH,018H,030H,030H,030H    ;  55 '7'
    DB 07CH,0C6H,0C6H,07CH,0C6H,0C6H,0C6H,07CH    ;  56 '8'
    DB 07CH,0C6H,0C6H,07EH,006H,006H,00CH,078H    ;  57 '9'
    DB 000H,000H,018H,000H,000H,000H,018H,000H    ;  58 ':'
    DB 000H,000H,018H,000H,000H,000H,018H,030H    ;  59 ';'
    DB 000H,006H,018H,030H,060H,030H,00CH,006H    ;  60 '<'
    DB 000H,000H,07EH,000H,000H,07EH,000H,000H    ;  61 '='
    DB 000H,060H,018H,00CH,006H,00CH,030H,060H    ;  62 '>'
    DB 07CH,0C6H,00CH,018H,018H,018H,018H,018H    ;  63 '?'
    DB 000H,07CH,0C6H,0DEH,0DEH,0DEH,0C0H,07CH    ;  64 '@'
    DB 010H,038H,0C6H,0C6H,0FEH,0C6H,0C6H,0C6H    ;  65 'A'
    DB 0FCH,066H,066H,07CH,066H,066H,066H,0FCH    ;  66 'B'
    DB 03CH,066H,0C0H,0C0H,0C0H,0C0H,066H,03CH    ;  67 'C'
    DB 0F8H,06CH,066H,066H,066H,066H,06CH,0F8H    ;  68 'D'
    DB 0FEH,066H,068H,078H,068H,060H,066H,0FEH    ;  69 'E'
    DB 0FEH,066H,068H,078H,068H,060H,060H,0F0H    ;  70 'F'
    DB 03CH,066H,0C0H,0C0H,0DEH,0C6H,066H,03AH    ;  71 'G'
    DB 0C6H,0C6H,0C6H,0FEH,0C6H,0C6H,0C6H,0C6H    ;  72 'H'
    DB 03CH,018H,018H,018H,018H,018H,018H,03CH    ;  73 'I'
    DB 01EH,00CH,00CH,00CH,00CH,0CCH,0CCH,078H    ;  74 'J'
    DB 0E6H,066H,06CH,078H,078H,06CH,066H,0E6H    ;  75 'K'
    DB 0F0H,060H,060H,060H,060H,060H,066H,0FEH    ;  76 'L'
    DB 0C3H,0E7H,0FFH,0DBH,0C3H,0C3H,0C3H,0C3H    ;  77 'M'
    DB 0C6H,0E6H,0FEH,0DEH,0CEH,0C6H,0C6H,0C6H    ;  78 'N'
    DB 07CH,0C6H,0C6H,0C6H,0C6H,0C6H,0C6H,07CH    ;  79 'O'
    DB 0FCH,066H,066H,07CH,060H,060H,060H,0F0H    ;  80 'P'
    DB 07CH,0C6H,0C6H,0C6H,0C6H,0C6H,0DEH,07CH    ;  81 'Q'
    DB 0FCH,066H,066H,07CH,06CH,066H,066H,0E6H    ;  82 'R'
    DB 07CH,0C6H,060H,038H,00CH,006H,0C6H,07CH    ;  83 'S'
    DB 0FFH,0DBH,018H,018H,018H,018H,018H,03CH    ;  84 'T'
    DB 0C6H,0C6H,0C6H,0C6H,0C6H,0C6H,0C6H,07CH    ;  85 'U'
    DB 0C3H,0C3H,0C3H,0C3H,0C3H,0C3H,03CH,018H    ;  86 'V'
    DB 0C3H,0C3H,0C3H,0C3H,0DBH,0DBH,066H,066H    ;  87 'W'
    DB 0C3H,0C3H,03CH,018H,018H,03CH,0C3H,0C3H    ;  88 'X'
    DB 0C3H,0C3H,066H,03CH,018H,018H,018H,03CH    ;  89 'Y'
    DB 0FFH,0C3H,00CH,018H,030H,060H,0C3H,0FFH    ;  90 'Z'
    DB 03CH,030H,030H,030H,030H,030H,030H,03CH    ;  91 '['
    DB 000H,080H,0E0H,070H,038H,01CH,006H,002H    ;  92 '\'
    DB 03CH,00CH,00CH,00CH,00CH,00CH,00CH,03CH    ;  93 ']'
    DB 06CH,0C6H,000H,000H,000H,000H,000H,000H    ;  94 '^'
    DB 000H,000H,000H,000H,000H,000H,000H,000H    ;  95 '_'
    DB 018H,000H,000H,000H,000H,000H,000H,000H    ;  96 '`'
    DB 000H,000H,078H,00CH,07CH,0CCH,0CCH,076H    ;  97 'a'
    DB 0E0H,060H,078H,06CH,066H,066H,066H,07CH    ;  98 'b'
    DB 000H,000H,07CH,0C6H,0C0H,0C0H,0C6H,07CH    ;  99 'c'
    DB 01CH,00CH,03CH,06CH,0CCH,0CCH,0CCH,076H    ; 100 'd'
    DB 000H,000H,07CH,0C6H,0FEH,0C0H,0C6H,07CH    ; 101 'e'
    DB 038H,06CH,060H,0F0H,060H,060H,060H,0F0H    ; 102 'f'
    DB 000H,000H,076H,0CCH,0CCH,0CCH,0CCH,07CH    ; 103 'g'
    DB 0E0H,060H,06CH,076H,066H,066H,066H,0E6H    ; 104 'h'
    DB 018H,018H,038H,018H,018H,018H,018H,03CH    ; 105 'i'
    DB 006H,006H,00EH,006H,006H,006H,006H,006H    ; 106 'j'
    DB 0E0H,060H,066H,06CH,078H,078H,066H,0E6H    ; 107 'k'
    DB 038H,018H,018H,018H,018H,018H,018H,03CH    ; 108 'l'
    DB 000H,000H,0E6H,0FFH,0DBH,0DBH,0DBH,0DBH    ; 109 'm'
    DB 000H,000H,0DCH,066H,066H,066H,066H,066H    ; 110 'n'
    DB 000H,000H,07CH,0C6H,0C6H,0C6H,0C6H,07CH    ; 111 'o'
    DB 000H,000H,0DCH,066H,066H,066H,066H,07CH    ; 112 'p'
    DB 000H,000H,076H,0CCH,0CCH,0CCH,0CCH,07CH    ; 113 'q'
    DB 000H,000H,0DCH,076H,066H,060H,060H,0F0H    ; 114 'r'
    DB 000H,000H,07CH,0C6H,060H,038H,0C6H,07CH    ; 115 's'
    DB 010H,030H,0FCH,030H,030H,030H,036H,01CH    ; 116 't'
    DB 000H,000H,0CCH,0CCH,0CCH,0CCH,0CCH,076H    ; 117 'u'
    DB 000H,000H,0C3H,0C3H,0C3H,0C3H,03CH,018H    ; 118 'v'
    DB 000H,000H,0C3H,0C3H,0C3H,0DBH,0FFH,066H    ; 119 'w'
    DB 000H,000H,0C3H,066H,03CH,018H,066H,0C3H    ; 120 'x'
    DB 000H,000H,0C6H,0C6H,0C6H,0C6H,0C6H,07EH    ; 121 'y'
    DB 000H,000H,0FEH,0CCH,018H,030H,0C6H,0FEH    ; 122 'z'
    DB 00EH,018H,018H,070H,018H,018H,018H,00EH    ; 123 '{'
    DB 018H,018H,018H,000H,018H,018H,018H,018H    ; 124 '|'
    DB 070H,018H,018H,00EH,018H,018H,018H,070H    ; 125 '}'
    DB 076H,0DCH,000H,000H,000H,000H,000H,000H    ; 126 '~'
    DB 000H,000H,038H,06CH,0C6H,0C6H,0FEH,000H    ; 127 ' '
    ; FONT_DATA_END
    ; ---- RAM 带宽测试静态缓冲（32KB）----
    ; int 21h AH=48h 在本 DOSBox 环境恒失败（错误码 8），动态分配不可用，
    ; 故在 DATA 段内置静态缓冲：前半目标 / 后半源，REP MOVSB 块内拷贝
    RB_BUF   DB 32768 DUP(?)
DATA ENDS

CODE SEGMENT
    ASSUME CS:CODE, DS:DATA, SS:STACK

    PIXCOLOR DB 0                     ; 图元颜色槽（CS 段内，段覆盖访问，
                                      ; 使 PUTPIX/FILLRECT 不依赖 DS）

START:
    MOV AX, DATA
    MOV DS, AX

; ---- 调试变体：文本模式链路验证（不进入图形模式）----
IF VARIANT EQ 2
    LEA DX, DBG_BANNER
    MOV AH, 09H
    INT 21H
    LEA DX, DBG_M0
    MOV AH, 09H
    INT 21H
    CALL SHOW_DEC32_TEST            ; M1：32 位十进制除法链路
    CALL MEASURE_CPU                ; M2：CPU 整数基准
    LEA DX, DBG_M2A
    MOV AH, 09H
    INT 21H
    MOV AX, RES_CPU_LO
    MOV DX, RES_CPU_HI
    CALL TEXT_DEC32
    CALL MEASURE_FPU                ; M4：FPU 浮点基准
    LEA DX, DBG_M4
    MOV AH, 09H
    INT 21H
    MOV AX, RES_FPU_LO
    MOV DX, RES_FPU_HI
    CALL TEXT_DEC32
    CALL TEST_MEMSIZE               ; M3：内存容量
    LEA DX, DBG_M3A
    MOV AH, 09H
    INT 21H
    MOV AX, RES_MEM_KB
    XOR DX, DX
    CALL TEXT_DEC32
    MOV BP, 5                       ; M3/M5：带宽与磁盘 5 次波动测试
HD_M3_LOOP:
    PUSH BP
    CALL TEST_RAMBW
    CALL TEST_VRAMBW
    CALL TEST_DISK
    LEA DX, DBG_M3B
    MOV AH, 09H
    INT 21H
    MOV AX, RES_RAMBW_LO
    MOV DX, RES_RAMBW_HI
    CALL TEXT_DEC32
    LEA DX, DBG_M3C
    MOV AH, 09H
    INT 21H
    MOV AX, RES_VRBW_LO
    MOV DX, RES_VRBW_HI
    CALL TEXT_DEC32
    LEA DX, DBG_M5
    MOV AH, 09H
    INT 21H
    MOV AX, RES_DSK_LO
    MOV DX, RES_DSK_HI
    CALL TEXT_DEC32
    POP BP
    DEC BP
    JNZ HD_M3_LOOP
    CALL TOUCH_DONE
    JMP EXIT_PROG
ENDIF
    ; ---- M6：UI 外壳主流程（测量/渲染严格分离）----
IF VARIANT EQ 1
    ; 验证版：六项全量测量（文本模式）-> 渲染 -> 自动演示 -> 转储
    CALL MEASURE_ALL                ; M2~M5：CPU/FPU/MEM/RAMBW/VRAMBW/DISK
    CALL SET_VGA13
    CALL CLEAR_VRAM
    CALL DRAW_TESTPATTERN
    CALL DEMO_HIGHLIGHT             ; M6：自动演示（无头无按键跑完 6 项）
    ; 把屏幕刚渲染的 M3 值打进 trace（与屏幕严格同源，
    ; 供主机侧做"条形端点与数值成比例"断言）；int 21h 输出在
    ; VGA 模式下写文本页不可见，但重定向进 hwv.log 正常
    LEA DX, DBG_M3A
    MOV AH, 09H
    INT 21H
    MOV AX, RES_MEM_KB
    XOR DX, DX
    CALL TEXT_DEC32
    LEA DX, DBG_M3B
    MOV AH, 09H
    INT 21H
    MOV AX, RES_RAMBW_LO
    MOV DX, RES_RAMBW_HI
    CALL TEXT_DEC32
    LEA DX, DBG_M3C
    MOV AH, 09H
    INT 21H
    MOV AX, RES_VRBW_LO
    MOV DX, RES_VRBW_HI
    CALL TEXT_DEC32
    LEA DX, DBG_M6                  ; M6 trace：自动演示完成
    MOV AH, 09H
    INT 21H
    CALL TOUCH_RENDER              ; 通知主机：首屏已渲染，可截图
    CALL WAIT_KEY_OR_TIMEOUT       ; 等待按键或约 8 秒超时
    CALL DUMP_VRAM                 ; 转储 A000 显存 -> DUMP.BIN
    CALL TOUCH_DONE
ELSE
    ; 提交版：交互循环——文本模式测量 -> VGA 渲染 -> 自动演示 -> 等键重测
MAIN_LOOP:
    CALL SET_TEXT                  ; 回文本模式再测量（设置模式 3 自带清屏）
    LEA DX, TXT_MEAS
    MOV AH, 09H
    INT 21H                        ; "MEASURING..."
    CALL MEASURE_ALL               ; 六项全量测量（只写 RES_* 槽，不碰显存）
    CALL SET_VGA13
    CALL CLEAR_VRAM
    CALL DRAW_TESTPATTERN
    CALL DEMO_HIGHLIGHT            ; M6：自动演示高亮（按键可跳过）
    MOV AH, 00H
    INT 16H                        ; 阻塞等待按键 -> AX=键码
    CMP AX, 011BH                  ; ESC（AH=01 扫描码 / AL=1BH）？
    JE  EXIT_PROG                  ; ESC 退出（恢复文本模式后 4C00h）
    JMP MAIN_LOOP                  ; 其他键：重测一轮
ENDIF

EXIT_PROG:
    CALL SET_TEXT                  ; 恢复文本模式（各变体均安全）
    MOV AX, 4C00H
    INT 21H

; ============================================================
; ---- 初始化 / 显示模式 ----
; ============================================================

; ---- 子程序：设置 VGA 13h 图形模式（320x200x256）----
; 破坏：AX
SET_VGA13 PROC
    MOV AX, 0013H
    INT 10H
    RET
SET_VGA13 ENDP

; ---- 子程序：恢复 80x25 文本模式 ----
; 破坏：AX
SET_TEXT PROC
    MOV AX, 0003H
    INT 10H
    RET
SET_TEXT ENDP

; ---- 子程序：清屏（A000 全屏填背景色 0=黑）----
; 破坏：AX/CX/DI
CLEAR_VRAM PROC
    MOV AX, 0A000H
    MOV ES, AX
    XOR DI, DI
    XOR AL, AL
    MOV CX, 64000
    CLD
    REP STOSB
    RET
CLEAR_VRAM ENDP

; ============================================================
; ---- 像素图元 ----
; ============================================================

; ---- 子程序：画点（AL=颜色，BX=x，CX=y）----
; 破坏：AX/DX/DI（ES 被设为 A000）
PUTPIX PROC
    MOV CS:PIXCOLOR, AL           ; 先存颜色（CS 覆盖：不依赖 DS，下面 AX 要被覆盖）
    MOV AX, 0A000H
    MOV ES, AX
    MOV AX, CX
    MOV DX, 320
    MUL DX                     ; DX:AX = y*320
    ADD AX, BX                 ; + x
    MOV DI, AX
    CLD
    MOV AL, CS:PIXCOLOR        ; STOSB 前恢复颜色
    STOSB                      ; AL -> ES:[DI]
    RET
PUTPIX ENDP

; ---- 子程序：填充矩形（AL=颜色，BX=x，CX=y，SI=宽，DI=高）----
; 破坏：AX/CX/DX/DI（内部保存恢复；BX/SI 保留）
; 注意：颜色必须经 PIXCOLOR 槽传递——循环内 AX/DX 被地址计算反复覆盖，
;       直接靠 AL 传递会在 REP STOSB 时填错值（M0 实测踩坑）
FILLRECT PROC
    PUSH AX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    MOV CS:PIXCOLOR, AL           ; 入口存颜色（CS 覆盖）
    MOV AX, 0A000H
    MOV ES, AX
    MOV BP, DI                 ; BP = 剩余行数
    CLD
FR_ROW:
    MOV AX, CX
    MOV DX, 320
    MUL DX                     ; y*320
    ADD AX, BX                 ; + x
    MOV DI, AX
    PUSH CX
    MOV CX, SI                 ; 每行像素数
    MOV AL, CS:PIXCOLOR        ; 每行恢复颜色
    REP STOSB                  ; AL 颜色填一行
    POP CX
    INC CX                     ; 下一行
    DEC BP
    JNZ FR_ROW
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP AX
    RET
FILLRECT ENDP

; ============================================================
; ---- M1：字体 / 文本 / 32 位十进制 ----
; ============================================================

; ---- 子程序：绘制 8x8 字符（AL=ASCII, BX=x, CX=y, SI=颜色）----
; 字体：DATA 段内置 FONT8X8 表（编译期生成，零 BIOS 依赖）
; 破坏：无（全部保存恢复）
DRAW_CHAR PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    XOR AH, AH
    SHL AX, 1
    SHL AX, 1
    SHL AX, 1                   ; AX = 字符 * 8
    LEA DI, FONT8X8
    ADD DI, AX                  ; DI = 字符点阵起始
    MOV BP, 8                   ; 8 行
DC_ROW:
    MOV DH, [DI]                ; 字体行字节
    INC DI
    MOV DL, 8                   ; 8 位
DC_BIT:
    SHL DH, 1                   ; 最高位移进 CF
    JNC DC_SKIP
    PUSH CX                     ; 保 y
    PUSH DX                     ; 保 DH(字体行)/DL(位计数)
    PUSH BX                     ; 保 x（PUTPIX 要 BX=x）
    PUSH DI                     ; 保字体指针（PUTPIX 契约破坏 DI；
                                ; 曾致字形第 3 行起读显存垃圾"发噪"）
    MOV AX, SI                  ; 颜色 -> AL
    CALL PUTPIX                 ; AL=颜色, BX=x, CX=y
    POP DI
    POP BX
    POP DX
    POP CX
DC_SKIP:
    INC BX                      ; x++
    DEC DL
    JNZ DC_BIT
    SUB BX, 8                   ; x 回行首
    INC CX                      ; y++
    DEC BP
    JNZ DC_ROW
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DRAW_CHAR ENDP

; ---- 子程序：绘制 ASCIIZ 字符串（DS:SI=串, BX=x, CX=y, DI=颜色）----
; 字符宽 8 像素逐字符右移；颜色经 STR_COLR 槽传递，避免占用串指针寄存器
DRAW_STR PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH SI
    MOV STR_COLR, DI
DS_LOOP:
    MOV AL, [SI]
    OR AL, AL
    JZ DS_DONE
    PUSH SI                     ; 保串指针（防御式）
    MOV SI, STR_COLR            ; 颜色 -> SI（DRAW_CHAR 约定）
    CALL DRAW_CHAR              ; AL=字符, BX=x, CX=y, SI=颜色
    POP SI
    INC SI                      ; 下一字符
    ADD BX, 8                   ; 右移一字符宽
    JMP DS_LOOP
DS_DONE:
    POP SI
    POP CX
    POP BX
    POP AX
    RET
DRAW_STR ENDP

; ---- 子程序：显示 32 位十进制数（DX:AX=值, BX=x, CX=y, SI=颜色）----
; 算法：32 位除 10 分两阶段（高字先除得商高，再以余数拼低字除），
;       避免 DX:AX 一次 DIV 商超 65535 触发 #DE；逐位压栈后逆序绘制
SHOW_DEC32 PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    MOV DEC_X, BX               ; 坐标/颜色入内存槽（除法要占用 BX/CX/DX/SI/DI）
    MOV DEC_Y, CX
    MOV DEC_COLR, SI
    MOV DEC_N, 0                ; DEC_N = 0（位数计数）。不可用 XOR AX,AX
                                ; 清零：AX 是 DX:AX 待显示值的低字，会被抹掉
                                ; （曾致 MEM KB=640 只显示 "0"）
SD_DIV:
    ; 输入 DX:AX = 待除数；输出 DX:AX = 商；压栈数字 = 本次余数
    MOV DIV_TMP, AX             ; 暂存低字
    MOV AX, DX                  ; 高字
    XOR DX, DX
    MOV BX, 10
    DIV BX                      ; AX = 商高, DX = 高字%10
    MOV SI, DX                  ; SI = 高字%10
    MOV DI, AX                  ; DI = 商高
    MOV DX, SI                  ; DX = 高字%10
    MOV AX, DIV_TMP             ; AX = 低字
    DIV BX                      ; DX:AX = (高字%10:低字)/10
                                ; -> AX = 商低, DX = 本次数字(0-9)
    PUSH DX                     ; 压数字（从低位到高位）
    INC DEC_N                   ; 位数++（内存计数）
    MOV DX, DI                  ; DX = 商高（兼作下次迭代输入）
    TEST DI, DI                 ; 商高 == 0 ?（TEST 不破坏操作数，
    JNZ SD_DIV                  ;   避免 OR DX,AX 污染商高导致不收敛）
    TEST AX, AX                 ; 商低 == 0 ?
    JNZ SD_DIV
SD_DRAW:
    POP DX                      ; 弹数字（最高位先出）
    ADD DL, '0'
    MOV AL, DL
    MOV BX, DEC_X
    MOV CX, DEC_Y               ; 注意：CX 只作 DRAW_CHAR 的 y 参数，
    MOV SI, DEC_COLR            ;       位数计数在 DEC_N，互不覆盖
    CALL DRAW_CHAR
    ADD DEC_X, 8
    DEC DEC_N                   ; 剩余位数--
    JNZ SD_DRAW
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
SHOW_DEC32 ENDP

IF VARIANT EQ 2
; ---- M1 调试链路自检（文本模式：验证除法循环不崩溃）----
; 调试版专用：以 0FFFFFFFFh 走一遍 SHOW_DEC32 的除法骨架
SHOW_DEC32_TEST PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    LEA DX, DBG_PRE1
    MOV AH, 09H
    INT 21H
    MOV AX, 0FFFFH
    MOV DX, 0FFFFH              ; 4294967295（10 位，最坏情形）
    MOV BX, 20                  ; x（文本模式画点无意义，给合法值防呆）
    MOV CX, 120                 ; y
    MOV SI, 15                  ; 颜色
    CALL SHOW_DEC32             ; 验证除法链+绘制链不死循环不跑飞
    LEA DX, DBG_M1
    MOV AH, 09H
    INT 21H
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
SHOW_DEC32_TEST ENDP
ENDIF

; ============================================================
; ---- M2：计时与 CPU 整数基准 ----
; ============================================================

; ---- 子程序：32 位 / 16 位 -> 32 位商 + 16 位余数 ----
; 入口：DX:AX = 被除数, BX = 除数（≠0）
; 出口：DX:AX = 商, SI = 余数
; 破坏：CX/DI/SI（调用方需自行保存）
; 原理：先除高字得商高，再以中间余数拼低字除，防一次 DIV 商超 65535 触发 #DE
DIV32_16 PROC
    MOV CX, AX                ; CX = 低字（DIV 不碰 CX）
    MOV AX, DX                ; AX = 高字
    XOR DX, DX
    DIV BX                    ; AX = 商高, DX = 高字%除数
    MOV SI, DX                ; 中间余数
    MOV DI, AX                ; 商高
    MOV DX, SI                ; DX = 中间余数
    MOV AX, CX                ; AX = 低字
    DIV BX                    ; AX = 商低, DX = 最终余数
    MOV SI, DX                ; SI = 余数
    MOV DX, DI                ; DX = 商高
    RET                       ; DX:AX = 商, SI = 余数
DIV32_16 ENDP

; ---- 子程序：CPU 整数基准（测量 -> 写 RES_CPU，不渲染）----
; 负载：2048 轮 x 1024 次内循环 x 8 条混合 ALU（无内存访问，纯寄存器），
;       共约 1678 万条 ALU + 210 万条 LOOP；实测窗口约 114 tick（约 6.3 秒，
;       量化误差 <1%；窗口须 >=4 tick，否则负载翻倍——见 TEST_RAMBW 自适应）
; 结果：RES_CPU = ops*18/ticks ≈ ops/sec（18.2 = tick 频率，取 18 减误差）
MEASURE_CPU PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    CALL GET_TICK
    MOV T0_LO, AX
    MOV T0_HI, DX
    MOV BP, 2048              ; 外层轮数
MC_OUTER:
    MOV CX, 1024              ; 内层次数（CX 专作计数，负载指令不碰 CX）
MC_INNER:
    INC AX
    ADD BX, AX
    SHL DX, 1
    XOR SI, DX
    ADD AX, BX
    OR DI, SI
    INC BX
    XOR DX, DI
    LOOP MC_INNER
    DEC BP
    JNZ MC_OUTER
    CALL GET_TICK
    SUB AX, T0_LO
    SBB DX, T0_HI             ; DX:AX = 经过 ticks
    MOV BX, AX                ; BX = 除数（ticks）
    TEST BX, BX
    JZ MC_DONE                ; 防 ticks=0 触发 #DE
    MOV DX, 1200H             ; 被除数 = ops*18 = 16777216*18 = 0x12000000
    XOR AX, AX
    CALL DIV32_16             ; DX:AX = ops/sec, SI = 余数
    MOV RES_CPU_LO, AX
    MOV RES_CPU_HI, DX
MC_DONE:
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
MEASURE_CPU ENDP

; ============================================================
; ---- M3：内存容量 / RAM 带宽 / 显存带宽 ----
; ============================================================

; ---- 子程序：常规内存容量（int 12h -> AX = KB）----
; DOSBox 下恒为 640（常规内存上限，与 conf 的 memsize 无关）
; 破坏：AX（其余保存恢复）
TEST_MEMSIZE PROC
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    MOV AH, 12H
    INT 12H                    ; AX = 常规内存 KB 数
    MOV RES_MEM_KB, AX
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    RET
TEST_MEMSIZE ENDP

; ---- 子程序：32 位逻辑右移（DX:AX >>= CL，CL 先经 CX 传入）----
; 破坏：CX
; 注意：必须高字先移——SHR DX,1 把高字最低位送 CF，RCR AX,1 把 CF
;       补入低字最高位。次序反了（先 SHR AX）会把低字的位移位泄漏进
;       高字，DX 被污染后 CLAMP_BAR 必顶格（2026 年调试实证：558>>6
;       算出 DX=0A800h，条形满长——当时布局满长 280，M7r 起顶格 257）
SHR32 PROC
    TEST CX, CX
    JZ  S32_DONE
S32_LOOP:
    SHR DX, 1                   ; 高字先移：DX 最低位进 CF
    RCR AX, 1                   ; 低字续移：CF 补入 AX 最高位
    LOOP S32_LOOP
S32_DONE:
    RET
SHR32 ENDP

; ---- 子程序：RAM 带宽（DATA 段静态 32KB 缓冲内 REP MOVSB 反复拷贝）----
; 总量 = 16384B x RB_REPS；自适应：窗口 <12 tick 时次数翻倍重测（最多 2 次，
;       上限 1792 次 =28MB），慢宿主不溢出、快宿主量化误差 <=8%
; 结果 = KB/s（32 位）：bytes/tick = 总量/ticks（DIV32_16），
;       KB/s = (bytes/tick >> 10) x 18（tick 频率 18.2 取 18 减误差）
; ES = DATA；DS 全程不变（无段切换，杜绝写错段）；ES/DS 保存恢复
TEST_RAMBW PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    PUSH DS
    PUSH ES
    MOV AX, DATA
    MOV ES, AX                ; ES = DATA（RB_BUF 所在段）
    MOV RETRY_CNT, 0
RB_ATTEMPT:
    CALL GET_TICK
    MOV T0_LO, AX
    MOV T0_HI, DX
    MOV BP, RB_REPS
RB_LOOP:
    LEA SI, RB_BUF+16384      ; 源 = 缓冲后半
    LEA DI, RB_BUF            ; 目标 = 缓冲前半（ES = DATA）
    MOV CX, 16384
    CLD
    REP MOVSB                 ; 块内拷贝（src/dst 不重叠）
    DEC BP
    JNZ RB_LOOP
    CALL GET_TICK
    SUB AX, T0_LO
    SBB DX, T0_HI             ; DX:AX = 经过 ticks
    MOV BX, AX                ; BX = ticks（低字，窗口 <1h 时高字为 0）
    TEST BX, BX
    JZ  RB_RETRY              ; ticks=0：量程翻倍重测
    CMP BX, 12
    JB  RB_RETRY              ; 窗口 <12 tick：量化误差 >8%，翻倍重测
    JMP RB_CALC
RB_RETRY:
    CMP RETRY_CNT, 2
    JAE RB_CALC               ; 重试次数用尽：按当前窗口计算
    INC RETRY_CNT
    MOV AX, RB_REPS
    SHL AX, 1                 ; 重复次数翻倍
    CMP AX, 1792              ; 上限 448x4 = 1792 次（=28MB）
    JBE RB_SET_REPS
    MOV AX, 1792
RB_SET_REPS:
    MOV RB_REPS, AX
    JMP RB_ATTEMPT
RB_CALC:
    MOV TICK_TMP, BX          ; 保存 ticks
    MOV AX, RB_REPS
    MOV BX, 16384
    MUL BX                    ; DX:AX = 总字节数（<=0x01C00000）
    MOV BX, TICK_TMP          ; 除数 = ticks
    TEST BX, BX
    JZ  RB_EXIT               ; 防呆：ticks=0 时保持原结果
    CALL DIV32_16             ; DX:AX = bytes/tick
    MOV CX, 10
    CALL SHR32                ; >>1024 -> KB/tick
    MOV BX, 18
    MUL BX                    ; DX:AX = KB/tick x 18 = KB/s
    MOV RES_RAMBW_LO, AX
    MOV RES_RAMBW_HI, DX
RB_EXIT:
    POP ES
    POP DS
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
TEST_RAMBW ENDP

; ---- 子程序：显存带宽（A000 REP STOSB 反复写满 64000 字节）----
; 自带模式切换：入口切 13h、出口恢复 03h，基准条件与调用时序无关
; 总量 = 64000B x VB_REPS；自适应同 TEST_RAMBW（上限 448 次 =28MB）
; 结果 = KB/s（32 位），算法同 TEST_RAMBW；ES 保存恢复
TEST_VRAMBW PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    PUSH DS
    PUSH ES
    MOV AX, 0013H
    INT 10H                    ; 切 VGA 13h（保证基准条件一致）
    MOV AX, 0A000H
    MOV ES, AX
    MOV RETRY_CNT, 0
VB_ATTEMPT:
    CALL GET_TICK
    MOV T0_LO, AX
    MOV T0_HI, DX
    MOV BP, VB_REPS
VB_LOOP:
    XOR DI, DI                 ; 目标 = 显存首
    MOV AL, 5                  ; 写洋红（顺手验证显存可写）
    MOV CX, 64000
    CLD
    REP STOSB                  ; 写满一帧 64000 字节
    DEC BP
    JNZ VB_LOOP
    CALL GET_TICK
    SUB AX, T0_LO
    SBB DX, T0_HI              ; DX:AX = 经过 ticks
    MOV BX, AX                 ; BX = ticks（低字）
    TEST BX, BX
    JZ  VB_RETRY
    CMP BX, 12
    JB  VB_RETRY
    JMP VB_CALC
VB_RETRY:
    CMP RETRY_CNT, 2
    JAE VB_CALC
    INC RETRY_CNT
    MOV AX, VB_REPS
    SHL AX, 1
    CMP AX, 448                ; 上限 112x4 = 448 次（=28MB）
    JBE VB_SET_REPS
    MOV AX, 448
VB_SET_REPS:
    MOV VB_REPS, AX
    JMP VB_ATTEMPT
VB_CALC:
    MOV TICK_TMP, BX
    MOV AX, VB_REPS
    MOV BX, 64000
    MUL BX                    ; DX:AX = 总字节数（<=0x01B5D400）
    MOV BX, TICK_TMP
    TEST BX, BX
    JZ  VB_EXIT               ; 防呆：ticks=0 时保持原结果
    CALL DIV32_16             ; DX:AX = bytes/tick
    MOV CX, 10
    CALL SHR32                ; >>1024 -> KB/tick
    MOV BX, 18
    MUL BX                    ; DX:AX = KB/tick x 18 = KB/s
    MOV RES_VRBW_LO, AX
    MOV RES_VRBW_HI, DX
VB_EXIT:
    MOV AX, 0003H
    INT 10H                    ; 恢复文本模式（调用方无感知）
    POP ES
    POP DS
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
TEST_VRAMBW ENDP

; ---- 子程序：条形长度 clamp（DX:AX -> AX = min(值, 257)）----
; 高字非零直接顶格；仅破坏 AX
CLAMP_BAR PROC
    TEST DX, DX
    JZ  CB_LOW
    MOV AX, 257                ; 值超 16 位：顶格（M7r：条起点 x=56，
                                ; 56+257=313 不越右边框）
    RET
CB_LOW:
    CMP AX, 257
    JBE CB_DONE
    MOV AX, 257
CB_DONE:
    RET
CLAMP_BAR ENDP


; ============================================================
; ---- M4：FPU 浮点基准 ----
; ============================================================

; ---- 子程序：FPU 浮点基准（x87 混合运算 -> 写 RES_FPU，不渲染）----
; 负载：512 轮 x 1024 次内循环 x 8 条混合 x87（FADD/FSUB/FMUL/FDIV），
;       运算按"加-减""乘-除"配对，ST(0)/ST(1) 每轮归位回 1.0——
;       不发散、不溢出、不产生 Inf/NaN、不触发任何 x87 异常
;       实测窗口约 54 tick（约 3.0 秒）
; 结果：RES_FPU = ops*18/ticks ≈ FLOPS（18.2 = tick 频率，取 18 减误差）
MEASURE_FPU PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    FINIT                       ; 复位 x87（清状态字、屏蔽全部异常）
    FLD1                        ; ST(0) = 1.0
    FLD1                        ; ST(0) = 1.0, ST(1) = 1.0
    CALL GET_TICK
    MOV T0_LO, AX
    MOV T0_HI, DX
    MOV BP, 512                 ; 外层轮数
MF_OUTER:
    MOV CX, 1024                ; 内层次数（CX 专作计数，FPU 指令不碰 CX）
MF_INNER:
    FADD ST(0), ST(1)           ; 1：ST0 += ST1
    FSUB ST(0), ST(1)           ; 2：ST0 -= ST1（归位）
    FMUL ST(1), ST(0)           ; 3：ST1 *= ST0
    FDIV ST(1), ST(0)           ; 4：ST1 /= ST0（归位）
    FADD ST(1), ST(0)           ; 5：ST1 += ST0
    FSUB ST(1), ST(0)           ; 6：ST1 -= ST0（归位）
    FMUL ST(0), ST(1)           ; 7：ST0 *= ST1
    FDIV ST(0), ST(1)           ; 8：ST0 /= ST1（归位）
    LOOP MF_INNER
    DEC BP
    JNZ MF_OUTER
    CALL GET_TICK
    SUB AX, T0_LO
    SBB DX, T0_HI               ; DX:AX = 经过 ticks
    MOV BX, AX                  ; BX = 除数（ticks）
    TEST BX, BX
    JZ  MF_DONE                 ; 防 ticks=0 触发 #DE
    MOV DX, 0480H               ; 被除数 = ops*18 = 4194304*18 = 0x04800000
    XOR AX, AX
    CALL DIV32_16               ; DX:AX = FLOPS, SI = 余数
    MOV RES_FPU_LO, AX
    MOV RES_FPU_HI, DX
MF_DONE:
    FINIT                       ; 离开时复位 x87，不留脏状态给后续代码
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
MEASURE_FPU ENDP

; ============================================================
; ---- M5：磁盘顺序读吞吐 ----
; ============================================================

; ---- 子程序：磁盘顺序读吞吐（int 21h 文件基准 -> 写 RES_DSK，不渲染）----
; 方法：当前目录自建 DISK.BIN（64KB，测完删除——提交版同样自包含，
;       不依赖外部文件）；每轮 seek 到文件头后顺序读 2x32KB，
;       重复 DISK_REPS 轮；自适应同带宽测试（窗口<12tick 翻倍，最多 2 次）
; 结果：RES_DSK = KB/s（32 位），算法同 TEST_RAMBW
; 注意：DOSBox 文件读走宿主文件系统（页缓存），测得的是"DOSBox int 21h
;       读路径"吞吐而非裸盘硬件——报告须如实注明此模拟器固有属性
TEST_DISK PROC
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
TEST_DISK ENDP

; ---- 子程序：六项指标全量测量（文本模式；交互循环的重复单元）----
; 顺序：CPU -> FPU -> MEM -> RAMBW -> VRAMBW -> DISK
; 测量/渲染严格分离：本过程只写 RES_* 槽，不碰显存与显示模式
; （TEST_VRAMBW 内部自带 13h/03h 切换，退出时保证回到文本模式）
MEASURE_ALL PROC
    CALL MEASURE_CPU                ; M2：CPU 整数基准
    CALL MEASURE_FPU                ; M4：FPU 浮点基准
    CALL TEST_MEMSIZE               ; M3a：常规内存容量
    CALL TEST_RAMBW                 ; M3b：RAM 带宽（静态缓冲）
    CALL TEST_VRAMBW                ; M3c：显存带宽（内部自带 13h/03h 切换）
    CALL TEST_DISK                  ; M5：磁盘顺序读吞吐（自建临时文件）
    RET
MEASURE_ALL ENDP

IF VARIANT GE 1
; ---- 子程序：文本模式输出 32 位十进制（DX:AX=值 -> stdout，行尾自带 CRLF）----
; 除法骨架与 SHOW_DEC32 同源（输出端不同：int 21h/02h 逐字符）
; 调试/验证变体共用：HWD 打 trace，HWV 打屏幕值供主机侧条形比例断言
TEXT_DEC32 PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    MOV DEC_N, 0              ; 位数 = 0（勿动 AX/DX：被除数在此）
TD_DIV:
    MOV DIV_TMP, AX           ; 暂存低字
    MOV AX, DX                ; 高字
    XOR DX, DX
    MOV BX, 10
    DIV BX                    ; AX = 商高, DX = 高字%10
    MOV SI, DX                ; 中间余数
    MOV DI, AX                ; 商高
    MOV DX, SI
    MOV AX, DIV_TMP           ; 低字
    DIV BX                    ; AX = 商低, DX = 数字
    PUSH DX                   ; 压数字（低位先）
    INC DEC_N
    MOV DX, DI                ; 商高
    TEST DI, DI
    JNZ TD_DIV
    TEST AX, AX
    JNZ TD_DIV
TD_OUT:
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H                   ; 输出一位
    DEC DEC_N
    JNZ TD_OUT
    MOV DL, 0DH               ; CR
    MOV AH, 02H
    INT 21H
    MOV DL, 0AH               ; LF
    MOV AH, 02H
    INT 21H
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
TEXT_DEC32 ENDP
ENDIF

; ---- 首屏渲染（纯渲染；所有测量已在 START 阶段完成）----
; M7r 排版重构（2026-10-23，用户反馈"文字挤、彩条占地方大"）：
;   三彩条 3×(280x20) 占屏高 40% -> 缩为 3×(96x6) 顶部细条（保留 M0 三色
;   自检与装饰功能）；文字行距 8px -> 16px；六项指标由"标签/数值两行 +
;   双列 3+2"改为"标签+数值同行 + 3行×2列"（左列 CPU/MEM/VRAM，
;   右列 FPU/RAM/DISK），原 DRAW_M3_PANEL 并入本过程（布局常量集中一处）。
; 布局（320x200，8px 字高）：
;   y=8..13     三彩条细条 96x6 并排（青 x=16 / 绿 x=112 / 红 x=208）
;   y=32..178   仪表盘边框（1px 深灰，x=6..313）
;   y=44/58     标题 HWSCOPE（白）/ M1 自检数字 4294967295（黄）
;   y=78/94/110 指标行：左列标签 x=20 数值 x=104，右列标签 x=170 数值 x=254
;              行1 CPU OPS/S | FPU FLOPS；行2 MEM KB | RAM BW；
;              行3 VRAM BW | DISK KB/S
;   y=132       状态行（浅灰 7）
;   y=153/161   迷你条标签 RAM（蓝 9）/ VRAM（洋红 13），条起点 x=56
;   y=154/162   RAM 条（蓝 9）/ VRAM 条（洋红 13），长 = 值>>6 clamp 257
; 颜色：11=淡青 10=淡绿 12=淡红 15=白 14=黄 7=浅灰 8=深灰 9=蓝 13=洋红
DRAW_TESTPATTERN PROC
    ; ---- M0：三色彩条（细条化：96x6 并排，仅保留自检与装饰功能）----
    MOV AL, 11
    MOV BX, 16
    MOV CX, 8
    MOV SI, 96
    MOV DI, 6
    CALL FILLRECT
    MOV AL, 10
    MOV BX, 112
    MOV CX, 8
    MOV SI, 96
    MOV DI, 6
    CALL FILLRECT
    MOV AL, 12
    MOV BX, 208
    MOV CX, 8
    MOV SI, 96
    MOV DI, 6
    CALL FILLRECT
    MOV AL, 15                 ; 白点（验证 PUTPIX，右下角边框外）
    MOV BX, 308
    MOV CX, 188
    CALL PUTPIX
    ; ---- M1：标题 + 32 位自检数字 ----
    LEA SI, TXT_M1             ; "HWSCOPE"（白色）
    MOV BX, 20
    MOV CX, 44
    MOV DI, 15
    CALL DRAW_STR
    MOV AX, 0FFFFH             ; 4294967295（黄色）
    MOV DX, 0FFFFH
    MOV BX, 20
    MOV CX, 58
    MOV SI, 14
    CALL SHOW_DEC32
    ; ---- 指标行 1（y=78）：CPU OPS/S | FPU FLOPS ----
    LEA SI, TXT_M2
    MOV BX, 20
    MOV CX, 78
    MOV DI, 15
    CALL DRAW_STR
    MOV AX, RES_CPU_LO
    MOV DX, RES_CPU_HI
    MOV BX, 104                ; 数值列：避开最长标签（10 字符到 x=99）
    MOV CX, 78
    MOV SI, 14
    CALL SHOW_DEC32
    LEA SI, TXT_M4
    MOV BX, 170
    MOV CX, 78
    MOV DI, 15
    CALL DRAW_STR
    MOV AX, RES_FPU_LO
    MOV DX, RES_FPU_HI
    MOV BX, 254
    MOV CX, 78
    MOV SI, 14
    CALL SHOW_DEC32
    ; ---- 指标行 2（y=94）：MEM KB | RAM BW ----
    LEA SI, TXT_M3A
    MOV BX, 20
    MOV CX, 94
    MOV DI, 15
    CALL DRAW_STR
    MOV AX, RES_MEM_KB
    XOR DX, DX
    MOV BX, 104
    MOV CX, 94
    MOV SI, 14
    CALL SHOW_DEC32
    LEA SI, TXT_M3B
    MOV BX, 170
    MOV CX, 94
    MOV DI, 15
    CALL DRAW_STR
    MOV AX, RES_RAMBW_LO
    MOV DX, RES_RAMBW_HI
    MOV BX, 254
    MOV CX, 94
    MOV SI, 14
    CALL SHOW_DEC32
    ; ---- 指标行 3（y=110）：VRAM BW | DISK KB/S ----
    LEA SI, TXT_M3C
    MOV BX, 20
    MOV CX, 110
    MOV DI, 15
    CALL DRAW_STR
    MOV AX, RES_VRBW_LO
    MOV DX, RES_VRBW_HI
    MOV BX, 104
    MOV CX, 110
    MOV SI, 14
    CALL SHOW_DEC32
    LEA SI, TXT_M5
    MOV BX, 170
    MOV CX, 110
    MOV DI, 15
    CALL DRAW_STR
    MOV AX, RES_DSK_LO
    MOV DX, RES_DSK_HI
    MOV BX, 254
    MOV CX, 110
    MOV SI, 14
    CALL SHOW_DEC32
    ; ---- M6：状态行（浅灰，y=132）----
    LEA SI, TXT_STATUS
    MOV BX, 20
    MOV CX, 132
    MOV DI, 7
    CALL DRAW_STR
    ; ---- 迷你条：RAM（y=154，蓝 9）/ VRAM（y=162，洋红 13）----
    ; M7r：条左侧加同色系标签（RAM/VRAM），条起点 x=56，顶格 257
    LEA SI, TXT_BAR1            ; 标签 "RAM"（蓝 9，与条同色）
    MOV BX, 20
    MOV CX, 153
    MOV DI, 9
    CALL DRAW_STR
    MOV AX, RES_RAMBW_LO
    MOV DX, RES_RAMBW_HI
    MOV CX, 6
    CALL SHR32                 ; >>6 = 每像素 64 KB/s
    CALL CLAMP_BAR             ; 顶格 257
    MOV SI, AX
    MOV AL, 9
    MOV BX, 56
    MOV CX, 154
    MOV DI, 5
    CALL FILLRECT
    LEA SI, TXT_BAR2            ; 标签 "VRAM"（洋红 13，与条同色）
    MOV BX, 20
    MOV CX, 161
    MOV DI, 13
    CALL DRAW_STR
    MOV AX, RES_VRBW_LO
    MOV DX, RES_VRBW_HI
    MOV CX, 6
    CALL SHR32
    CALL CLAMP_BAR
    MOV SI, AX
    MOV AL, 13
    MOV BX, 56
    MOV CX, 162
    MOV DI, 5
    CALL FILLRECT
    ; ---- M6：仪表盘边框（1px 深灰矩形 x=6..313, y=32..178）----
    MOV AL, 8                   ; 深灰
    MOV BX, 6
    MOV CX, 32
    MOV SI, 308
    MOV DI, 1
    CALL FILLRECT               ; 上边（y=32）
    MOV AL, 8
    MOV BX, 6
    MOV CX, 178
    MOV SI, 308
    MOV DI, 1
    CALL FILLRECT               ; 下边（y=178）
    MOV AL, 8
    MOV BX, 6
    MOV CX, 32
    MOV SI, 1
    MOV DI, 147
    CALL FILLRECT               ; 左边（x=6, y=32..178）
    MOV AL, 8
    MOV BX, 313
    MOV CX, 32
    MOV SI, 1
    MOV DI, 147
    CALL FILLRECT               ; 右边（x=313, y=32..178）
    RET
DRAW_TESTPATTERN ENDP

; ============================================================
; ---- M6：UI 外壳——自动演示高亮 ----
; ============================================================

; ---- 子程序：自动演示——依次高亮 6 个指标行（">" 亮黄标记 ~0.7s 后涂黑擦除）----
; 高亮位坐标表 DEMO_PTS（x,y 六对）；演示期间按键立即跳过（键留在
; BIOS 缓冲区，交由交互主循环处理）。破坏：AX/BX/CX/DX/SI/DI（全保存）
DEMO_HIGHLIGHT PROC
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    LEA SI, DEMO_PTS
    MOV CX, 6                       ; 6 个指标
DH_ITEM:
    PUSH CX                        ; 保循环计数（FILLRECT 擦除用 CX）
    PUSH SI                        ; 保表指针（DRAW_CHAR 的 SI 是颜色参数）
    MOV BX, [SI]                   ; x（DRAW_CHAR/FILLRECT 均要 BX=x）
    MOV CX, [SI+2]                 ; y（DRAW_CHAR 要 CX=y，不是 DX！）
    PUSH CX                        ; 保 y（DEMO_DELAY 破坏 CX/DX）
    PUSH BX                        ; 保 x（DEMO_DELAY 破坏 BX）
    MOV AL, '>'
    MOV SI, 14                     ; 亮黄
    CALL DRAW_CHAR                 ; 画高亮标记（AL=字符, BX=x, CX=y, SI=色）
    CALL DEMO_DELAY                ; ~0.7s，可被按键打断
    POP BX                         ; 恢复 x
    POP CX                         ; 恢复 y
    MOV AL, 0                      ; 黑
    MOV SI, 8                      ; 宽 8
    MOV DI, 8                      ; 高 8
    CALL FILLRECT                  ; 涂黑 8x8 单元格（空格字形无像素，
                                ; 必须用矩形填充才能真正擦除）
    POP SI                         ; 恢复表指针
    POP CX                         ; 恢复循环计数
    ADD SI, 4                      ; 下一对坐标
    LOOP DH_ITEM
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DEMO_HIGHLIGHT ENDP

; ---- 子程序：演示延时 ~0.7s（13 tick），期间有按键立即返回 ----
; 破坏：AX/BX/CX/DX（调用方如需保留须自行压栈）
DEMO_DELAY PROC
    PUSH BX
    PUSH CX
    PUSH DX
    CALL GET_TICK
    MOV BX, AX                     ; 起始 tick（低字）
DD_LOOP:
    MOV AH, 01H
    INT 16H                        ; ZF=0 表示有键
    JNZ DD_DONE                    ; 按键：跳过剩余延时
    CALL GET_TICK
    MOV CX, AX
    SUB CX, BX                     ; 回绕安全的经过 tick 数
    CMP CX, 13                     ; 13 tick 约 0.71 秒
    JB  DD_LOOP
DD_DONE:
    POP DX
    POP CX
    POP BX
    RET
DEMO_DELAY ENDP

; ============================================================
; ---- 计时 ----
; ============================================================

; ---- 子程序：读取 BIOS tick 计数 ----
; 出口：DX:AX = tick 数（每秒 18.2 次，开机以来）
; 破坏：AX/DX（CX 内部保存恢复）
GET_TICK PROC
    PUSH CX
    MOV AH, 00H
    INT 1AH                    ; 出口 CX:DX = tick 计数
    MOV AX, DX
    MOV DX, CX
    POP CX
    RET
GET_TICK ENDP

; ============================================================
; ---- 验证 / 调试专用（VARIANT 门控）----
; ============================================================

IF VARIANT GE 1
; ---- 子程序：创建空文件（DX=ASCIIZ 文件名）----
; 出口：CF=1 失败；破坏：AX/BX
TOUCH PROC
    MOV AH, 3CH
    XOR CX, CX
    INT 21H
    JC  TOUCH_FAIL
    MOV BX, AX
    MOV AH, 3EH
    INT 21H
    CLC
    RET
TOUCH_FAIL:
    STC
    RET
TOUCH ENDP

; ---- 子程序：创建运行完成标记 ----
TOUCH_DONE PROC
    LEA DX, F_DONE
    CALL TOUCH
    RET
TOUCH_DONE ENDP
ENDIF

IF VARIANT EQ 1
; ---- 子程序：创建首屏渲染完成标记 ----
TOUCH_RENDER PROC
    LEA DX, F_RENDER
    CALL TOUCH
    RET
TOUCH_RENDER ENDP

; ---- 子程序：等待按键或约 8 秒超时 ----
; 破坏：AX/BX/CX/DX
WAIT_KEY_OR_TIMEOUT PROC
    PUSH BX
    PUSH CX
    PUSH DX
    CALL GET_TICK
    MOV BX, AX                 ; 起始 tick（低字）
WT_LOOP:
    MOV AH, 01H
    INT 16H                    ; ZF=0 表示有键，AX=键值
    JZ  WT_CHECK
    MOV AH, 00H
    INT 16H                    ; 取走按键
    JMP WT_DONE
WT_CHECK:
    CALL GET_TICK
    MOV CX, AX
    SUB CX, BX                 ; 回绕安全的经过 tick 数
    CMP CX, 160                ; 160 tick 约 8.8 秒
    JB  WT_LOOP
WT_DONE:
    POP DX
    POP CX
    POP BX
    RET
WAIT_KEY_OR_TIMEOUT ENDP

; ---- 子程序：把 A000 段 64000 字节转储到 DUMP.BIN ----
DUMP_VRAM PROC
    PUSH DS
    LEA DX, F_DUMP
    MOV AH, 3CH
    XOR CX, CX
    INT 21H                    ; 创建/截断
    JC  DV_FAIL
    MOV BX, AX                 ; 文件句柄
    MOV AX, 0A000H
    MOV DS, AX                 ; DS 指向显存，DX 作偏移
    XOR DX, DX
    MOV CX, 64000
    MOV AH, 40H
    INT 21H                    ; 写显存数据
    MOV AH, 3EH
    INT 21H                    ; 关闭（BX=句柄）
DV_FAIL:
    POP DS
    RET
DUMP_VRAM ENDP
ENDIF

CODE ENDS
    END START
