/*
*   This file is part of Luma3DS
*   Copyright (C) 2016-2020 Aurora Wright, TuxSH
*
*   This program is free software: you can redistribute it and/or modify
*   it under the terms of the GNU General Public License as published by
*   the Free Software Foundation, either version 3 of the License, or
*   (at your option) any later version.
*
*   This program is distributed in the hope that it will be useful,
*   but WITHOUT ANY WARRANTY; without even the implied warranty of
*   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*   GNU General Public License for more details.
*
*   You should have received a copy of the GNU General Public License
*   along with this program.  If not, see <http://www.gnu.org/licenses/>.
*
*   Additional Terms 7.b and 7.c of GPLv3 apply to this file:
*       * Requiring preservation of specified reasonable legal notices or
*         author attributions in that material or in the Appropriate Legal
*         Notices displayed by works containing it.
*       * Prohibiting misrepresentation of the origin of that material,
*         or requiring that modified versions of such material be marked in
*         reasonable ways as different from the original version.
*/

#include "arm9_exception_handlers.h"
#include "i2c.h"
#include "screen.h"

#define FINAL_BUFFER    0x25000000

#define REG_DUMP_SIZE   4 * 17
#define CODE_DUMP_SIZE  48

static inline void dumpArm9Memory(ExceptionDumpHeader *dumpHeader, u8 *buf)
{
    // Check if n3ds extra arm9 mem is enabled (if it's possible to read CFG9_EXTMEMCNT9)
    u8 extmemcnt9 = 0;
    safecpy(&extmemcnt9, (const void *)0x10000200, 1);

    u32 size = (extmemcnt9 & 1) ? 0x180000 : 0x100000;
    dumpHeader->additionalDataSize += safecpy(buf, (const void *)0x08000000, size);
}


// Debug (dead-eMMC fork): draw the register dump on screen, since the RAM dump is lost on power cycle.
// Everything here must live in ITCM (font is placed in the handler section, no rodata/libc use).
__attribute__((section(".arm9_exception_handlers.text.font")))
static const u16 dbgFont[16] = {0x7B6F, 0x2C97, 0x73E7, 0x73CF, 0x5BC9, 0x79CF, 0x79EF, 0x7249, 0x7BEF, 0x7BCF, 0x7BED, 0x6BAE, 0x7927, 0x6B6E, 0x79E7, 0x79E4};

static void dbgHex(u8 *fb, u32 x, u32 y, u32 val, u32 rgb)
{
    for(u32 d = 0; d < 8; d++)
    {
        u16 g = dbgFont[(val >> (28 - 4 * d)) & 0xF];
        for(u32 gy = 0; gy < 5; gy++)
            for(u32 gx = 0; gx < 3; gx++)
                if((g >> (14 - (gy * 3 + gx))) & 1)
                    for(u32 sy = 0; sy < 3; sy++)
                        for(u32 sx = 0; sx < 3; sx++)
                        {
                            u32 px = x + d * 12 + gx * 3 + sx;
                            u32 py = y + gy * 3 + sy;
                            u8 *p = fb + (px * 240 + (239 - py)) * 3;
                            p[0] = rgb; p[1] = rgb >> 8; p[2] = rgb >> 16;
                        }
    }
}

static void dbgDraw(u8 *fb, u32 *regs, u32 type)
{
    if((u32)fb < 0x18000000 || (u32)fb >= 0x18600000) return;
    // clear background to dark red so we can tell the dump was drawn
    for(u32 i = 0; i < 400 * 240; i++) { fb[i*3] = 0; fb[i*3+1] = 0; fb[i*3+2] = 0x40; }
    // col0: type, R0-R7 | col1: R8-R12,SP,LR,PC,CPSR | col2: 9 stack words
    dbgHex(fb, 8, 8, type, 0xFFFF00);
    for(u32 i = 0; i < 8; i++) dbgHex(fb, 8, 8 + 24 * (i + 1), regs[i], 0xFFFFFF);
    for(u32 i = 0; i < 9; i++) dbgHex(fb, 140, 8 + 24 * i, regs[8 + i], i >= 6 ? 0x00FF00 : 0xFFFFFF);
    u32 sp = regs[13];
    for(u32 i = 0; i < 9; i++)
    {
        u32 v = 0;
        safecpy(&v, (const void *)(sp + 4 * i), 4);
        dbgHex(fb, 272, 8 + 24 * i, v, 0x00FFFF);
    }
}

