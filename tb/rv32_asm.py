"""
rv32_asm.py — a tiny, dependency-free RV32I assembler.

There is no RISC-V toolchain on this machine, and the pe_top bench needs REAL
machine code to boot the IBEX with. Rather than hand-encoding hex (unreadable and
unreviewable), this assembles the small instruction subset the firmware needs.

Scope is deliberately minimal — exactly the instructions used by the pe_top
firmware, nothing more:

    lui/auipc, addi, add, sub, and/or/xor, andi/ori/xori, slli/srli/srai,
    sw/sh/sb, lw/lh/lhu/lb/lbu, beq/bne/blt/bge/bltu/bgeu, jal/jalr,
    nop, li (pseudo, 1-2 instr), la (pseudo), j (pseudo), ret (pseudo),
    ebreak, wfi

Labels are supported. Usage:

    from rv32_asm import assemble
    words = assemble('''
            li   t0, 0x1000
            li   t1, 42
            sw   t1, 0(t0)
    loop:   j    loop
    ''', base=0x0000_0000)
    # -> list of 32-bit ints, one per instruction word

Encoding follows the RV32I spec (unprivileged ISA v2.2). It is straightforward
enough to review by eye, which is the point: the firmware in the bench must be
trustworthy, because a bug here looks exactly like a bug in the DUT.
"""

REGS = {}
for i in range(32):
    REGS[f"x{i}"] = i
REGS.update({
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15, "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23, "s8": 24, "s9": 25,
    "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
})


def _reg(tok):
    t = tok.strip().lower()
    if t not in REGS:
        raise ValueError(f"unknown register: {tok!r}")
    return REGS[t]


def _imm(tok, labels=None, pc=None, rel=False):
    t = tok.strip()
    if labels is not None and t in labels:
        return labels[t] - pc if rel else labels[t]
    try:
        return int(t, 0)
    except ValueError:
        raise ValueError(f"cannot parse immediate/label: {tok!r}")


def _s(v, bits):
    """two's-complement fit check"""
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if not (lo <= v <= hi):
        raise ValueError(f"immediate {v} does not fit in {bits} signed bits")
    return v & ((1 << bits) - 1)


