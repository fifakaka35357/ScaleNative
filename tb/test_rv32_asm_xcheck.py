"""
Cross-validate the hand-rolled RV32I assembler (rv32_asm.py) against the OFFICIAL
GNU toolchain, word for word.

WHY
---
The pe_top SoC bench boots the IBEX with machine code produced by rv32_asm.py — a
~250-line assembler written in-house because no RISC-V toolchain was installed. That
is a load-bearing dependency: a bug in the ASSEMBLER looks exactly like a bug in the
DUT. "The chip didn't do what I asked" and "I encoded the instruction wrong" are
indistinguishable from the outside, and the wrong one is far easier to believe.

So this test does not trust rv32_asm.py. It assembles the SAME source with
riscv64-unknown-elf-as / ld / objcopy and demands a byte-identical image.

INSTALL (Ubuntu/Debian):
    sudo apt install binutils-riscv64-unknown-elf gcc-riscv64-unknown-elf

    # binutils alone is enough for this test (as + ld + objcopy); gcc is for the
    # future C bring-up firmware.
    riscv64-unknown-elf-as --version     # verify

If the toolchain is absent the test SKIPS (so the regression stays green on a bare
machine) but says so loudly. Once installed it is a hard gate.

Run: cd tb && make MODULE=test_rv32_asm_xcheck TOPLEVEL=tb_asm_host \
        VERILOG_SOURCES="./tb_asm_host.sv"
"""
import os
import shutil
import subprocess
import sys
import tempfile

import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32_asm import assemble
from test_pe_top import (firmware_src, build_desc,
                         OP_DMA_MEMSET, OP_DMA_EVICT, OP_DMA_FILL, OP_TENS_GEMM)

AS = "riscv64-unknown-elf-as"
LD = "riscv64-unknown-elf-ld"
OBJCOPY = "riscv64-unknown-elf-objcopy"

# Alternate prefixes some distros ship
ALT_PREFIXES = ["riscv64-unknown-elf-", "riscv32-unknown-elf-", "riscv-none-elf-",
                "riscv64-elf-", "riscv64-linux-gnu-"]


def find_toolchain():
    for p in ALT_PREFIXES:
        if shutil.which(p + "as") and shutil.which(p + "ld") and shutil.which(p + "objcopy"):
            return p
    return None


def gnu_assemble(src, base=0x80, prefix="riscv64-unknown-elf-"):
    """Assemble with the official toolchain; return a list of 32-bit words."""
    with tempfile.TemporaryDirectory() as d:
        s_path = os.path.join(d, "fw.S")
        o_path = os.path.join(d, "fw.o")
        e_path = os.path.join(d, "fw.elf")
        b_path = os.path.join(d, "fw.bin")

        # .option norelax: keep the encoding literal — linker relaxation could turn
        # our lui/addi pairs into shorter sequences and we are comparing encodings,
        # not semantics.
        with open(s_path, "w") as f:
            f.write(".option norelax\n.text\n.globl _start\n_start:\n")
            f.write(src)
            f.write("\n")

        subprocess.run([prefix + "as", "-march=rv32i", "-mabi=ilp32",
                        "-o", o_path, s_path], check=True, capture_output=True)
        subprocess.run([prefix + "ld", "-m", "elf32lriscv", f"-Ttext=0x{base:x}",
                        "--no-relax", "-o", e_path, o_path],
                       check=True, capture_output=True)
        subprocess.run([prefix + "objcopy", "-O", "binary", e_path, b_path],
                       check=True, capture_output=True)

        raw = open(b_path, "rb").read()

    assert len(raw) % 4 == 0, f"GNU image not word-aligned: {len(raw)} bytes"
    return [int.from_bytes(raw[i:i + 4], "little") for i in range(0, len(raw), 4)]


def compare(name, src, base=0x80, prefix="riscv64-unknown-elf-"):
    mine = assemble(src, base=base)
    theirs = gnu_assemble(src, base=base, prefix=prefix)

    if len(mine) != len(theirs):
        raise AssertionError(
            f"[{name}] instruction COUNT differs: rv32_asm={len(mine)} words, "
            f"GNU as={len(theirs)} words. A pseudo-instruction expanded differently.")

    diffs = [(i, m, t) for i, (m, t) in enumerate(zip(mine, theirs)) if m != t]
    if diffs:
        lines = "\n".join(
            f"  word {i:3d} @0x{base + 4*i:04x}: rv32_asm=0x{m:08x}  GNU=0x{t:08x}"
            for i, m, t in diffs[:12])
        raise AssertionError(
            f"[{name}] {len(diffs)}/{len(mine)} words differ from the official "
            f"toolchain — rv32_asm.py is WRONG and every pe_top result that depends "
            f"on it is suspect:\n{lines}")
    return len(mine)