void __attribute__((noreturn)) arm9ExceptionHandlerMain(u32 *registerDump, u32 type)
{
    ExceptionDumpHeader dumpHeader;

    u8 codeDump[CODE_DUMP_SIZE];

    dumpHeader.magic[0] = 0xDEADC0DE;
    dumpHeader.magic[1] = 0xDEADCAFE;
    dumpHeader.versionMajor = 1;
    dumpHeader.versionMinor = 3;

    dumpHeader.processor = 9;
    dumpHeader.core = 0;
    dumpHeader.type = type;

    dumpHeader.registerDumpSize = REG_DUMP_SIZE;
    dumpHeader.codeDumpSize = CODE_DUMP_SIZE;
    dumpHeader.additionalDataSize = 0;

    u32 cpsr = registerDump[16];
    u32 pc   = registerDump[15] - (type < 3 ? (((cpsr & 0x20) != 0 && type == 1) ? 2 : 4) : 8);

    registerDump[15] = pc;

    //Dump code
    u8 *instr = (u8 *)pc + ((cpsr & 0x20) ? 2 : 4) - dumpHeader.codeDumpSize; //wouldn't work well on 32-bit Thumb instructions, but it isn't much of a problem
    dumpHeader.codeDumpSize = ((u32)instr & (((cpsr & 0x20) != 0) ? 1 : 3)) != 0 ? 0 : safecpy(codeDump, instr, dumpHeader.codeDumpSize);

    //Copy register dump and code dump
    u8 *final = (u8 *)(FINAL_BUFFER + sizeof(ExceptionDumpHeader));
    final += safecpy(final, registerDump, dumpHeader.registerDumpSize);
    final += safecpy(final, codeDump, dumpHeader.codeDumpSize);

    //Dump stack in place
    dumpHeader.stackDumpSize = safecpy(final, (const void *)registerDump[13], 0x1000 - (registerDump[13] & 0xFFF));
    final += dumpHeader.stackDumpSize;

    // See if we need to copy Arm9 memory (check for bkpt 0xFFFD / bkpt 0xFD)
    if(dumpHeader.codeDumpSize > 0)
    {
        if(cpsr & 0x20)
        {
            // Thumb
            u16 instr;
            safecpy(&instr, codeDump + dumpHeader.codeDumpSize - 2, 2);
            if(instr == 0xBEFD) dumpArm9Memory(&dumpHeader, final);
        }
        else
        {
            u32 instr;
            safecpy(&instr, codeDump + dumpHeader.codeDumpSize - 4, 4);
            if(instr == 0xE12FFF7D) dumpArm9Memory(&dumpHeader, final);
        }
    }

    dumpHeader.totalSize = sizeof(ExceptionDumpHeader) + dumpHeader.registerDumpSize + dumpHeader.codeDumpSize + dumpHeader.stackDumpSize + dumpHeader.additionalDataSize;

    //Copy header (actually optimized by the compiler)
    *(ExceptionDumpHeader *)FINAL_BUFFER = dumpHeader;

    // Debug: show registers on screen and halt instead of rebooting
    dbgDraw((u8 *)0x18300000, registerDump, type);
    dbgDraw((u8 *)0x18400000, registerDump, type);
    dbgDraw((u8 *)*(vu32 *)0x10400468, registerDump, type);
    dbgDraw((u8 *)*(vu32 *)0x10400494, registerDump, type);
    ((void (*)())0xFFFF0830)();
    while(true);

    ((void (*)())0xFFFF0830)(); //Ensure that all memory transfers have completed and that the data cache has been flushed

    I2C_writeReg(I2C_DEV_MCU, 0x20, 1 << 2); //Reboot
    while(true);
}
