@ Dead-eMMC fork: hook of Process9's SD/MMC "init device by id" entry point (0x08080ED0 on O3DS 11.17).
@ Runs from ITCM, called by P9 (same mechanism as emunandPatch). For the eMMC (id 0x101), the
@ real hardware init fails (command timeout, flag 0x200) because the chip is dead. Every NAND
@ read/write is redirected to the SD by the emuNAND patch, so we just make the init report
@ success and fix the fields Process9 uses afterwards:
@  - clear the error flags, mark the card as ready
@  - CSD C_SIZE_MULT 6 -> 7 (512 MB -> 1 GB, the dead chip reports half the size)
@  - CID = the one that decrypts this EmuNAND (chosen in patchNandInitFailure)

.section .emunand_patch, "aw", %progbits
.arm
.align 4

.global emunandBlobStart
emunandBlobStart:

.global nandInitHook
nandInitHook:
    push {r4, lr}
    mov r4, r0
    ldr r1, nandInitHookOrigFunc
    blx r1                          @ original init(id)
    ldr r1, =0x101
    cmp r4, r1
    popne {r4, pc}

    ldr r1, nandInitHookGetStruct
    mov r0, r4
    blx r1                          @ r0 = eMMC device struct
    cmp r0, #0
    beq _nandOut

    mov r1, #0
    str r1, [r0, #0x3C]             @ clear error flags
    mov r1, #1
    strb r1, [r0, #8]               @ card present/initialized
    strb r1, [r0, #9]               @ card ready flags
    strb r1, [r0, #0xA]
    mov r1, #0
    str r1, [r0, #0x48]             @ capacity info read by Process9: flags,
    str r1, [r0, #0x50]             @ sector count high word,
    mov r1, #0x200000
    str r1, [r0, #0x4C]             @ sector count = 0x200000 (1 GB, matches the NCSD image size)
    ldrb r1, [r0, #0x20]            @ CSD byte 4 (C_SIZE_MULT bit 0)
    orr r1, r1, #0x80
    strb r1, [r0, #0x20]

    ldr r1, nandInitHookCidValid
    cmp r1, #0
    beq _nandOut
    adr r1, nandInitHookCid
    add r0, r0, #0xC                @ CID field
    ldmia r1, {r1-r3, r12}
    stmia r0, {r1-r3, r12}

_nandOut:
    mov r0, #0
    pop {r4, pc}

.pool

.global nandInitHookOrigFunc, nandInitHookGetStruct, nandInitHookCidValid, nandInitHookCid
nandInitHookOrigFunc:  .word 0
nandInitHookGetStruct: .word 0
nandInitHookCidValid:  .word 0
nandInitHookCid:       .word 0, 0, 0, 0

@ ---------------------------------------------------------------------------------------------
@ TWL_FIRM (DS Mode) variant. In TWL_FIRM's Process9 the "init device by id" function is not wrapped by
@ a word-aligned 8-byte stub, so we hook the function itself: its first 8 bytes
@     push {r2-r6, lr} ; movs r6, r0 ; bl <cfg getter>
@ are replaced by "ldr r1, [pc]; bx r1; .word nandInitHookTwl". The hook performs those three
@ instructions itself, makes the function return into nandInitHookTwlAfter (by replacing the saved lr
@ in its stack frame) and then resumes the function right after the replaced bytes.
@ ---------------------------------------------------------------------------------------------
.global nandInitHookTwl
nandInitHookTwl:
    push {r12, lr}
    ldr r12, =0x8000FF              @ DIAG: purple = init(other device) called
    cmp r0, #0x100
    ldreq r12, =0xFF6000            @ DIAG: orange = init(SD card) called
    push {r1}
    ldr r1, =0x101
    cmp r0, r1
    ldreq r12, =0xFF0000            @ DIAG: red = init(eMMC) called
    pop {r1}
    bl ledMarkRaw
    pop {r12, lr}

    @ DS Mode initializes the eMMC before the SD card, and the eMMC init already reads the NAND, which we
    @ redirect to the SD card: that read hangs because the SD card isn't initialized yet. So, the first time,
    @ initialize the SD card first (through this same hooked function), then the eMMC.
    ldr r1, =0x101
    cmp r0, r1
    bne 1f
    ldr r1, nandInitHookTwlSdDone
    cmp r1, #0
    bne 1f
    mov r1, #1
    str r1, nandInitHookTwlSdDone
    push {r0, lr}
    mov r0, #0x100
    ldr r1, nandInitHookTwlSite
    blx r1                          @ init(SD card)
    pop {r0, lr}
1:
    @ While the eMMC itself is being initialized, its accesses (e.g. EXT_CSD) must reach the real eMMC,
    @ not be redirected to the SD card (that hung DS Mode).
    ldr r1, =0x101
    cmp r0, r1
    moveq r1, #1
    streq r1, twlNoRedirect
    push {r2, r3, r4, r5, r6, lr}   @ original prologue
    adr r1, nandInitHookTwlSaved
    str lr, [r1]                    @ caller's return address
    str r0, [r1, #4]                @ device id
    adr r2, nandInitHookTwlAfter
    str r2, [sp, #20]               @ the function's final "pop {..., pc}" now returns to our code
    mov r6, r0                      @ original "movs r6, r0"
    ldr r1, nandInitHookTwlCfg
    blx r1                          @ original "bl <cfg getter>"
    ldr r1, nandInitHookTwlResume
    bx r1                           @ continue the original function after the replaced bytes

.align 2
nandInitHookTwlAfter:               @ reached through the function's pop {..., pc} (ARM state)
    adr r1, nandInitHookTwlSaved
    ldr r2, [r1, #4]                @ device id
    ldr r12, =0x00FFFF              @ DIAG: cyan = init(other device) returned
    cmp r2, #0x100
    ldreq r12, =0xFFFFFF            @ DIAG: white = init(SD card) returned
    ldr r3, =0x101
    cmp r2, r3
    ldreq r12, =0x00FF00            @ DIAG: green = init(eMMC) returned
    bl ledMarkRaw
    ldr r3, [r1]                    @ caller's return address
    ldr r1, =0x101
    cmp r2, r1
    bxne r3                         @ not the eMMC: keep the original result
    mov r1, #0
    str r1, twlNoRedirect           @ eMMC init done: redirect NAND accesses to the SD card again

    push {r3, r4}
    mov r0, r2
    ldr r1, nandInitHookGetStruct
    blx r1                          @ r0 = eMMC device struct
    cmp r0, #0
    beq _nandTwlOut

    mov r1, #0
    str r1, [r0, #0x3C]
    mov r1, #1
    strb r1, [r0, #8]
    strb r1, [r0, #9]
    strb r1, [r0, #0xA]
    mov r1, #0
    str r1, [r0, #0x48]
    str r1, [r0, #0x50]
    mov r1, #0x200000
    str r1, [r0, #0x4C]
    ldrb r1, [r0, #0x20]
    orr r1, r1, #0x80
    strb r1, [r0, #0x20]

    ldr r1, nandInitHookCidValid
    cmp r1, #0
    beq _nandTwlOut
    adr r1, nandInitHookCid
    add r0, r0, #0xC
    ldmia r1, {r1-r3, r12}
    stmia r0, {r1-r3, r12}

_nandTwlOut:
    mov r0, #0
    pop {r3, r4}
    bx r3

.pool

.global nandInitHookTwlCfg, nandInitHookTwlResume, nandInitHookTwlSite
nandInitHookTwlCfg:    .word 0
nandInitHookTwlSite:   .word 0
nandInitHookTwlSdDone: .word 0
nandInitHookTwlResume: .word 0
nandInitHookTwlSaved:  .word 0, 0


@ ---------------------------------------------------------------------------------------------
@ DS Mode diagnostics: show progress on the notification LED. Uses Luma's own I2C code (still in ITCM).
@ ---------------------------------------------------------------------------------------------
.global ledI2cFunc, ledEnabled, ledCount
ledI2cFunc: .word 0
ledEnabled: .word 0
ledCount:   .word 0
ledSdCount: .word 0
twlNoRedirect: .word 0

@ r12 = 0x00RRGGBB ; preserves all registers and the flags
ledMarkRaw:
    stmfd sp!, {r0-r12, lr}
    mrs r4, cpsr
    mov r6, sp
    sub sp, sp, #112
    bic sp, sp, #7
    ldr r5, ledI2cFunc
    cmp r5, #0
    beq 9f
    ldr r0, =0x00FF0020
    str r0, [sp]
    mov r1, r12, lsr #16
    and r1, r1, #0xFF
    mov r2, r12, lsr #8
    and r2, r2, #0xFF
    and r3, r12, #0xFF
    mov r0, #0
1:
    add r7, sp, #4
    strb r1, [r7, r0]
    add r7, r7, #32
    strb r2, [r7, r0]
    add r7, r7, #32
    strb r3, [r7, r0]
    add r0, r0, #1
    cmp r0, #32
    blo 1b
    mov r0, #3                      @ I2C_DEV_MCU
    mov r1, #0x2D                   @ notification LED pattern
    mov r2, sp
    mov r3, #100
    blx r5
    ldr r0, =40000000               @ DIAG: hold each colour for about a second so none is missed
2:
    subs r0, r0, #1
    bne 2b
9:
    mov sp, r6
    msr cpsr_f, r4
    ldmfd sp!, {r0-r12, lr}
    bx lr
.pool

@ called at the start of every emuNAND read/write redirect; only active in DS Mode
.global ledRwCheck
ledRwCheck:
    push {r0, r2, r3, r12, lr}
    ldr r3, twlNoRedirect
    cmp r3, #0
    movne r1, #1
    bne 9f
    ldr r0, ledEnabled
    cmp r0, #0
    beq 8f
    cmp r1, r2
    beq 5f
    adr r3, ledCount                @ NAND (eMMC) access, redirected to the SD card
    ldr r1, [r3]
    add r1, r1, #1
    str r1, [r3]
    cmp r1, #1
    ldreq r12, =0x0000FF            @ DIAG: blue = first NAND access
    beq 7f
    cmp r1, #100
    ldreq r12, =0xFF0080            @ DIAG: pink = 100 NAND accesses
    beq 7f
    b 8f
5:
    adr r3, ledSdCount              @ direct SD card access
    ldr r1, [r3]
    add r1, r1, #1
    str r1, [r3]
    cmp r1, #1
    ldreq r12, =0xFF00FF            @ DIAG: magenta = first direct SD card access
    bne 8f
7:
    bl ledMarkRaw
8:
    mov r1, #0
9:
    pop {r0, r2, r3, r12, lr}
    bx lr
.pool

.align 2
.global emunandBlobEnd
emunandBlobEnd:
