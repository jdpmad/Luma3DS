@ Debug (dead-eMMC fork): replacement for Process9's generic "init device if needed" wrapper
@ (0x08060A46 on O3DS 11.17). Runs from ITCM, called by P9 (like emunandPatch).
@ Behaviour = the NOP workaround (failures are ignored and the device is marked initialized),
@ but calls and failures are logged so the exception handler can include them in the dump.
@ Log (ARM9-only RAM, bottom of P9's main stack area, never touched by the ARM11):
@   +0 magic 'DBG1', +4 number of calls, +8 number of failures,
@   +0xC: up to 15 entries of 16 bytes: error code, device object, vtable, caller return address

.set DBG_LOG, 0x080FF000

.section .emunand_patch, "aw", %progbits
.arm
.align 4

.global dbgInitWrapperHook
dbgInitWrapperHook:
    push {r4, lr}
    mov r4, r0

    ldr r1, =DBG_LOG
    ldr r2, [r1, #4]
    add r2, r2, #1
    str r2, [r1, #4]            @ calls++

    ldr r1, [r4]
    ldr r1, [r1, #0x18]         @ isInitialized()
    mov r0, r4
    blx r1
    cmp r0, #0
    movne r0, #0
    popne {r4, pc}

    ldr r0, [r4]
    ldr r1, [r0, #0x1C]         @ init()
    mov r0, r4
    blx r1
    cmp r0, #0
    bge _dbgOk

    @ log the failure
    ldr r1, =DBG_LOG
    ldr r2, [r1, #8]
    cmp r2, #15
    bhs _dbgOk
    add r3, r1, #0xC
    add r3, r3, r2, lsl #4
    str r0, [r3]                @ error code
    str r4, [r3, #4]            @ device object
    ldr r0, [r4]
    str r0, [r3, #8]            @ vtable
    ldr r0, [sp, #4]
    str r0, [r3, #12]           @ caller return address
    add r2, r2, #1
    str r2, [r1, #8]

_dbgOk:
    mov r0, #1
    strb r0, [r4, #0xC]
    mov r0, #0
    pop {r4, pc}

.pool