def _r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _i_type(imm, rs1, f3, rd, op):
    return (_s(imm, 12) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _s_type(imm, rs2, rs1, f3, op):
    i = _s(imm, 12)
    return (((i >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
           | ((i & 0x1F) << 7) | op


def _b_type(imm, rs2, rs1, f3, op):
    if imm & 1:
        raise ValueError("branch target must be 2-byte aligned")
    i = _s(imm, 13)
    return (((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | (rs2 << 20) \
           | (rs1 << 15) | (f3 << 12) | (((i >> 1) & 0xF) << 8) \
           | (((i >> 11) & 1) << 7) | op


def _u_type(imm, rd, op):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | op


def _j_type(imm, rd, op):
    i = _s(imm, 21)
    return (((i >> 20) & 1) << 31) | (((i >> 1) & 0x3FF) << 21) \
           | (((i >> 11) & 1) << 20) | (((i >> 12) & 0xFF) << 12) | (rd << 7) | op


# opcode / funct3 / funct7 tables
_ALU_R = {  # rd, rs1, rs2
    "add":  (0x00, 0x0), "sub": (0x20, 0x0),
    "sll":  (0x00, 0x1), "slt": (0x00, 0x2), "sltu": (0x00, 0x3),
    "xor":  (0x00, 0x4), "srl": (0x00, 0x5), "sra":  (0x20, 0x5),
    "or":   (0x00, 0x6), "and": (0x00, 0x7),
}
_ALU_I = {  # rd, rs1, imm
    "addi": 0x0, "slti": 0x2, "sltiu": 0x3, "xori": 0x4, "ori": 0x6, "andi": 0x7,
}
_SHIFT_I = {"slli": (0x00, 0x1), "srli": (0x00, 0x5), "srai": (0x20, 0x5)}
_LOAD = {"lb": 0x0, "lh": 0x1, "lw": 0x2, "lbu": 0x4, "lhu": 0x5}
_STORE = {"sb": 0x0, "sh": 0x1, "sw": 0x2}
_BRANCH = {"beq": 0x0, "bne": 0x1, "blt": 0x4, "bge": 0x5, "bltu": 0x6, "bgeu": 0x7}


def _split_mem(operand):
    """'8(t0)' -> (8, 't0')"""
    o = operand.strip()
    if "(" not in o or not o.endswith(")"):
        raise ValueError(f"bad memory operand: {operand!r}")
    off, reg = o[:-1].split("(", 1)
    return off.strip() or "0", reg.strip()


def _tokenize(line):
    line = line.split("#", 1)[0].split("//", 1)[0].strip()
    if not line:
        return None, []
    label = None
    if ":" in line:
        label, line = line.split(":", 1)
        label = label.strip()
        line = line.strip()
    if not line:
        return label, []
    parts = line.replace(",", " ").split()
    return label, parts


def _li_words(rd, val):
    """li pseudo: 1 instruction if it fits in 12 signed bits, else lui+addi."""
    val &= 0xFFFFFFFF
    sv = val - (1 << 32) if val >> 31 else val
    if -2048 <= sv <= 2047:
        return [_i_type(sv, 0, 0x0, rd, 0x13)]                    # addi rd, zero, imm
    # lui takes bits [31:12]; addi adds a SIGNED 12-bit low part, so if the low
    # part has bit 11 set we must pre-compensate the upper immediate by +1.
    lo = val & 0xFFF
    hi = (val >> 12) & 0xFFFFF
    if lo & 0x800:
        hi = (hi + 1) & 0xFFFFF
        lo_s = lo - 0x1000
    else:
        lo_s = lo
    out = [_u_type(hi, rd, 0x37)]                                  # lui rd, hi
    if lo_s != 0:
        out.append(_i_type(lo_s, rd, 0x0, rd, 0x13))              # addi rd, rd, lo
    return out


def _pseudo_size(op, args):
    """How many words a (possibly pseudo) instruction takes — needed for pass 1."""
    if op == "li":
        val = int(args[1], 0) & 0xFFFFFFFF
        sv = val - (1 << 32) if val >> 31 else val
        return 1 if -2048 <= sv <= 2047 else (1 if (val & 0xFFF) == 0 else 2)
    if op == "la":
        return 2      # always lui+addi (label value not known in pass 1)
    if op == "nop":
        return 1
    return 1


def assemble(src, base=0):
    """Assemble `src` (multi-line string). Returns a list of 32-bit words."""
    lines = [_tokenize(l) for l in src.splitlines()]

    # ---- pass 1: label addresses ----
    labels = {}
    pc = base
    for label, parts in lines:
        if label:
            if label in labels:
                raise ValueError(f"duplicate label: {label}")
            labels[label] = pc
        if parts:
            pc += 4 * _pseudo_size(parts[0].lower(), parts[1:])

    # ---- pass 2: encode ----
    words = []
    pc = base
    for label, parts in lines:
        if not parts:
            continue
        op, args = parts[0].lower(), parts[1:]

        if op == "nop":
            words.append(_i_type(0, 0, 0x0, 0, 0x13)); pc += 4

        elif op == "li":
            ws = _li_words(_reg(args[0]), _imm(args[1]))
            words += ws; pc += 4 * len(ws)

        elif op == "la":
            rd = _reg(args[0])
            val = _imm(args[1], labels, pc)
            # always 2 words (size reserved in pass 1) — force lui+addi
            lo = val & 0xFFF
            hi = (val >> 12) & 0xFFFFF
            if lo & 0x800:
                hi = (hi + 1) & 0xFFFFF
                lo_s = lo - 0x1000
            else:
                lo_s = lo
            words.append(_u_type(hi, rd, 0x37))
            words.append(_i_type(lo_s, rd, 0x0, rd, 0x13))
            pc += 8

        elif op == "j":
            words.append(_j_type(_imm(args[0], labels, pc, rel=True), 0, 0x6F)); pc += 4

        elif op == "jal":
            if len(args) == 1:
                words.append(_j_type(_imm(args[0], labels, pc, rel=True), 1, 0x6F))
            else:
                words.append(_j_type(_imm(args[1], labels, pc, rel=True), _reg(args[0]), 0x6F))
            pc += 4

        elif op == "jalr":
            if len(args) == 1:
                words.append(_i_type(0, _reg(args[0]), 0x0, 1, 0x67))
            else:
                off, rs1 = _split_mem(args[1]) if "(" in args[1] else (args[2], args[1])
                words.append(_i_type(_imm(off), _reg(rs1), 0x0, _reg(args[0]), 0x67))
            pc += 4

        elif op == "ret":
            words.append(_i_type(0, 1, 0x0, 0, 0x67)); pc += 4      # jalr zero, 0(ra)

        elif op in _ALU_R:
            f7, f3 = _ALU_R[op]
            words.append(_r_type(f7, _reg(args[2]), _reg(args[1]), f3, _reg(args[0]), 0x33))
            pc += 4

        elif op in _ALU_I:
            words.append(_i_type(_imm(args[2]), _reg(args[1]), _ALU_I[op], _reg(args[0]), 0x13))
            pc += 4

        elif op == "mv":
            words.append(_i_type(0, _reg(args[1]), 0x0, _reg(args[0]), 0x13)); pc += 4

        elif op in _SHIFT_I:
            f7, f3 = _SHIFT_I[op]
            sh = _imm(args[2]) & 0x1F
            words.append(_i_type((f7 << 5) | sh, _reg(args[1]), f3, _reg(args[0]), 0x13))
            pc += 4

        elif op in _LOAD:
            off, rs1 = _split_mem(args[1])
            words.append(_i_type(_imm(off), _reg(rs1), _LOAD[op], _reg(args[0]), 0x03))
            pc += 4

        elif op in _STORE:
            off, rs1 = _split_mem(args[1])
            words.append(_s_type(_imm(off), _reg(args[0]), _reg(rs1), _STORE[op], 0x23))
            pc += 4

        elif op in _BRANCH:
            words.append(_b_type(_imm(args[2], labels, pc, rel=True),
                                 _reg(args[1]), _reg(args[0]), _BRANCH[op], 0x63))
            pc += 4

        elif op == "lui":
            words.append(_u_type(_imm(args[1]), _reg(args[0]), 0x37)); pc += 4

        elif op == "auipc":
            words.append(_u_type(_imm(args[1]), _reg(args[0]), 0x17)); pc += 4

        elif op == "ebreak":
            words.append(0x00100073); pc += 4

        elif op == "wfi":
            words.append(0x10500073); pc += 4

        else:
            raise ValueError(f"unsupported instruction: {op!r} (line: {parts})")

    return words


if __name__ == "__main__":
    # self-check against known-good encodings
    prog = assemble("""
        li   t0, 0x20000000
        li   t1, 1
        sw   t1, 0(t0)
        lw   t2, 0(t0)
    spin: beq  t2, t1, spin
        j    spin
    """)
    for i, w in enumerate(prog):
        print(f"{i*4:04x}: {w:08x}")
    # lui t0, 0x20000 ; addi is skipped (low bits zero) -> 0x200002b7
    assert prog[0] == 0x200002B7, hex(prog[0])
    assert prog[1] == 0x00100313, hex(prog[1])   # addi t1, zero, 1
    assert prog[2] == 0x0062A023, hex(prog[2])   # sw t1, 0(t0)
    assert prog[3] == 0x0002A383, hex(prog[3])   # lw t2, 0(t0)
    print("rv32_asm self-check OK")
