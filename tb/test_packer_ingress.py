"""
cocotb contract-join test: tensor_result_packer (D2) -> vec_ingress_arb (Vector).

The single strongest Step-4 integration proof: a Tensor-formed bs_capsule_t is
ACCEPTED by the Vector fast-path ingress gate (out_valid, zero MISS) when the
descriptor (vec_ctrl_t) matches, and produces the correct fp_miss_reason_e when
block_size / scale_format / scale_epoch mismatch. Driven via tb_packer_ingress.sv.

Run: cd tb && make MODULE=test_packer_ingress TOPLEVEL=tb_packer_ingress \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Vector/vec_pkg.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ./tb_packer_ingress.sv"
"""
import os
import sys
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

BS_16, BS_32 = 0, 1
SF_E8M0, SF_E4M3 = 0, 1
MISS_NONE, MISS_BLOCK_SIZE, MISS_SCALE_FORMAT, MISS_EPOCH = 0, 1, 2, 3


async def drive(dut, cells, *, cap_bs=BS_16, cap_sf=SF_E8M0, cap_ep=0x5A, cap_fmt=8,
                ctrl_bs=BS_16, ctrl_sf=SF_E8M0, ctrl_ep=0x5A, ctrl_valid=1):
    for i in range(16):
        c = cells[i] if i < len(cells) else g.acc_cell(0.0)
        dut.cells_i[i].value = g.pack_fp_acc(c["mant48"], c["exp10"], c["sign"], c["is_nan"], c["is_inf"])
    dut.cap_block_size_i.value = cap_bs
    dut.cap_scale_format_i.value = cap_sf
    dut.cap_scale_epoch_i.value = cap_ep
    dut.cap_elem_fmt_i.value = cap_fmt
    dut.ctrl_block_size_i.value = ctrl_bs
    dut.ctrl_scale_format_i.value = ctrl_sf
    dut.ctrl_scale_epoch_i.value = ctrl_ep
    dut.ctrl_valid_i.value = ctrl_valid
    await Timer(1, "ns")
    return {
        "out_valid": int(dut.out_valid_o.value),
        "escape": int(dut.packer_escape_o.value),
        "miss_valid": int(dut.miss_valid_o.value),
        "miss_reason": int(dut.miss_reason_o.value),
    }


@cocotb.test()
async def test_contract_join(dut):
    fails = []
    row = [g.acc_cell(v) for v in
           [4.0, -2.0, 1.0, -0.5, 6.0, -6.0, 3.0, 1.5,
            2.0, -4.0, 0.5, -1.0, 1.25, -3.0, 0.25, 5.0]]   # bounded spread, no escape

    # matching descriptor -> ACCEPT, zero miss
    r = await drive(dut, row)
    if r["escape"]:
        fails.append("setup row unexpectedly escapes")
    if not r["out_valid"] or r["miss_valid"]:
        fails.append(f"match: out_valid={r['out_valid']} miss_valid={r['miss_valid']} "
                     f"reason={r['miss_reason']} (want accept, no miss)")

    # epoch mismatch -> MISS_EPOCH
    r = await drive(dut, row, ctrl_ep=0x33)
    if r["out_valid"] or not r["miss_valid"] or r["miss_reason"] != MISS_EPOCH:
        fails.append(f"epoch-mismatch: out_valid={r['out_valid']} miss={r['miss_valid']} "
                     f"reason={r['miss_reason']} (want MISS_EPOCH={MISS_EPOCH})")

    # block_size mismatch -> MISS_BLOCK_SIZE
    r = await drive(dut, row, ctrl_bs=BS_32)
    if r["out_valid"] or r["miss_reason"] != MISS_BLOCK_SIZE:
        fails.append(f"bs-mismatch: reason={r['miss_reason']} (want {MISS_BLOCK_SIZE})")

    # scale_format mismatch -> MISS_SCALE_FORMAT
    r = await drive(dut, row, ctrl_sf=SF_E4M3)
    if r["out_valid"] or r["miss_reason"] != MISS_SCALE_FORMAT:
        fails.append(f"sf-mismatch: reason={r['miss_reason']} (want {MISS_SCALE_FORMAT})")

    # no active descriptor -> no accept, no miss (capsule waits)
    r = await drive(dut, row, ctrl_valid=0)
    if r["out_valid"] or r["miss_valid"]:
        fails.append(f"ctrl_valid=0: out_valid={r['out_valid']} miss={r['miss_valid']} (want both 0)")

    # block32 + E4M3 capsule with a matching descriptor -> ACCEPT (NVFP4-on-fastpath path)
    r = await drive(dut, row, cap_bs=BS_32, cap_sf=SF_E4M3, ctrl_bs=BS_32, ctrl_sf=SF_E4M3)
    if not r["out_valid"] or r["miss_valid"]:
        fails.append(f"block32+E4M3 match: out_valid={r['out_valid']} miss={r['miss_valid']}")

    assert not fails, "contract-join mismatches (%d):\n  %s" % (len(fails), "\n  ".join(fails))
    dut._log.info("contract join: Tensor capsule accepted by Vector ingress, miss reasons correct")
