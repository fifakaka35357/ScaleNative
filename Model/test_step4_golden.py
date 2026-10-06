#!/usr/bin/env python3
"""Self-test for the Step-4 requantizer/capsule golden (Model/bfp_golden.py).

The golden is the ORACLE the RTL requantizer / tensor_result_packer cocotb tests
check against — so it must be validated independently here (property + directed
cases) before any RTL leans on it. Run: python3 Model/test_step4_golden.py
"""
import math, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfp_golden as g

fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)
        print(f"  FAIL: {msg}")

# --- lzc48 / eff_unbiased_exp ---
check(g.lzc48(0) == 48, "lzc48(0)=48")
check(g.lzc48(1) == 47, "lzc48(1)=47")
check(g.lzc48(1 << 47) == 0, "lzc48(2^47)=0")
check(g.lzc48(1 << 39) == 8, "lzc48(2^39)=8")
# value = 2^39 * 2^-39 = 1.0 -> eff = 0
check(g.eff_unbiased_exp(1 << 39, -39) == 0, "eff(1.0)=0")
# value = 3*2^38 * 2^-37 = 6.0 = 1.5*2^2 -> eff = 2
check(g.eff_unbiased_exp(3 << 38, -37) == 2, "eff(6.0)=2")

# --- _round_shift_mag ---
check(g._round_shift_mag(0b1011, 0, g.OUT_ROUND_RTZ) == 0b1011, "shift 0 = identity")
check(g._round_shift_mag(0b1011, -2, g.OUT_ROUND_RTZ) == 0b101100, "left shift")
check(g._round_shift_mag(0b1011, 2, g.OUT_ROUND_RTZ) == 0b10, "RTZ truncates 1011>>2=10")
check(g._round_shift_mag(0b1011, 2, g.OUT_ROUND_RNE) == 0b11, "RNE 1011>>2: rem=11>half10 ->round up=11")
check(g._round_shift_mag(0b1010, 2, g.OUT_ROUND_RNE) == 0b10, "RNE tie 1010>>2: rem=10==half, q=10 even -> stay 10")
check(g._round_shift_mag(0b1110, 2, g.OUT_ROUND_RNE) == 0b100, "RNE tie 1110>>2: rem=10==half, q=11 odd -> up 100")

# --- FP4/FP8 encode round-trips (exact grid points) ---
for v in [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, -1.5, -6.0]:
    b = g.fp4_e2m1_encode(v)
    check(g.fp4_e2m1_decode(b) == v, f"fp4 round-trip {v} -> {g.fp4_e2m1_decode(b)}")
check(g.fp4_e2m1_decode(g.fp4_e2m1_encode(100.0)) == 6.0, "fp4 saturates to 6")
check(g.fp4_e2m1_decode(g.fp4_e2m1_encode(0.1, g.OUT_ROUND_RTZ)) == 0.0, "fp4 RTZ 0.1->0")
check(g.fp4_e2m1_decode(g.fp4_e2m1_encode(0.4, g.OUT_ROUND_RNE)) == 0.5, "fp4 RNE 0.4->0.5")
for v in [0.0, 1.0, 1.5, 2.0, 448.0, -448.0, 0.015625]:
    b = g.fp8_e4m3fn_encode(v)
    dec, _ = g.fp8_e4m3fn_decode(b)
    check(dec == v, f"fp8 round-trip {v} -> {dec}")
check(g.fp8_e4m3fn_decode(g.fp8_e4m3fn_encode(1e9))[0] == 448.0, "fp8 saturates to 448")

# --- requantize INT: uniform block ---
cells = [g.acc_cell(1.0) for _ in range(16)]
rq = g.requantize_block_golden(cells, 16, "INT")
check(rq["shared_exp"] == 0, f"uniform shared_exp=0 (got {rq['shared_exp']})")
check(rq["ref_exp"] == -14, f"E_block = shared-(W-2) = -14 (got {rq['ref_exp']})")
check(all(q == 16384 for q in rq["elems"]), f"uniform q=2^14=16384 (leading bit at W-2)")
check(rq["scale_byte"] == (-14 + 127), "E8M0 byte = E_block+127")
check(not rq["escape"], "uniform: no escape")
# reconstruction
for c, q in zip(cells, rq["elems"]):
    recon = q * (2.0 ** rq["ref_exp"])
    check(abs(recon - g.cell_value(c)) <= 2.0 ** rq["ref_exp"], f"INT recon within 1 ULP: {recon} vs {g.cell_value(c)}")

# --- requantize INT: max cell uses near-full W bits ---
cells = [g.acc_cell(6.0)] + [g.acc_cell(0.0)] * 15
rq = g.requantize_block_golden(cells, 16, "INT")
qmax = rq["elems"][0]
check(qmax.bit_length() == 15 - 0 and (qmax >> 14) & 1, f"max cell leading bit at W-2=14 (q={qmax}, bits={qmax.bit_length()})")

