"""
cocotb test for vec_cmd_to_desc (STEP4-E2E) — the OP_VEC_RESADD mapping plus
legacy LOAD/STORE/ACT regression. Combinational adapter: drive opcode + contract,
check the emitted vec_exec_desc_t fields against the documented mapping spec.

Run: cd tb && make MODULE=test_vec_cmd_to_desc TOPLEVEL=tb_vec_cmd_to_desc \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv ../tb/tb_vec_cmd_to_desc.sv"
"""
import os
import sys
import cocotb
from cocotb.triggers import Timer

# opcodes
OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT, OP_VEC_RESADD = 0x01, 0x02, 0x03, 0x04
# vec_primitive_e
VEC_PACK, VEC_UNPACK, VEC_RESADD, VEC_RENORM = 1, 2, 5, 6
# vec_op_class_e
VCLASS_TRANSFORM, VCLASS_ARITHMETIC, VCLASS_RENORM = 0, 1, 3
# block_size_sel_e / scale_format_e
BLOCK_SIZE_16, BLOCK_SIZE_32 = 0, 1
SCALE_E8M0, SCALE_E4M3 = 0, 1
BS_16, BS_32 = 0, 1


async def drive(dut, opcode, bs_log2=BS_32, fwd=0, epoch=0, src=0, dst=0,
                src1_resident=0, len_rows=0, sidecar_base=0):
    dut.opcode_i.value = opcode
    dut.block_size_log2_i.value = bs_log2
    dut.fwd_eligible_i.value = fwd
    dut.scale_epoch_i.value = epoch
    dut.src_row_i.value = src
    dut.dst_row_i.value = dst
    dut.src1_resident_i.value = src1_resident
    dut.len_rows_i.value = len_rows
    dut.cmd_sidecar_base_i.value = sidecar_base
    await Timer(1, "ns")


def g(dut):
    return {
        "prim": int(dut.prim_id_o.value),
        "class": int(dut.op_class_o.value),
        "block_size": int(dut.desc_block_size_o.value),
        "scale_format": int(dut.desc_scale_format_o.value),
        "fwd": int(dut.desc_fwd_eligible_o.value),
        "epoch": int(dut.desc_scale_epoch_o.value),
        "src0": int(dut.desc_src0_ref_o.value),
        "dst": int(dut.desc_dst_ref_o.value),
        "block_count": int(dut.desc_block_count_o.value),
        "sidecar_base": int(dut.desc_sidecar_base_o.value),
    }


@cocotb.test()
async def test_vec_cmd_to_desc(dut):
    fails = []

    def chk(label, got, exp):
        for k, v in exp.items():
            if got[k] != v:
                fails.append(f"{label}: {k} got={got[k]} exp={v} (full={got})")

    # ---- OP_VEC_RESADD, block16 -> NVFP4/E4M3 (D12) ----
    await drive(dut, OP_VEC_RESADD, bs_log2=BS_16, fwd=1, epoch=0xA5, src=0x12, dst=0x34)
    chk("RESADD/bs16", g(dut), {
        "prim": VEC_RESADD, "class": VCLASS_ARITHMETIC,
        "block_size": BLOCK_SIZE_16, "scale_format": SCALE_E4M3,
        "fwd": 1, "epoch": 0xA5, "src0": 0x12, "dst": 0x34})

    # ---- OP_VEC_RESADD, block32 -> OCP MX/E8M0 ----
    await drive(dut, OP_VEC_RESADD, bs_log2=BS_32, fwd=1, epoch=0x07, src=1, dst=2)
    chk("RESADD/bs32", g(dut), {
        "prim": VEC_RESADD, "class": VCLASS_ARITHMETIC,
        "block_size": BLOCK_SIZE_32, "scale_format": SCALE_E8M0,
        "fwd": 1, "epoch": 0x07})

    # ---- RESADD passes fwd_eligible through (must be honored, not forced) ----
    await drive(dut, OP_VEC_RESADD, bs_log2=BS_16, fwd=0, epoch=0)
    if g(dut)["fwd"] != 0:
        fails.append("RESADD fwd_eligible=0 not honored")

    # ---- [T3-FF/FF3b-c] streaming contract threading ----
    # Resident RESADD: block_count == len_rows, sidecar_base passes through.
    await drive(dut, OP_VEC_RESADD, bs_log2=BS_16, fwd=1, epoch=0x5A, src=0x12, dst=0x34,
                src1_resident=1, len_rows=5, sidecar_base=0x1C)
    chk("RESADD/resident/N=5", g(dut), {"block_count": 5, "sidecar_base": 0x1C})

    # Non-resident RESADD with a non-zero len_rows MUST clamp block_count to 1
    # (the outer streaming loop can never engage on a non-resident RESADD) and
    # zero the sidecar_base.
    await drive(dut, OP_VEC_RESADD, bs_log2=BS_16, fwd=1, epoch=0, src=0, dst=0,
                src1_resident=0, len_rows=5, sidecar_base=0x1C)
    chk("RESADD/non-resident/N=5->1", g(dut), {"block_count": 1, "sidecar_base": 0})

    # block32 resident streaming: block_count counts BLOCKS (= len_rows), not rows.
    await drive(dut, OP_VEC_RESADD, bs_log2=BS_32, fwd=1, epoch=0x07, src=2, dst=8,
                src1_resident=1, len_rows=3, sidecar_base=0x40)
    chk("RESADD/resident/bs32/N=3", g(dut), {"block_count": 3, "sidecar_base": 0x40})

    # Legacy LOAD with a stray len_rows must NOT leak into block_count (stays 1).
    await drive(dut, OP_VEC_LOAD, bs_log2=BS_16, fwd=1, epoch=0xFF, src=9, dst=10,
                src1_resident=1, len_rows=7, sidecar_base=0x55)
    chk("LOAD/no-stream-leak", g(dut), {"block_count": 1, "sidecar_base": 0})

    # ---- legacy regression: LOAD/STORE/ACT keep v2 safe defaults ----
    await drive(dut, OP_VEC_LOAD, bs_log2=BS_16, fwd=1, epoch=0xFF, src=9, dst=10)
    chk("LOAD", g(dut), {
        "prim": VEC_PACK, "class": VCLASS_TRANSFORM,
        "block_size": BLOCK_SIZE_32, "scale_format": SCALE_E8M0,  # forced defaults
        "fwd": 0, "epoch": 0, "src0": 9, "dst": 10})              # contract ignored

    await drive(dut, OP_VEC_STORE, bs_log2=BS_16, fwd=1, epoch=0xFF)
    chk("STORE", g(dut), {"prim": VEC_UNPACK, "class": VCLASS_TRANSFORM,
                          "block_size": BLOCK_SIZE_32, "scale_format": SCALE_E8M0, "fwd": 0})

    await drive(dut, OP_VEC_ACT, bs_log2=BS_32, fwd=1, epoch=0x11)
    chk("ACT", g(dut), {"prim": VEC_RENORM, "class": VCLASS_RENORM, "fwd": 0, "epoch": 0})

    assert not fails, "vec_cmd_to_desc mapping mismatches (%d):\n  %s" % (
        len(fails), "\n  ".join(fails))
    dut._log.info("vec_cmd_to_desc: OP_VEC_RESADD mapping + legacy regression all pass")
