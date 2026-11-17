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