# --- requantize INT: escape boundary (spread 14 vs 15) ---
c14 = [g.acc_cell(1.0), g.acc_cell(2.0 ** -14)] + [g.acc_cell(0.0)] * 14
c15 = [g.acc_cell(1.0), g.acc_cell(2.0 ** -15)] + [g.acc_cell(0.0)] * 14
r14 = g.requantize_block_golden(c14, 16, "INT")
r15 = g.requantize_block_golden(c15, 16, "INT")
check(r14["spread"] == 14 and not r14["escape"], f"spread 14: no escape (escape={r14['escape']})")
check(r15["spread"] == 15 and r15["escape"], f"spread 15: escape (escape={r15['escape']})")
check(r14["elems"][1] == 1, f"spread14 smallest q=1 (got {r14['elems'][1]})")
check(r15["elems"][1] == 0, f"spread15 smallest q=0 underflow (got {r15['elems'][1]})")

# --- requantize INT: signs + clamp ---
cells = [g.acc_cell(-6.0), g.acc_cell(3.0)] + [g.acc_cell(0.0)] * 14
rq = g.requantize_block_golden(cells, 16, "INT")
check(rq["elems"][0] < 0 and rq["elems"][1] > 0, "sign preserved")
check(abs(rq["elems"][0]) == 2 * abs(rq["elems"][1]), f"-6 is 2x 3 in mantissa ({rq['elems'][0]} vs {rq['elems'][1]})")

# --- requantize FP4: grid-exact + block scale ---
cells = [g.acc_cell(4.0), g.acc_cell(2.0)] + [g.acc_cell(0.0)] * 14   # max=4 -> shared=2
rq = g.requantize_block_golden(cells, 4, "FP", round_mode=g.OUT_ROUND_RNE)
check(rq["shared_exp"] == 2, f"FP shared_exp=2 (got {rq['shared_exp']})")
# x0 = 4/4 = 1.0 -> fp4 1.0 ; recon 1.0*2^2 = 4
recon0 = g.fp4_e2m1_decode(rq["elems"][0]) * (2.0 ** rq["shared_exp"])
recon1 = g.fp4_e2m1_decode(rq["elems"][1]) * (2.0 ** rq["shared_exp"])
check(recon0 == 4.0, f"FP4 recon cell0=4.0 (got {recon0})")
check(recon1 == 2.0, f"FP4 recon cell1=2.0 (got {recon1})")

# --- requantize FP8: wider range ---
cells = [g.acc_cell(1.0), g.acc_cell(0.25), g.acc_cell(0.03125)] + [g.acc_cell(0.0)] * 13
rq = g.requantize_block_golden(cells, 8, "FP", round_mode=g.OUT_ROUND_RNE)
recon = [g.fp8_e4m3fn_decode(e)[0] * (2.0 ** rq["shared_exp"]) for e in rq["elems"][:3]]
check(recon[0] == 1.0 and recon[1] == 0.25, f"FP8 recon {recon[:2]}")

# --- NaN / all-zero propagation ---
rq = g.requantize_block_golden([g.acc_cell(float('nan'))] + [g.acc_cell(0.0)] * 15, 16, "INT")
check(rq["is_nan"] and rq["escape"], "NaN -> is_nan + escape")
rq = g.requantize_block_golden([g.acc_cell(0.0)] * 16, 16, "INT")
check(rq["all_zero"] and not rq["escape"], "all-zero block: all_zero, no escape")

# --- capsule_form (D2) ---
cap = g.capsule_form_golden([g.acc_cell(1.0)] * 16)
check(len(cap["payload_mants"]) == 16 and not cap["escape"], "capsule16 formed, no escape")
cap15 = g.capsule_form_golden([g.acc_cell(1.0), g.acc_cell(2.0 ** -15)] + [g.acc_cell(0.0)] * 14)
check(cap15["escape"], "capsule spread15 -> escape (Class C)")

# --- block32 dual window: independent exps ---
w0 = [g.acc_cell(256.0)] + [g.acc_cell(0.0)] * 15      # window0 big
w1 = [g.acc_cell(1.0)] + [g.acc_cell(0.0)] * 15        # window1 small
c0, c1 = g.block32_dual_window_golden(w0 + w1)
check(c0["shared_exp"] == 8 and c1["shared_exp"] == 0, f"block32 independent exps ({c0['shared_exp']},{c1['shared_exp']})")
check(c0["inline_scale"] != c1["inline_scale"], "block32 windows carry distinct inline_scale")

print(f"\n{'='*48}\nStep-4 golden self-test: {'ALL PASS' if not fails else str(len(fails))+' FAIL'}")
sys.exit(1 if fails else 0)