# A corpus that covers every encoding form rv32_asm implements, not just the ones
# the firmware happens to use: U/I/S/B/J types, all the pseudo-op expansions, and the
# li corner cases (fits-in-12-bits, low-bit-11-set carry into lui, low-bits-zero).
CORPUS = """
        lui   t0, 0x12345
        auipc t1, 0x1
        li    t2, 0
        li    a0, 1
        li    a1, -1
        li    a2, 2047
        li    a3, -2048
        li    a4, 2048
        li    a5, 0x1000
        li    a6, 0xFFF
        li    a7, 0x800
        li    s2, 0x7FFFFFFF
        li    s3, 0x80000000
        li    s4, 0xDEADBEEF
        li    s5, 0xA5A51234
        addi  t0, t1, 17
        addi  t0, t1, -17
        andi  t0, t1, 0xF
        ori   t0, t1, 0x70
        xori  t0, t1, -1
        slli  t0, t1, 4
        srli  t0, t1, 31
        srai  t0, t1, 1
        add   t0, t1, t2
        sub   t0, t1, t2
        and   t0, t1, t2
        or    t0, t1, t2
        xor   t0, t1, t2
        mv    t0, t1
        nop
        sw    t1, 0(t0)
        sw    t1, 2044(t0)
        sw    t1, -2048(t0)
        sh    t1, 8(t0)
        sb    t1, 3(t0)
        lw    t2, 0(t0)
        lw    t2, 1020(t0)
        lh    t2, -4(t0)
        lhu   t2, 6(t0)
        lb    t2, 1(t0)
        lbu   t2, 2(t0)
fwd:
        beq   t0, t1, fwd
        bne   t0, t1, back
        blt   t0, t1, fwd
        bge   t0, t1, fwd
        bltu  t0, t1, fwd
        bgeu  t0, t1, fwd
        jal   ra, back
        j     back
        jalr  t0
        ebreak
        wfi
back:
        ret
"""


@cocotb.test()
async def test_rv32_asm_matches_gnu(dut):
    """rv32_asm.py must produce byte-identical machine code to riscv64-unknown-elf-as."""
    await Timer(1, units="ns")   # cocotb wants at least one await

    prefix = find_toolchain()
    if prefix is None:
        raise cocotb.result.TestSuccess(
            "SKIPPED — no RISC-V toolchain found. rv32_asm.py is therefore "
            "UNVALIDATED against an official assembler, and the pe_top SoC bench "
            "depends on it. Install with:\n"
            "    sudo apt install binutils-riscv64-unknown-elf gcc-riscv64-unknown-elf")

    total = 0
    total += compare("corpus", CORPUS, base=0x80, prefix=prefix)

    # The exact firmware the pe_top bench boots the chip with — three shapes.
    fw_cases = {
        "fw_memset_evict": firmware_src(
            [build_desc(OP_DMA_MEMSET, dst_off=0, len_rows=1, memset_val=0xA5A51234),
             build_desc(OP_DMA_EVICT, src_off=0, len_rows=1)], n_desc=2),
        "fw_2d_fill": firmware_src(
            [build_desc(OP_DMA_FILL, dst_off=4, len_rows=1, outer_count=3, stride_rows=2),
             build_desc(OP_DMA_EVICT, src_off=4, len_rows=1),
             build_desc(OP_DMA_EVICT, src_off=6, len_rows=1),
             build_desc(OP_DMA_EVICT, src_off=8, len_rows=1)], n_desc=4),
        "fw_gemm": firmware_src(
            [build_desc(OP_TENS_GEMM, src_off=0, dst_off=20, len_rows=1,
                        param_m=16, param_n=16, param_k=4),
             build_desc(OP_DMA_MEMSET, dst_off=40, len_rows=1, memset_val=0x600D600D),
             build_desc(OP_DMA_EVICT, src_off=40, len_rows=1)], n_desc=3),
        "fw_negative_control": firmware_src(
            [build_desc(OP_DMA_MEMSET, dst_off=0, len_rows=1, memset_val=0xDEAD0001),
             build_desc(OP_DMA_EVICT, src_off=0, len_rows=1)], n_desc=2,
            skip_region=True),
    }
    for name, src in fw_cases.items():
        total += compare(name, src, base=0x80, prefix=prefix)

    dut._log.info(
        "rv32_asm.py cross-validated against %sas: %d instruction words identical "
        "across the encoding corpus and all four pe_top firmware images.",
        prefix, total)
