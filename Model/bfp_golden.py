"""
bfp_golden.py — Bit-accurate golden reference for the H-Tensor block-float datapath.

Encodes the FROZEN numeric convention (decision C07): a block-float value is
    value = mant * 2^exp      (mant an integer; no hidden per-mode scale)
and the per-mode element formats (FP4 E2M1 / FP8 E4M3FN, with subnormals — the
CORRECT behavior, against which RTL bugs C06/C07/D4/E1 are measured).

This module is the oracle for the cocotb regressions in ../tb/.
Pure Python + numpy-free (uses math) for portability.
"""
import math

# ---- tensor_mode_e encodings (tensor_pkg.sv) ----
MODE_UINT4_SIMD = 0
MODE_UINT8      = 1
MODE_FP4        = 2
MODE_FP8        = 3
MODE_BF16       = 4
MODE_MXFP4      = 5
MODE_MXFP8      = 6
MODE_MXINT8     = 7

FP4_MODES = (MODE_FP4, MODE_MXFP4)
FP8_MODES = (MODE_FP8, MODE_MXFP8)

# ---- out_fmt_e / out_round_e encodings (tensor_pkg.sv) ----
OUT_FMT_BF16 = 0
OUT_FMT_FP16 = 1
OUT_FMT_FP8  = 2
OUT_FMT_FP32 = 3
OUT_ROUND_RTZ = 0
OUT_ROUND_RNE = 1

# ---- scale_fmt_e / scale_format_e encodings (tensor_pkg.sv / pe_pkg.sv) ----
SCALE_E8M0 = 0   # OCP MX: pure 8-bit exponent, bias 127
SCALE_E4M3 = 1   # NVFP4: FP8-like block scale {exp[3:0], mant[2:0]}, bias 7


def signed(x, bits):
    """Interpret unsigned `x` (width `bits`) as two's-complement signed."""
    x &= (1 << bits) - 1
    return x - (1 << bits) if (x >> (bits - 1)) & 1 else x


# ---------------------------------------------------------------------------
# Element decoders (real value, WITH subnormals — the correct behavior)
# ---------------------------------------------------------------------------
def fp4_e2m1_decode(bits):
    """FP4 E2M1: {sign[3], exp[2:1], frac[0]}, bias=1.  Magnitudes: {0,0.5,1,1.5,2,3,4,6}."""
    bits &= 0xF
    s = (bits >> 3) & 1
    e = (bits >> 1) & 0b11
    f = bits & 1
    if e == 0:
        mag = (f * 0.5)                       # subnormal: 0 or 0.5 (the single subnormal)
    else:
        mag = (1.0 + 0.5 * f) * (2.0 ** (e - 1))
    return -mag if s else mag


def fp8_e4m3fn_decode(bits):
    """FP8 E4M3FN: {sign[7], exp[6:3], frac[2:0]}, bias=7.  Returns (value, is_nan)."""
    bits &= 0xFF
    s = (bits >> 7) & 1
    e = (bits >> 3) & 0xF
    f = bits & 0b111
    if e == 0xF and f == 0b111:
        return (math.nan, True)               # E4M3FN single NaN encoding
    if e == 0:
        mag = (f / 8.0) * (2.0 ** (1 - 7))    # subnormal
    else:
        mag = (1.0 + f / 8.0) * (2.0 ** (e - 7))
    return (-mag if s else mag, False)


# ---------------------------------------------------------------------------
# mac_lru golden — reduces lane products to a single real value
# ---------------------------------------------------------------------------
def mac_lru_golden(mode, fp4_a, fp4_b, fp8_a, fp8_b):
    """Returns dict {value, is_nan, all_zero}: what mac_lru should output (infinite precision)."""
    if mode in FP4_MODES:
        total, any_nonzero = 0.0, False
        for i in range(4):
            va, vb = fp4_e2m1_decode(fp4_a[i]), fp4_e2m1_decode(fp4_b[i])
            total += va * vb
            if va != 0.0 and vb != 0.0:
                any_nonzero = True
        return {"value": total, "is_nan": False, "all_zero": not any_nonzero}
    if mode in FP8_MODES:
        total, any_nonzero, nan = 0.0, False, False
        for i in range(2):
            va, na = fp8_e4m3fn_decode(fp8_a[i])
            vb, nb = fp8_e4m3fn_decode(fp8_b[i])
            if na or nb:
                nan = True
                continue
            total += va * vb
            if va != 0.0 and vb != 0.0:
                any_nonzero = True
        return {"value": total, "is_nan": nan, "all_zero": (not any_nonzero) and not nan}
    return {"value": 0.0, "is_nan": False, "all_zero": True}


# ---------------------------------------------------------------------------
# RTL output decoders (interpret packed struct bits → real value)
# ---------------------------------------------------------------------------
# mac_lru OUTPUT scale offset F: value = mant * 2^(exp - F).
# C07 LANDED: mac_lru now source-rebiases lru_out.exp (FP4 -6, FP8 -10) so the
# frozen convention value = mant * 2^exp holds (F = 0 for every mode). Before
# C07 this returned {FP4:6, FP8:10}; the RTL exp shifted by -F in lockstep.
def lru_out_F(mode):
    return 0


def decode_lru_out(raw, mode):
    """raw = 29-bit lru_result_t. Layout (packed, MSB first):
       mant[28:14] (15b signed) | exp[13:4] (10b signed) | zero[3] | is_nan[2] | is_inf[1] | inf_sign[0]."""
    mant = signed((raw >> 14) & 0x7FFF, 15)
    exp = signed((raw >> 4) & 0x3FF, 10)
    zero = (raw >> 3) & 1
    is_nan = (raw >> 2) & 1
    F = lru_out_F(mode)
    return {"value": float(mant) * (2.0 ** (exp - F)),
            "mant": mant, "exp": exp, "zero": zero, "is_nan": is_nan}


# mac_fp_accumulator OUTPUT scale offset F: value = (sign?-1:1) * |mant| * 2^(exp - F).
# C07 LANDED: every source (mac_lru FP4 -6 / FP8 -10, mac_cell BF16 -14, MXINT8
# already 0) rebiases its product exponent, so the accumulator output obeys the
# frozen convention value = mant * 2^exp (F = 0 for all modes). The OFU consumes
# this as a 48-bit integer mantissa (leading 1 at bit 47-lzc) → IEEE unbiased
# exponent = exp + (47 - lzc).
def acc_out_F(mode):
    return 0


def decode_fp_acc_out(raw, mode):
    """raw = 61-bit fp_acc_output_t. Layout (packed, MSB first):
       mant[60:13] (48b unsigned |mant|) | exp[12:3] (10b signed) | sign[2] | is_nan[1] | is_inf[0]."""
    mant = (raw >> 13) & ((1 << 48) - 1)
    exp = signed((raw >> 3) & 0x3FF, 10)
    sign = (raw >> 2) & 1
    is_nan = (raw >> 1) & 1
    is_inf = raw & 1
    F = acc_out_F(mode)
    mag = float(mant) * (2.0 ** (exp - F))
    return {"value": (-mag if sign else mag), "mant": mant, "exp": exp,
            "sign": sign, "is_nan": is_nan, "is_inf": is_inf}


# ---------------------------------------------------------------------------
# MX block-scale MAC golden — single accumulation after a clear
# ---------------------------------------------------------------------------
def e8m0_decode(byte):
    """E8M0 block scale (OCP MX): value = 2^(byte-127); byte=0xFF = NaN. Returns (scale, is_nan)."""
    byte &= 0xFF
    if byte == 0xFF:
        return (math.nan, True)
    return (2.0 ** (byte - 127), False)


def mxint8_decode(byte):
    """MXINT8 element: signed INT8 with implicit 2^-6 scale → real value q*2^-6 (OCP MX Table 6)."""
    return signed(byte & 0xFF, 8) * (2.0 ** -6)


def e4m3_scale_decode(byte):
    """E4M3 block scale (NVFP4), NORMAL scales only (E1 scope): {exp[6:3], mant[2:0]},
    bias 7. value = (1 + m3/8) * 2^(exp-7). Returns (scale, is_nan)."""
    byte &= 0xFF
    e = (byte >> 3) & 0xF
    m = byte & 0x7
    if (byte & 0x7F) == 0x7F:               # exp=1111, mant=111 → NaN
        return (math.nan, True)
    if e == 0:                              # subnormal (out of E1 scope; modelled for completeness)
        return ((m / 8.0) * (2.0 ** (1 - 7)), False)
    return ((1.0 + m / 8.0) * (2.0 ** (e - 7)), False)


def mac_cell_mx_golden(mode, weight, act, scale_a, scale_b, scale_format=SCALE_E8M0):
    """Golden for ONE MX MAC accumulation after a clear (the accumulator adopts the product).

    weight/act : 16-bit packed operands (FP4 ×4 nibbles, FP8 ×2 bytes, or INT8 in [7:0]).
    scale_a    : E8M0 block scale byte for operand A (weight).
    scale_b    : E8M0 block scale byte for operand B (activation).

    scale_format : SCALE_E8M0 (C06: 2^(s-127), two biases → -254) or
                   SCALE_E4M3 (E1, NVFP4: (1+m3/8)*2^(exp-7) — scale has a mantissa).
    The per-element dot product is multiplied by the combined block scale
    decode(scale_a) * decode(scale_b)."""
    if scale_format == SCALE_E4M3:
        sa, sa_nan = e4m3_scale_decode(scale_a)
        sb, sb_nan = e4m3_scale_decode(scale_b)
    else:
        sa, sa_nan = e8m0_decode(scale_a)
        sb, sb_nan = e8m0_decode(scale_b)
    scale_nan = sa_nan or sb_nan
    if mode == MODE_MXFP4:
        a = [(weight >> (4 * i)) & 0xF for i in range(4)]
        b = [(act    >> (4 * i)) & 0xF for i in range(4)]
        lru = mac_lru_golden(MODE_MXFP4, a, b, [0, 0], [0, 0])
        val, is_nan = lru["value"], lru["is_nan"]
    elif mode == MODE_MXFP8:
        a = [(weight >> (8 * i)) & 0xFF for i in range(2)]
        b = [(act    >> (8 * i)) & 0xFF for i in range(2)]
        lru = mac_lru_golden(MODE_MXFP8, [0, 0, 0, 0], [0, 0, 0, 0], a, b)
        val, is_nan = lru["value"], lru["is_nan"]
    elif mode == MODE_MXINT8:
        val = mxint8_decode(weight & 0xFF) * mxint8_decode(act & 0xFF)
        is_nan = False
    else:
        raise ValueError(f"mac_cell_mx_golden: unsupported mode {mode}")
    if scale_nan or is_nan:
        return {"value": math.nan, "is_nan": True}
    return {"value": val * sa * sb, "is_nan": False}


# ---------------------------------------------------------------------------
# Output Format Unit (C07) — pack/decode helpers and golden value
# ---------------------------------------------------------------------------
def pack_fp_acc(mant, exp, sign=0, is_nan=0, is_inf=0):
    """Build a 61-bit fp_acc_output_t. `mant` is the 48-bit unsigned |mantissa|,
    `exp` a signed 10-bit exponent. Frozen convention: value = (-1)^sign * mant * 2^exp."""
    return (((mant & ((1 << 48) - 1)) << 13)
            | ((exp & 0x3FF) << 3)
            | ((sign & 1) << 2)
            | ((is_nan & 1) << 1)
            | (is_inf & 1))


def _decode_ieee(bits, ew, mw, bias):
    """Decode a packed IEEE-style float → (value, is_nan, is_inf)."""
    s = (bits >> (ew + mw)) & 1
    e = (bits >> mw) & ((1 << ew) - 1)
    f = bits & ((1 << mw) - 1)
    if e == (1 << ew) - 1:                      # all-ones exponent
        if f == 0:
            return (-math.inf if s else math.inf, False, True)
        return (math.nan, True, False)
    if e == 0:
        mag = (f / float(1 << mw)) * (2.0 ** (1 - bias))     # subnormal / zero
    else:
        mag = (1.0 + f / float(1 << mw)) * (2.0 ** (e - bias))
    return (-mag if s else mag, False, False)


def decode_target_fp(bits, fmt):
    """Decode a packed OFU result (right-aligned in `bits`) for out_fmt_e `fmt`
    → (value, is_nan, is_inf)."""
    if fmt == OUT_FMT_BF16:
        return _decode_ieee(bits & 0xFFFF, 8, 7, 127)
    if fmt == OUT_FMT_FP16:
        return _decode_ieee(bits & 0xFFFF, 5, 10, 15)
    if fmt == OUT_FMT_FP8:                       # E4M3FN (no Inf; saturates to ±448)
        v, nan = fp8_e4m3fn_decode(bits & 0xFF)
        return (v, nan, False)
    return _decode_ieee(bits & 0xFFFFFFFF, 8, 23, 127)   # FP32


# ---- BF16 operand construction (for MODE_BF16 MAC driving) ----
def bf16_bits(value):
    """Encode an exactly-representable BF16 value → 16-bit {s,e8,m7}. Asserts exactness."""
    if value == 0.0:
        return 0
    s = 1 if value < 0 else 0
    m = abs(value)
    e = 0
    while m >= 2.0:
        m /= 2.0; e += 1
    while m < 1.0:
        m *= 2.0; e -= 1
    frac = m - 1.0
    f7 = round(frac * 128)
    assert abs(frac * 128 - f7) < 1e-9, f"{value} not exactly BF16-representable"
    biased = e + 127
    assert 1 <= biased <= 254, f"{value} BF16 exponent out of range"
    return (s << 15) | (biased << 7) | (f7 & 0x7F)


def bf16_decode(bits):
    """Decode a 16-bit BF16 value → float."""
    return _decode_ieee(bits & 0xFFFF, 8, 7, 127)[0]


# ---------------------------------------------------------------------------
# Tensor OS-GEMM golden (HW-REVIEW TIER-1) — exact dense GEMM oracle
# ---------------------------------------------------------------------------
# Independent oracle for the 16x16 output-stationary array re-wire. The array
# computes C[r][c] = sum_k A[r][k]*B[k][c] into each cell's block-float
# accumulator (fp_acc_output_t), captured into the snapshot bank. With operands
# chosen exactly-BF16-representable AND small (so every per-cycle BF16 product
# and the 48-bit block-float partial sum are EXACT — no rounding), the snapshot
# decoded by decode_fp_acc_out() must equal C[r][c] EXACTLY.
#
# Operand SRAM layout convention (must match the driver + the array boundary):
#   act  SRAM row k = [A[0][k], A[1][k], ..., A[ROWS-1][k]]  (lane index = output row r)
#   wgt  SRAM row k = [B[k][0], B[k][1], ..., B[k][COLS-1]]  (lane index = output col c)
# i.e. act lane r at contraction index k = A[r][k]; wgt lane c at index k = B[k][c].
def gemm_bf16_golden(A, B):
    """Exact dense GEMM C = A @ B for BF16-exact integer-ish operands.

    A : ROWS x K  (A[r][k])      B : K x COLS  (B[k][c])
    Returns C : ROWS x COLS of Python floats (== exact for BF16-exact small inputs).

    Each operand is round-tripped through bf16_bits()/bf16_decode() so the helper
    ASSERTS the chosen operands are exactly BF16-representable (the array's product
    path is only bit-exact for representable operands). Keep |operands| small (e.g.
    in [-8, 8]) so products and partial sums never exceed the exact-integer range.
    """
    R = len(A)
    K = len(A[0])
    Cn = len(B[0])
    assert len(B) == K, f"gemm_bf16_golden: inner dims mismatch (A K={K}, B rows={len(B)})"
    C = [[0.0] * Cn for _ in range(R)]
    for r in range(R):
        assert len(A[r]) == K, "gemm_bf16_golden: ragged A"
        for c in range(Cn):
            acc = 0.0
            for k in range(K):
                a = bf16_decode(bf16_bits(float(A[r][k])))   # asserts BF16-exact
                b = bf16_decode(bf16_bits(float(B[k][c])))
                acc += a * b
            C[r][c] = acc
    return C


# ---------------------------------------------------------------------------
# Vector vec_scale_adapter (C11) — golden + vec_internal_scale_t decode
# ---------------------------------------------------------------------------
def decode_vec_internal_scale(raw):
    """raw = 20-bit vec_internal_scale_t. Layout (packed, MSB first):
       exp_adj[19:10] (10b signed) | mant_corr[9:2] (8b) | special_nan[1] | special_zero[0]."""
    return {"exp_adj":      signed((raw >> 10) & 0x3FF, 10),
            "mant_corr":    (raw >> 2) & 0xFF,
            "special_nan":  (raw >> 1) & 1,
            "special_zero": raw & 1}


def vec_scale_adapter_golden(raw, scale_format, scale_inline_valid, valid):
    """Golden for vec_scale_adapter. Returns {exp_adj, mant_corr, special_nan,
    special_zero, error, valid_o}. Mirrors VEC_README §3.6/§5.6."""
    out = {"exp_adj": 0, "mant_corr": 128, "special_nan": 0,
           "special_zero": 0, "error": 0, "valid_o": 1 if valid else 0}
    if not valid or not scale_inline_valid:
        return out                                   # quiet identity, no error
    raw &= 0xFF
    if scale_format == SCALE_E8M0:
        if raw == 0xFF:
            out["special_nan"] = 1; out["error"] = 1
        else:
            out["exp_adj"] = raw - 127; out["mant_corr"] = 128
    elif scale_format == SCALE_E4M3:
        e4 = (raw >> 3) & 0xF
        m3 = raw & 0x7
        if (raw & 0x7F) == 0x7F:
            out["special_nan"] = 1; out["error"] = 1
        elif e4 == 0:
            out["special_zero"] = 1; out["mant_corr"] = 128
        else:
            out["exp_adj"] = e4 - 7
            out["mant_corr"] = (8 + m3) << 4          # {1,m3,0000} = (1+m3/8)*128
    else:
        out["error"] = 1                              # unsupported format
    return out


# ===========================================================================
# Step 4 — Fast-path requantizer (D9) + capsule formation (D2) golden
# ===========================================================================
#
# FROZEN block-float output convention for the fast-path capsule / compact MX:
#
#   A block of N block-float cells (each a decoded fp_acc_output_t,
#   value_i = (-1)^sign * mant48 * 2^exp10) is narrowed to:
#     - INT kind:  N signed two's-complement mantissas q_i of width W
#                  (target_mant_w) + one shared block exponent E_block, with
#                       value_i ~= q_i * 2^E_block.
#                  E_block = shared_exp - (W-2), shared_exp = max over nonzero
#                  cells of eff_unbiased_exp. (Max cell's leading magnitude bit
#                  lands at W-2, leaving the sign bit — full-scale use of W bits.)
#     - FP  kind:  N FP elements (FP4 E2M1 for W=4, FP8 E4M3FN for W=8), each
#                  re-encoded from value_i / 2^shared_exp, + one shared scale,
#                       value_i ~= fpdecode(elem_i) * 2^shared_exp.
#
#   Shared block scale carried as an E8M0 byte (= ref_exp + 127) by default
#   (OCP MX); SCALE_E4M3 (NVFP4) carries it as an E4M3 byte instead.
#     - INT: ref_exp = E_block ;  FP: ref_exp = shared_exp.
#
#   ESCAPE (D2 escape valve): set when any NONZERO input cell quantizes to a
#   zero output mantissa/element (catastrophic underflow). For INT-W this is
#   exactly exp-spread > (W-2) (e.g. >14 for the W=16 Vector fast-path lane).
#
# This is the oracle for the RTL `requantizer` (leaf) and `tensor_result_packer`
# (16-lane row) cocotb tests. See Review/Step4_FastPath_Plan.md §3-§5.
# ---------------------------------------------------------------------------

def lzc48(m):
    """Leading-zero count of a 48-bit magnitude (0..48; 48 for zero)."""
    m &= (1 << 48) - 1
    if m == 0:
        return 48
    n = 0
    for b in range(47, -1, -1):
        if (m >> b) & 1:
            break
        n += 1
    return n


def eff_unbiased_exp(mant48, exp10):
    """Position of the leading 1 as a power of 2: exp + (47 - lzc48(mant)).
    value = mant48 * 2^exp = 1.frac * 2^eff. Caller must guard mant48 != 0."""
    return exp10 + (47 - lzc48(mant48))


def _round_shift_mag(mag, sh, round_mode):
    """Scale a non-negative integer magnitude by 2^-sh with rounding.
    sh > 0 : right shift by sh (drop low bits) with RTZ(truncate) or RNE.
    sh <= 0: left shift by -sh (exact).  Returns the rounded magnitude (int)."""
    if sh <= 0:
        return mag << (-sh)
    q = mag >> sh
    if round_mode == OUT_ROUND_RNE:
        rem = mag & ((1 << sh) - 1)
        half = 1 << (sh - 1)
        if rem > half or (rem == half and (q & 1)):
            q += 1
    return q   # RTZ: plain truncation


# ---- FP element ENCODE (value -> nearest packed bits) for the MXFP path ----
def _fp_grid(decode_fn, nbits, tuple_decode=False):
    """Build sorted [(magnitude, pattern)] for all sign=0 patterns, excluding NaN."""
    grid = []
    for pat in range(1 << (nbits - 1)):     # sign bit = 0
        v = decode_fn(pat)
        if tuple_decode:
            v, is_nan = v
            if is_nan:
                continue
        grid.append((float(v), pat))
    grid.sort()
    return grid


_FP4_GRID = _fp_grid(fp4_e2m1_decode, 4)
_FP8_GRID = _fp_grid(fp8_e4m3fn_decode, 8, tuple_decode=True)


def _encode_fp(value, grid, sign_bit_pos, round_mode):
    """Encode `value` to the nearest pattern on `grid` (mag ascending). Ties->even
    pattern LSB for RNE; toward-zero (floor magnitude) for RTZ. Returns packed bits."""
    s = 1 if value < 0 else 0
    mag = abs(float(value))
    max_mag = grid[-1][0]
    if mag >= max_mag:                      # saturate
        pat = grid[-1][1]
    else:
        # lo = largest grid mag <= mag ; hi = smallest grid mag >= mag
        # (lo == hi when mag is exactly a grid point)
        lo = grid[0]
        hi = grid[-1]
        for gm, gp in grid:
            if gm <= mag:
                lo = (gm, gp)
        for gm, gp in reversed(grid):
            if gm >= mag:
                hi = (gm, gp)
        if round_mode == OUT_ROUND_RNE:
            dlo, dhi = mag - lo[0], hi[0] - mag
            if dlo < dhi:
                pat = lo[1]
            elif dhi < dlo:
                pat = hi[1]
            else:                            # tie -> even pattern LSB (mantissa bit)
                pat = lo[1] if (lo[1] & 1) == 0 else hi[1]
        else:                                # RTZ: floor magnitude
            pat = lo[1]
    return pat | (s << sign_bit_pos)


def fp4_e2m1_encode(value, round_mode=OUT_ROUND_RNE):
    """Encode a real value -> nearest FP4 E2M1 4-bit pattern."""
    return _encode_fp(value, _FP4_GRID, 3, round_mode)


def fp8_e4m3fn_encode(value, round_mode=OUT_ROUND_RNE):
    """Encode a real value -> nearest FP8 E4M3FN 8-bit pattern (no Inf; saturates ±448)."""
    return _encode_fp(value, _FP8_GRID, 7, round_mode)


# ---- Cell helpers (decoded fp_acc_output_t form) ----
def acc_cell(value, mant_bits=40):
    """Build a block-float cell dict {mant48, exp10, sign, is_nan, is_inf} that
    represents `value` with up to mant_bits of mantissa precision (for tests).
    Normalizes the leading 1 toward bit 47 then drops to mant_bits significance."""
    if value == 0 or (isinstance(value, float) and math.isnan(value)):
        return {"mant48": 0, "exp10": 0, "sign": (1 if (isinstance(value, float) and math.copysign(1, value) < 0) else 0),
                "is_nan": 1 if (isinstance(value, float) and math.isnan(value)) else 0, "is_inf": 0}
    sign = 1 if value < 0 else 0
    mag = abs(float(value))
    e = 0
    while mag >= 2.0:
        mag /= 2.0; e += 1
    while mag < 1.0:
        mag *= 2.0; e -= 1
    # mag in [1,2): put (mant_bits) significant bits, leading 1 at bit (mant_bits-1)
    mant = int(round(mag * (1 << (mant_bits - 1))))
    exp10 = e - (mant_bits - 1)
    # normalize into 48-bit field with leading 1 toward MSB is NOT required; the
    # convention only needs value = mant*2^exp. Keep mant within 48 bits.
    return {"mant48": mant & ((1 << 48) - 1), "exp10": exp10, "sign": sign,
            "is_nan": 0, "is_inf": 0}


def cell_value(c):
    """Real value of a block-float cell dict."""
    if c["is_nan"]:
        return math.nan
    if c["is_inf"]:
        return (-math.inf if c["sign"] else math.inf)
    mag = float(c["mant48"]) * (2.0 ** c["exp10"])
    return -mag if c["sign"] else mag


def block_shared_exp(cells):
    """Return (shared_exp, min_exp, n_nonzero, any_nan, any_inf) over the block.
    shared/min computed over NONZERO finite cells via eff_unbiased_exp."""
    effs = []
    any_nan = any(c["is_nan"] for c in cells)
    any_inf = any(c["is_inf"] for c in cells)
    for c in cells:
        if c["is_nan"] or c["is_inf"] or c["mant48"] == 0:
            continue
        effs.append(eff_unbiased_exp(c["mant48"], c["exp10"]))
    if not effs:
        return (None, None, 0, any_nan, any_inf)
    return (max(effs), min(effs), len(effs), any_nan, any_inf)


def requantize_cell_int_golden(cell, shared_exp, target_mant_w, round_mode=OUT_ROUND_RTZ):
    """Per-cell INT narrowing — the requantizer LEAF oracle (given the block's
    shared_exp). Returns (q_signed, underflow). value ~= q * 2^(shared_exp-(W-2))."""
    W = target_mant_w
    if cell["mant48"] == 0:
        return (0, False)
    E_block = shared_exp - (W - 2)
    sh = E_block - cell["exp10"]
    qmag = _round_shift_mag(cell["mant48"], sh, round_mode)
    qmax = (1 << (W - 1)) - 1
    qmin_mag = (1 << (W - 1))
    if cell["sign"]:
        qmag = min(qmag, qmin_mag); q = -qmag
    else:
        qmag = min(qmag, qmax); q = qmag
    return (q, q == 0)


def requantize_cell_fp_golden(cell, shared_exp, target_mant_w, round_mode=OUT_ROUND_RNE):
    """Per-cell MXFP re-encode — the requantizer FP LEAF oracle. Returns
    (fp_bits, underflow). elem = FP4 E2M1 (W=4) / FP8 E4M3FN (W=8) of
    value/2^shared_exp; underflow when the magnitude pattern rounds to 0."""
    W = target_mant_w
    if cell["mant48"] == 0:
        return (0, False)
    x = cell_value(cell) / (2.0 ** shared_exp)
    enc = fp4_e2m1_encode if W == 4 else fp8_e4m3fn_encode
    bits = enc(x, round_mode)
    return (bits, (bits & ((1 << (W - 1)) - 1)) == 0)


def requantize_block_golden(cells, target_mant_w, kind, round_mode=OUT_ROUND_RTZ,
                            scale_format=SCALE_E8M0):
    """D9 oracle. Narrow a block of block-float cells to target_mant_w x {INT,FP}.

    Returns dict:
      scale_byte   : E8M0 (or E4M3) shared-scale byte
      ref_exp      : the exponent the scale_byte encodes (E_block for INT,
                     shared_exp for FP)
      shared_exp   : block max eff exponent
      elems        : list of N outputs — signed ints (INT) or packed FP bits (FP)
      escape       : True if any nonzero cell underflowed to a zero output
      spread       : max_eff - min_eff over nonzero cells (None if all zero)
      is_nan/is_inf/all_zero : block status
    """
    W = target_mant_w
    shared_exp, min_exp, n_nz, any_nan, any_inf = block_shared_exp(cells)
    if any_nan or any_inf:
        return {"scale_byte": 0xFF if any_nan else 0, "ref_exp": None,
                "shared_exp": shared_exp, "elems": [0] * len(cells),
                "escape": True, "spread": None, "is_nan": bool(any_nan),
                "is_inf": bool(any_inf and not any_nan), "all_zero": False}
    if n_nz == 0:                                  # all zero
        return {"scale_byte": 0, "ref_exp": 0, "shared_exp": 0,
                "elems": [0] * len(cells), "escape": False, "spread": 0,
                "is_nan": False, "is_inf": False, "all_zero": True}

    elems, escape = [], False

    if kind == "INT":
        E_block = shared_exp - (W - 2)
        ref_exp = E_block
        for c in cells:
            q, uf = requantize_cell_int_golden(c, shared_exp, W, round_mode)
            if c["mant48"] != 0 and uf:
                escape = True
            elems.append(q)
    elif kind == "FP":
        ref_exp = shared_exp
        enc = fp4_e2m1_encode if W == 4 else fp8_e4m3fn_encode
        for c in cells:
            if c["mant48"] == 0:
                elems.append(0); continue
            x = cell_value(c) / (2.0 ** shared_exp)
            bits = enc(x, round_mode)
            # detect underflow-to-zero (magnitude pattern == 0)
            mag_pat = bits & ((1 << (W - 1)) - 1)
            if mag_pat == 0:
                escape = True
            elems.append(bits)
    else:
        raise ValueError(f"kind must be INT or FP, got {kind}")

    if scale_format == SCALE_E4M3:
        scale_byte = _e4m3_scale_encode(ref_exp)
    else:
        scale_byte = (ref_exp + 127) & 0xFF
    return {"scale_byte": scale_byte, "ref_exp": ref_exp, "shared_exp": shared_exp,
            "elems": elems, "escape": escape,
            "spread": (shared_exp - min_exp), "is_nan": False, "is_inf": False,
            "all_zero": False}


def _e4m3_scale_encode(exp):
    """Encode a power-of-2 (2^exp) shared scale as an E4M3 byte (mant=0 -> exact 2^e).
    bias 7, so byte = ((exp+7) << 3). Clamped to the E4M3 normal range.
    LEGACY byte 'wire codec' (still clamps) — kept for back-compat tbs (bit8=0).
    The absolute-scale codec below is the fidelity oracle (HW-REVIEW TIER-3)."""
    e = max(1, min(15, exp + 7))
    return (e << 3) & 0xFF


# ---------------------------------------------------------------------------
# HW-REVIEW TIER-3: ABSOLUTE block-scale codec (no E4M3 4-bit clamp).
# Fidelity oracle for RESADD alignment. The alignment exponent is a PURE FUNCTION
# of the block VALUES (block_shared_exp), never re-derived from the clamped E4M3
# byte. On the wire it rides bs_capsule_t.scale_ref (signed 16b) + inline_scale[8]
# (ABS_EXP_PRESENT). bit8=0 => legacy byte decode (existing tbs stay bit-exact).
# ---------------------------------------------------------------------------
ABS_EXP_PRESENT_BIT = 8          # bs_capsule_t.inline_scale[8]
VEC_EXP_W = 10                   # lane exponent width (saturation target)


def true_ref_exp(cells, w=16, kind="INT"):
    """Absolute block reference exponent from VALUES (mirrors tensor_result_packer
    ref_exp): INT -> shared_exp-(w-2); FP -> shared_exp. None for an all-zero block."""
    shared_exp, _min, n_nz, _nan, _inf = block_shared_exp(cells)
    if n_nz == 0:
        return None
    return shared_exp - (w - 2) if kind == "INT" else shared_exp


def abs_scale_encode(ref_exp, byte=0x38):
    """Wire encoding of an absolute exponent. Returns (scale_ref, inline_scale):
    scale_ref = signed ref_exp (16b two's complement); inline_scale = bit8 | E4M3 byte
    (byte default 0x38 = exp0/mant0 -> mant_corr 128 identity)."""
    return (ref_exp & 0xFFFF), ((1 << ABS_EXP_PRESENT_BIT) | (byte & 0xFF))


def abs_scale_decode(scale_ref, inline_scale, scale_format=SCALE_E4M3, exp_w=VEC_EXP_W):
    """Decode the alignment exp_adj the RTL (vec_scale_adapter) yields for a capsule.
    abs path (inline_scale[8] & E4M3): saturate(signed scale_ref) to VEC_EXP_W; else
    legacy byte (E4M3 exp4-7 or E8M0 raw-127)."""
    byte = inline_scale & 0xFF
    if ((inline_scale >> ABS_EXP_PRESENT_BIT) & 1) and scale_format == SCALE_E4M3:
        e = signed(scale_ref & 0xFFFF, 16)
        lo, hi = -(1 << (exp_w - 1)), (1 << (exp_w - 1)) - 1
        return max(lo, min(hi, e))
    if scale_format == SCALE_E4M3:
        return ((byte >> 3) & 0xF) - 7        # legacy E4M3
    return (byte & 0xFF) - 127                 # E8M0


def extract_tile_contract_golden(w6, w7):
    """[HW-REVIEW T3-FF/FF1] Independent oracle for tile_contract_t, authored FROM
    the pe_pkg.sv word-layout COMMENT (word[6]/word[7]) — NOT copied from the RTL
    extract_tile_contract() body — so a shared bug cannot satisfy both. Returns the
    contract fields that ride the resident-RESADD path; word7[31:16] is the SIGNED
    per-residual absolute block exponent (src1_scale_ref)."""
    w6 &= 0xFFFFFFFF
    w7 &= 0xFFFFFFFF
    return {
        "elem_fmt":           w6 & 0xF,             # word6[3:0]
        "block_size_log2":    (w6 >> 4) & 0x3,      # word6[5:4]
        "dest_hint":          (w6 >> 6) & 0x3,      # word6[7:6]
        "fwd_eligible":       (w6 >> 8) & 0x1,      # word6[8]
        "half_sel":           (w6 >> 9) & 0x1,      # word6[9]
        "pertensor_scale_id": (w6 >> 10) & 0x3F,    # word6[15:10]
        "scale_rid":          (w6 >> 16) & 0xF,     # word6[19:16]
        "scale_epoch":        (w6 >> 20) & 0xFF,    # word6[27:20]
        "src1_resident":      (w6 >> 28) & 0x1,     # word6[28]
        "scale_row_off":      w7 & 0xFFFF,          # word7[15:0]
        "src1_scale_ref":     signed((w7 >> 16) & 0xFFFF, 16),  # word7[31:16] SIGNED
    }


def capsule_form_golden(cells, spread_limit=14, round_mode=OUT_ROUND_RTZ):
    """D2 oracle: form ONE block16 fast-path capsule from one row of <=16 cells.
    Always W=16 INT (the Vector fast-path lane). Returns dict:
      payload_mants : list of 16 signed 16-bit mantissas (zero-padded)
      inline_scale  : E8M0 byte (low 8 bits of bs_capsule_t.inline_scale)
      shared_exp, escape (spread>spread_limit OR underflow), spread, is_nan, is_inf, all_zero.
    On escape the capsule is NOT formed (caller routes Class C)."""
    rq = requantize_block_golden(cells, 16, "INT", round_mode, SCALE_E8M0)
    mants = list(rq["elems"]) + [0] * (16 - len(rq["elems"]))
    spread = rq["spread"]
    escape = rq["escape"] or (spread is not None and spread > spread_limit)
    return {"payload_mants": mants[:16], "inline_scale": rq["scale_byte"],
            "shared_exp": rq["shared_exp"], "escape": escape, "spread": spread,
            "is_nan": rq["is_nan"], "is_inf": rq["is_inf"], "all_zero": rq["all_zero"]}


def block32_dual_window_golden(cells32, round_mode=OUT_ROUND_RTZ):
    """D8 oracle (Q8 = two INDEPENDENT per-window exps): split 32 cells into two
    16-wide windows, form each as its own capsule with its own shared exp / scale.
    Returns (capsule_w0, capsule_w1)."""
    assert len(cells32) == 32
    return (capsule_form_golden(cells32[:16], round_mode=round_mode),
            capsule_form_golden(cells32[16:], round_mode=round_mode))


# ===========================================================================
# D10 — E4M3 precise mode: apply block-scale mantissa correction in the lane
# ===========================================================================
# The NVFP4 E4M3 block scale = (1 + m3/8) * 2^(exp-7) = (mant_corr/128) * 2^exp_adj.
# Simple mode applies only exp_adj (to the element exponent) and drops mant_corr
# (the H21 "no consumer" gap -> "lossless" was metadata-only). D10 precise mode
# applies mant_corr to the element MANTISSA: corrected = mant * mant_corr / 128.
# mant_corr in {128,144,...,240} for E4M3 (m3=0..7) -> factor in [1.0, 1.875].
# ---------------------------------------------------------------------------

def mant_corr_apply_golden(mant, mant_corr, round_mode=OUT_ROUND_RTZ, mant_w=16):
    """Oracle for vec_mant_corr_mul (D10). Apply the E4M3 block-scale mantissa
    factor to a signed block-float mantissa: corrected = mant * mant_corr / 128,
    clamped to signed mant_w. mant_corr=128 -> identity. Returns (corrected, overflow)."""
    sign = 1 if mant < 0 else 0
    mag = abs(int(mant))
    prod = mag * (mant_corr & 0xFF)          # 16b * 8b -> up to 24b
    q = prod >> 7                             # / 128
    if round_mode == OUT_ROUND_RNE:
        rem = prod & 0x7F
        if rem > 64 or (rem == 64 and (q & 1)):
            q += 1
    qmax = (1 << (mant_w - 1)) - 1
    qmin_mag = (1 << (mant_w - 1))
    ovf = False
    if sign:
        if q > qmin_mag:
            q = qmin_mag; ovf = True
        return (-q, ovf)
    else:
        if q > qmax:
            q = qmax; ovf = True
        return (q, ovf)


# ---------------------------------------------------------------------------
# D10 lane integration oracle — E4M3 precise-mode RESADD in vec_lane_array.
#
# The lane corrects each operand mantissa with its block scale's mant_corr
# (per-operand leaf, 17-bit product domain so it never clamps for a 16-bit
# input), renorms the (at most 1-bit) growth into a 16-bit mantissa + an
# exponent bump (renorm17), then runs the SAME block-float aligned add the
# lane has always done. This oracle is deliberately a faithful structural
# model of vec_lane_array's add (toward-zero alignment shift + sticky, carry
# overflow renorm, guard-bit fit-to-width). N19 independence is recovered in
# the cocotb test, which ALSO checks every result against the true real value
# value = mant*2^exp within the toward-zero quantization bound — so a shared
# bug between this model and the RTL cannot pass silently.
# ---------------------------------------------------------------------------

VEC_MANT_W = 16
VEC_EXP_W = 10
VEC_SHIFT_WIDTH = VEC_MANT_W + 4   # 20
VEC_SHIFT_MAX = VEC_SHIFT_WIDTH    # tz shifter clamp threshold (==20)


def _wrap_signed(v, bits):
    """Two's-complement wrap of v into a signed `bits`-wide value."""
    return signed(v & ((1 << bits) - 1), bits)


def _tz_shift(val, amt, width=VEC_SHIFT_WIDTH, shift_max=VEC_SHIFT_MAX):
    """Model vec_tz_shifter: arithmetic right shift with toward-zero
    correction for negatives, plus sticky. Returns (val_out_signed, sticky)."""
    if amt == 0:
        return _wrap_signed(val, width), 0
    if amt > shift_max:                      # clamp: whole value lost
        return 0, (1 if val != 0 else 0)
    floor = val >> amt                       # python >> = arithmetic (floor)
    residue = 1 if (val & ((1 << amt) - 1)) != 0 else 0
    is_neg = 1 if val < 0 else 0
    out = floor + (is_neg & residue)
    return _wrap_signed(out, width), residue


def renorm17_golden(v17, exp, mant_w=VEC_MANT_W):
    """Renorm a 17-bit corrected mantissa into a `mant_w`-bit mantissa + exp.
    If it fits, pass through. Otherwise toward-zero >>1 and bump exp by 1
    (the E4M3 factor is < 2, so the growth is always exactly one bit)."""
    lo, hi = -(1 << (mant_w - 1)), (1 << (mant_w - 1)) - 1
    if lo <= v17 <= hi:
        return v17, exp
    floor = v17 >> 1
    resid = v17 & 1
    is_neg = 1 if v17 < 0 else 0
    return floor + (is_neg & resid), exp + 1


def correct_operand_golden(mant, exp, mant_corr, precise, round_mode=OUT_ROUND_RNE):
    """Apply E4M3 precise-mode correction to one operand (mant, exp).
    Returns the corrected (mant16, exp). Identity when precise=0 or corr=128."""
    if not precise:
        return signed(mant, VEC_MANT_W), exp
    v17, _ = mant_corr_apply_golden(mant, mant_corr, round_mode, mant_w=VEC_MANT_W + 1)
    return renorm17_golden(v17, exp)


def lane_add_corrected_golden(m0, e0, m1, e1, is_sub):
    """Faithful model of vec_lane_array's normal (non-special) aligned add on
    already-corrected 16-bit operands. Returns (mant16, exp, sign, is_zero, overflow)."""
    # 17-bit-safe negate: -(-2^15) = +2^15 without a 16-bit two's-complement wrap
    # (matches the RTL's VEC_MANT_W+1 eff_src1_mant). The wide add absorbs the bit.
    eff1 = -signed(m1, VEC_MANT_W) if is_sub else signed(m1, VEC_MANT_W)
    ext0 = signed(m0, VEC_MANT_W)
    ext1 = eff1

    ediff = e0 - e1
    abs_diff = min(abs(ediff), 63)
    shift_src1_side = ediff > 0

    if shift_src1_side:
        sh, sticky = _tz_shift(ext1, abs_diff)
        a = ext0
        b = sh | (1 if sticky else 0)          # aligned_b[0] |= sticky
    else:
        sh, sticky = _tz_shift(ext0, abs_diff)
        a = sh | (1 if sticky else 0)          # aligned_a[0] |= sticky
        b = ext1
    res_exp = e0 if shift_src1_side else e1

    s = a + b                                  # 21-bit sum (arbitrary precision)
    # overflow when the 21-bit sum no longer fits in VEC_SHIFT_WIDTH-bit signed
    lo20, hi20 = -(1 << (VEC_SHIFT_WIDTH - 1)), (1 << (VEC_SHIFT_WIDTH - 1)) - 1
    ovf = not (lo20 <= s <= hi20)
    if ovf:
        sum_norm = s >> 1                      # sum_wide[20:1]  (arithmetic)
        exp_norm = res_exp + 1
    else:
        sum_norm = s
        exp_norm = res_exp

    # guard-bit fit-to-width: bits [18:15] that differ from the sign (bit 19)
    sb = (sum_norm >> (VEC_SHIFT_WIDTH - 1)) & 1
    extra_shift = 0
    for k in range(VEC_SHIFT_WIDTH - 2, VEC_MANT_W - 2, -1):   # 18,17,16,15
        if ((sum_norm >> k) & 1) != sb:
            extra_shift = k - (VEC_MANT_W - 1) + 1             # 18->4 .. 15->1
            break

    if extra_shift == 0:
        final_val = sum_norm
        final_exp = exp_norm
    else:
        final_val, _ = _tz_shift(sum_norm, extra_shift)        # toward-zero >> extra
        final_exp = exp_norm + extra_shift

    fv = _wrap_signed(final_val, VEC_SHIFT_WIDTH)
    mant = signed(fv & ((1 << VEC_MANT_W) - 1), VEC_MANT_W)
    sign = (fv >> (VEC_SHIFT_WIDTH - 1)) & 1
    is_zero = 1 if mant == 0 else 0
    return mant, final_exp, sign, is_zero, (1 if (ovf or extra_shift) else 0)


def lane_resadd_precise_golden(m0, e0, z0, m1, e1, z1,
                               mant_corr0, mant_corr1, is_sub, precise,
                               round_mode=OUT_ROUND_RNE):
    """Top-level oracle for one lane of vec_lane_array under LANE_ADD/LANE_SUB.
    Operands are (mant, exp, is_zero); is_nan/is_inf are out of scope for D10
    (correction does not touch the special flags). Returns a dict matching the
    tb_lane_resadd_precise observation ports."""
    cm0, ce0 = correct_operand_golden(m0, e0, mant_corr0, precise, round_mode)
    cm1, ce1 = correct_operand_golden(m1, e1, mant_corr1, precise, round_mode)

    if z0 and z1:                              # 0 +/- 0
        return {"mant": cm0, "exp": ce0, "sign": (cm0 >> (VEC_MANT_W - 1)) & 1,
                "is_zero": 1, "overflow": 0}
    if z0:                                     # 0 +/- x  -> +/-x (RTL forces is_zero=0)
        neg = -signed(cm1, VEC_MANT_W) if is_sub else signed(cm1, VEC_MANT_W)
        m, e = renorm17_golden(neg, ce1)        # +2^15 (from negating -2^15) -> (2^14, e+1)
        return {"mant": m, "exp": e, "sign": (m >> (VEC_MANT_W - 1)) & 1,
                "is_zero": 0, "overflow": 0}
    if z1:                                     # x +/- 0  -> x (from_elem(es0), is_zero=z0=0)
        return {"mant": cm0, "exp": ce0, "sign": (cm0 >> (VEC_MANT_W - 1)) & 1,
                "is_zero": 0, "overflow": 0}

    mant, exp, sign, is_zero, ovf = lane_add_corrected_golden(cm0, ce0, cm1, ce1, is_sub)
    return {"mant": mant, "exp": exp, "sign": sign, "is_zero": is_zero, "overflow": ovf}


# ---------------------------------------------------------------------------
# vec_renorm_quant model — the SHARED-exponent re-alignment that consumes the
# per-lane results (including any +1 exp bump from D10's mant_corr renorm17).
# This is the "renorm 移位 + 抬 shared exp" stage: it finds the block max exponent
# across finite non-zero lanes, toward-zero re-aligns every lane mantissa to it,
# and flags escape on excessive spread. The module is UNCHANGED by D10 — this
# oracle exists to prove the per-lane bump actually propagates to the shared exp.
# ---------------------------------------------------------------------------

ESCAPE_THRESHOLD = VEC_MANT_W - 2          # 14

def _mant_tz_shift_w(val, amt, width=VEC_MANT_W):
    """vec_renorm_quant.mant_tz_shift: toward-zero, clamp-to-zero at amt>=width."""
    if amt == 0:
        return signed(val, width)
    if amt >= width:
        return 0
    floor = val >> amt
    resid = 1 if (val & ((1 << amt) - 1)) != 0 else 0
    is_neg = 1 if val < 0 else 0
    return signed(floor + (is_neg & resid), width)


def renorm_block_golden(lanes):
    """lanes = list of dicts with mant/exp/is_zero (and optional is_nan/is_inf).
    Returns {shared_exp, escape, scale_changed, aligned: [mant,...]} matching
    vec_renorm_quant (orig_scale=identity so scale_changed = max_exp!=0)."""
    norm = [l for l in lanes if not l.get("is_nan") and not l.get("is_inf")
            and not l["is_zero"] and signed(l["mant"], VEC_MANT_W) != 0]
    any_nan = any(l.get("is_nan") for l in lanes)
    any_inf = any(l.get("is_inf") for l in lanes)
    if not norm:
        max_exp = min_exp = 0
        any_normal = False
    else:
        any_normal = True
        max_exp = max(l["exp"] for l in norm)
        min_exp = min(l["exp"] for l in norm)
    escape = bool(any_normal and (max_exp - min_exp) > ESCAPE_THRESHOLD)
    aligned = []
    for l in lanes:
        if l.get("is_nan") or l.get("is_inf") or l["is_zero"] or signed(l["mant"], VEC_MANT_W) == 0:
            aligned.append(0)
        else:
            sh = max_exp - l["exp"]
            sh = 0 if sh < 0 else (63 if sh > 63 else sh)
            aligned.append(_mant_tz_shift_w(signed(l["mant"], VEC_MANT_W), sh))
    scale_changed = bool(any_normal and (max_exp != 0))   # orig identity exp_adj=0
    return {"shared_exp": max_exp, "escape": escape,
            "scale_changed": scale_changed, "aligned": aligned}


# ---------------------------------------------------------------------------
# resadd_fastpath_golden — the SoC E2E oracle (STEP4-E2E inc 5).
# Composes the D10 lane + renorm goldens: the Vector RESADD of two fast-path
# operand capsules (SRC0, SRC1) produces a block-float result whose packed
# mantissas + shared exponent are the L2 write-back. Given the two capsules'
# 16-lane payloads and their decoded block-scale exponents, returns the
# expected (shared_exp, aligned[16]) that the Vector renorm/packer writes to L2.
# Default path: E8M0 scales (mant_corr=128, simple mode) — the simplest E2E.
# ---------------------------------------------------------------------------

def resadd_fastpath_golden(mant0, e0, mant1, e1, is_sub=False,
                           mant_corr0=128, mant_corr1=128, precise=False):
    """mant0/mant1: list of 16 signed 16-bit lane mantissas; e0/e1: decoded
    block-scale exp_adj per operand. Returns {shared_exp, aligned:[16]} = the
    256b L2 write-back (lane i mantissa = aligned[i])."""
    lanes = []
    for i in range(16):
        r = lane_resadd_precise_golden(mant0[i], e0, 0, mant1[i], e1, 0,
                                       mant_corr0, mant_corr1, is_sub, precise)
        lanes.append({"mant": r["mant"], "exp": r["exp"], "is_zero": r["is_zero"]})
    rn = renorm_block_golden(lanes)
    return {"shared_exp": rn["shared_exp"], "aligned": rn["aligned"], "escape": rn["escape"]}


def resadd_block32_golden(src0_w0, src0_w1, e0_w0, e0_w1, res_w0, res_w1, e1_w0, e1_w1,
                          is_sub=False, mant_corr0=128, mant_corr1=128, precise=False):
    """[HW-REVIEW T3-FF/FF2] block32 (2-window) RESADD oracle: apply
    resadd_fastpath_golden INDEPENDENTLY per 16-lane window. e1_w0/e1_w1 are EXPLICIT
    per-window residual exps — FF2 uses ONE shared residual scale (so e1_w0==e1_w1),
    but the oracle stays honest about per-window alignment so a shared-scale shortcut
    cannot silently re-admit a power-of-two misalign on window 1. Returns (win0, win1),
    each {shared_exp, aligned[16]} = one 256b L2 write-back (window1 -> dst_ref+1)."""
    w0 = resadd_fastpath_golden(src0_w0, e0_w0, res_w0, e1_w0, is_sub,
                                mant_corr0, mant_corr1, precise)
    w1 = resadd_fastpath_golden(src0_w1, e0_w1, res_w1, e1_w1, is_sub,
                                mant_corr0, mant_corr1, precise)
    return (w0, w1)


# ---------------------------------------------------------------------------
# [HW-REVIEW T3-FF/FF3a] Multi-block streaming residual scales.
# A resident residual spans N blocks (N = the streaming length, carried by
# len_rows); each block has its OWN absolute block exponent. The N exponents live
# in an L2 "scale-sidecar" region addressed by the contract's scale_rid +
# scale_row_off, packed DENSE as 16 signed-16b exps per 256b row: exp[k] is at
# row (sidecar_base + k//16), bits [16*(k%16) +: 16]. The streaming reader reads a
# sidecar row alongside the residual payload reads and applies exp[k] as the
# resident block's abs scale_ref. SRC0 streams as N ordered fast-path capsules
# (user decision (B), 2026-06-21) — the natural extension of the resident RESADD.
# ---------------------------------------------------------------------------

def scale_stream_pack(exps):
    """Pack signed block exponents into 256b sidecar rows (16 per row; exp[k] at
    row k//16, bits [16*(k%16) +: 16]). Returns a list of ints (each a 256b row)."""
    rows = []
    for k, e in enumerate(exps):
        r, lane = k // 16, k % 16
        while len(rows) <= r:
            rows.append(0)
        rows[r] |= (e & 0xFFFF) << (16 * lane)
    return rows


def scale_stream_unpack(row, lane):
    """Independent decode: extract the signed-16b exp at lane (k%16) from a 256b row.
    Mirrors the pe_pkg sidecar_scale_k() RTL primitive (authored from the packing doc)."""
    return signed((row >> (16 * lane)) & 0xFFFF, 16)


def resadd_stream_golden(src0_blocks, e0_list, res_blocks, e1_list,
                         is_sub=False, mant_corr0=128, mant_corr1=128, precise=False):
    """[T3-FF/FF3a] Multi-block streaming RESADD oracle: per-block resadd_fastpath_golden
    over N blocks, each with its OWN src0/residual exponent. Returns a list of N
    {shared_exp, aligned[16]} (block k -> dst_ref+k). Reduces to the single-block golden
    at N=1. The EXPLICIT per-block e1_list keeps the oracle honest — a single shared
    residual scale would silently re-admit the power-of-two misalign on blocks k>=1."""
    n = len(src0_blocks)
    assert len(res_blocks) == n and len(e0_list) == n and len(e1_list) == n
    return [resadd_fastpath_golden(src0_blocks[k], e0_list[k], res_blocks[k], e1_list[k],
                                   is_sub, mant_corr0, mant_corr1, precise)
            for k in range(n)]


def resadd_stream_block32(src0_w0_blocks, src0_w1_blocks, res_w0_blocks, res_w1_blocks,
                          e1_list, e0=0, is_sub=False, mant_corr0=128, mant_corr1=128,
                          precise=False):
    """[T3-FF/FF3b-c] Multi-block streaming block32 RESADD oracle. Block k is two 16-lane
    windows that SHARE the block's absolute exponent e1_list[k] (one scale over 32 elems);
    window 0 -> dst_ref+2k, window 1 -> dst_ref+2k+1. Returns a list of N (g0, g1) pairs.
    The shared-per-block e1 is the honest model — a window that used a different exp, or a
    block that reused block-0's exp, would diverge from this oracle."""
    n = len(src0_w0_blocks)
    assert (len(src0_w1_blocks) == n and len(res_w0_blocks) == n
            and len(res_w1_blocks) == n and len(e1_list) == n)
    return [resadd_block32_golden(src0_w0_blocks[k], src0_w1_blocks[k], e0, e0,
                                  res_w0_blocks[k], res_w1_blocks[k], e1_list[k], e1_list[k],
                                  is_sub, mant_corr0, mant_corr1, precise)
            for k in range(n)]


# =============================================================================================
# REDUCE_STAT (sum of squares) golden — S-STAT v1.2 = prereg soc600_prereg_20260902.md §70 + §74.1
#   (待-2 / #285 ⑬⑭ / H6; S6 = O-IB, S8 = scheme C, user pick D-SSQ-SDEL-ANSWERS-2026-10-01 ①②)
# The block from "from fractions import Fraction" down to stat_sumsq_golden_int is copied
# VERBATIM from the §74.1.3 code block (the judge re-extracts that block from the prereg and
# requires byte equality with the text between the two marker lines below, gate G0s). G0s also
# requires that every name the block defines is still bound, at module level, to the block's own
# definition (no later re-definition / re-binding anywhere in this file, no shadowing of the
# builtins the block calls). Do not edit it here: change the prereg first (§74 is the authority;
# §70.3's draft-§3.2 version is superseded by §74.1.0).
# Pure Python, no RTL structure (no LZC / funnel / accumulator width) — the bit-level models of
# the old and proposed RTL live in aichip_run_logs/stat_fix_judge_20261002.py, not here.
# =============================================================================================
# ---- §74.1.3 verbatim begin ----
from fractions import Fraction
import math
STAT_P, STAT_EMAX, STAT_EMIN = 20, 511, -512
STAT_WIN_LSB = 34                      # 窗口格点 u = 2^(2G - 34)
STAT_INF = (-(1 << 20), 511)           # O-IB：21 位字段 0x100000
STAT_NAN = (-1, 0)                     # O-IB：21 位字段 0x1FFFFF
# lane = dict(mant=int16, exp=int10, is_zero, is_nan, is_inf)

def _stat_contrib(l):                                     # S1
    return not (l['is_zero'] or l['mant'] == 0 or l['is_nan'] or l['is_inf'])

def _stat_key(l):                                         # g = e + floor(log2|m|)
    return l['exp'] + abs(l['mant']).bit_length() - 1

def _stat_pass_value(lanes, exact=False):                 # S2 / S3-C
    c = [l for l in lanes if _stat_contrib(l)]
    if not c:
        return Fraction(0)
    t = [Fraction(l['mant'] ** 2) * Fraction(2) ** (2 * l['exp']) for l in c]
    if exact:
        return sum(t, Fraction(0))
    u = Fraction(2) ** (2 * max(_stat_key(l) for l in c) - STAT_WIN_LSB)
    return sum((math.floor(x / u) * u for x in t), Fraction(0))

def _ilog2(S):
    k = S.numerator.bit_length() - S.denominator.bit_length()
    if Fraction(2) ** k > S: k -= 1
    elif Fraction(2) ** (k + 1) <= S: k += 1
    return k

def stat_sumsq_golden(passes, exact=False):               # -> (mant21 有符号, exp10, is_nan, is_inf)
    nan = any(l['is_nan'] for p in passes for l in p)
    inf = any(l['is_inf'] for p in passes for l in p)
    S = sum((_stat_pass_value(p, exact) for p in passes), Fraction(0))   # S4
    ovf, M, E = False, 0, 0
    if S != 0:                                                            # S5
        E = _ilog2(S) - (STAT_P - 1); M = round(S / Fraction(2) ** E)
        if M == 1 << STAT_P: M >>= 1; E += 1
        if E > STAT_EMAX: ovf = True                                      # S6
        elif E < STAT_EMIN: M = E = 0                                     # S7
    if nan: return (*STAT_NAN, 1, int(inf or ovf))                        # S8
    if inf or ovf: return (*STAT_INF, 0, 1)
    return (M, E, 0, 0)

def stat_raw_golden(lanes):                               # S9：rm ∈ [2^39, 2^40)
    S = _stat_pass_value(lanes)
    if S == 0: return (0, 0)
    re = _ilog2(S) - 39; rm = S / Fraction(2) ** re
    assert rm.denominator == 1 and (1 << 39) <= rm < (1 << 40)
    return (int(rm), re)

def stat_sumsq_golden_int(passes, K=1200):                # N 版本：纯大整数
    nan = any(l['is_nan'] for p in passes for l in p)
    inf = any(l['is_inf'] for p in passes for l in p)
    Si = 0
    for lanes in passes:
        c = [l for l in lanes if _stat_contrib(l)]
        if not c: continue
        sh = 2 * max(l['exp'] + abs(l['mant']).bit_length() - 1 for l in c) - STAT_WIN_LSB + K
        for l in c:
            v = (l['mant'] * l['mant']) << (2 * l['exp'] + K)
            Si += (v >> sh) << sh
    ovf, M, E = False, 0, 0
    if Si:
        s = Si.bit_length() - STAT_P; M = Si >> s; rem = Si & ((1 << s) - 1); half = 1 << (s - 1)
        if rem > half or (rem == half and (M & 1)): M += 1
        E = s - K
        if M == 1 << STAT_P: M >>= 1; E += 1
        if E > STAT_EMAX: ovf = True
        elif E < STAT_EMIN: M = E = 0
    if nan: return (*STAT_NAN, 1, int(inf or ovf))
    if inf or ovf: return (*STAT_INF, 0, 1)
    return (M, E, 0, 0)
# ---- §74.1.3 verbatim end ----


# ---- [§74.1.4] H6 boundary vectors (STAT_H6_VECTORS) --------------------------------------
# One entry per id of prereg §74.1.4 (54 rows: module 41 = B*, block32 13 = X*).
#   passes : list of 1 (block16) or 2 (block32) passes, each exactly 16 lane dicts
#   expect : (M, E, is_nan, is_inf), M as signed 21-bit (C + O-IB expectation of §74.1.4)
# Lane notation of the prereg table: (m,e) non-zero lane, Z(e) = is_zero lane with exp e,
# unlisted lanes are Z. Module rows pad with Z(0); block32 (X*) rows pad each pass with
# Z(<block exp of that pass>) because at e2e level a zero lane carries the block exponent.
# The judge (aichip_run_logs/stat_fix_judge_20261002.py, gate G0b) re-parses the prereg
# table independently and requires table == this dict == golden output, lane by lane.

def _stat_lane(m, e, is_zero=0, is_nan=0, is_inf=0):
    return dict(mant=m, exp=e, is_zero=is_zero, is_nan=is_nan, is_inf=is_inf)


def _stat_pad(lanes, zexp=0):
    lanes = list(lanes)
    assert len(lanes) <= 16
    return lanes + [_stat_lane(0, zexp, 1) for _ in range(16 - len(lanes))]


def _stat_at(mants, e):
    return [_stat_lane(m, e) for m in mants]


STAT_D0 = [-280, 259, -206, 177, -132, 95, -58, 13, 16, -69, 90, -151, 164, -233, 238, -315]
STAT_D1 = [-19, 38, 53, -52, 83, 98, -85, 128, 143, -118, 173, 188, -151, 218, 233, -184]

_L, _P, _A = _stat_lane, _stat_pad, _stat_at
_B5D = [-32768, 32767, 253, 22, 4, 1, 1, 1]
_B5F = [-32768, -32768, -32768, 32767, 251, 22, 1, 1, 1]

STAT_H6_VECTORS = {
    # ---- module level (vec_reduce_cluster, block16) ----
    'B1a': dict(passes=[_P([_L(16384, -14)], -14)], expect=(524288, -19, 0, 0)),
    'B1b': dict(passes=[_P([_L(16384, -14)], 0)], expect=(524288, -19, 0, 0)),
    'B1c': dict(passes=[_P([_L(16384, -14)], 100)], expect=(524288, -19, 0, 0)),
    'B1d': dict(passes=[_P([_L(1, 0)])], expect=(524288, -19, 0, 0)),
    'B1e': dict(passes=[_P([_L(16384, -14), _L(0, 100, 0)])], expect=(524288, -19, 0, 0)),
    'B1f': dict(passes=[_P([_L(1, -14)], 0)], expect=(524288, -47, 0, 0)),
    'B2a': dict(passes=[_P([], 0)], expect=(0, 0, 0, 0)),
    'B2b': dict(passes=[_P([], -14)], expect=(0, 0, 0, 0)),
    'B3a': dict(passes=[_A([-32768] * 16, 0)], expect=(524288, 15, 0, 0)),
    'B3b': dict(passes=[_A([-32768] * 16, -8)], expect=(524288, -1, 0, 0)),
    'B3c': dict(passes=[_P([_L(-32768, 0)])], expect=(524288, 11, 0, 0)),
    'B3e': dict(passes=[_A([-32768] * 16, 248)], expect=(524288, 511, 0, 0)),
    'B4a': dict(passes=[_P([_L(1, 100), _L(32767, -100)])], expect=(524288, 181, 0, 0)),
    'B4b': dict(passes=[_P([_L(1, 2), _L(3, 0)])], expect=(819200, -15, 0, 0)),
    'B4c': dict(passes=[_P([_L(1, 511), _L(32767, -512)])], expect=(-1048576, 511, 0, 1)),
    'B4d': dict(passes=[_P([_L(32767, -5), _L(7, -6), _L(1023, 0), _L(1, 5), _L(7, -2)])],
                expect=(1048034, 1, 0, 0)),
    'B4e': dict(passes=[_P([_L(1, 3)] + _A([1] * 15, 0))], expect=(647168, -13, 0, 0)),
    'B4f': dict(passes=[_P([_L(1, 0)] + _A([32767] * 15, -17))], expect=(1015778, -19, 0, 0)),
    'B5a': dict(passes=[_P([_L(100, 300)])], expect=(-1048576, 511, 0, 1)),
    'B5b': dict(passes=[_P([_L(-32768, 251)])], expect=(-1048576, 511, 0, 1)),
    'B5c': dict(passes=[_P([_L(-32768, 250)])], expect=(524288, 511, 0, 0)),
    'B5d': dict(passes=[_P(_A(_B5D, 250))], expect=(-1048576, 511, 0, 1)),
    'B5f': dict(passes=[_P(_A(_B5F, 249))], expect=(524288, 511, 0, 0)),
    'B5g': dict(passes=[_P(_A(_B5F, 250))], expect=(-1048576, 511, 0, 1)),
    'B6a': dict(passes=[_P([_L(1, -512)])], expect=(0, 0, 0, 0)),
    'B6b': dict(passes=[_P(_A([1, 1], -247))], expect=(524288, -512, 0, 0)),
    'B6c': dict(passes=[_P(_A([1], -247))], expect=(0, 0, 0, 0)),
    'B6d': dict(passes=[_P(_A(_B5D, -262))], expect=(524288, -512, 0, 0)),
    'B6e': dict(passes=[_P(_A(_B5D, -263))], expect=(0, 0, 0, 0)),
    'B7a': dict(passes=[_P([_L(5, 0, is_nan=1), _L(3, 0)])], expect=(-1, 0, 1, 0)),
    'B7b': dict(passes=[_P([_L(5, 0, is_inf=1), _L(3, 0)])], expect=(-1048576, 511, 0, 1)),
    'B7c': dict(passes=[_P([_L(5, 0, is_nan=1), _L(5, 0, is_inf=1)])], expect=(-1, 0, 1, 1)),
    'B7d': dict(passes=[_P([_L(5, 300, is_nan=1), _L(3, 0)])], expect=(-1, 0, 1, 0)),
    'B8': dict(passes=[_P([_L(1024, 0), _L(1, 0)])], expect=(524288, 1, 0, 0)),
    'B4g': dict(passes=[_P([_L(1, 0)] + _A([32767] * 15, -32))], expect=(524288, -19, 0, 0)),
    'B5h': dict(passes=[_P([_L(32767, 498)])], expect=(-1048576, 511, 0, 1)),
    'B8w': dict(passes=[_P([_L(1024, 0), _L(1, 0), _L(3, -9)])], expect=(524288, 1, 0, 0)),
    'B8n': dict(passes=[_P([_L(1024, 0), _L(1, 0), _L(1, -7)])], expect=(524289, 1, 0, 0)),
    'B8p': dict(passes=[_P([_L(1449, 0), _L(1, 0), _L(1, -7)])], expect=(524901, 2, 0, 0)),
    'B8c': dict(passes=[_P([_L(1024, 0), _L(1, 0), _L(-32768, -22)])], expect=(524289, 1, 0, 0)),
    'B8d': dict(passes=[_P([_L(1024, 0), _L(1, 0), _L(-32768, -23)])], expect=(524288, 1, 0, 0)),
    # ---- block32 (vector_unit cross-pass) ----
    'X1': dict(passes=[_P([], 0), _P([_L(16384, -14)], -14)], expect=(524288, -19, 0, 0)),
    'X2': dict(passes=[_P([_L(16384, -14)], -14), _P([], 0)], expect=(524288, -19, 0, 0)),
    'X12': dict(passes=[_P([_L(16384, -14)], -14), _P([_L(1, -300)], -300)], expect=(524288, -19, 0, 0)),
    'X3': dict(passes=[_A([32767] * 16, 128), _A([32767] * 16, -128)], expect=(1048512, 270, 0, 0)),
    'X3b': dict(passes=[_A([1] * 16, 128), _A([1] * 16, -128)], expect=(524288, 241, 0, 0)),
    'X3c': dict(passes=[_A([1] * 16, -128), _A([1] * 16, 128)], expect=(524288, 241, 0, 0)),
    'X4': dict(passes=[_A([32767] * 16, 150), _A([32767] * 16, -150)], expect=(1048512, 314, 0, 0)),
    'X5': dict(passes=[_P([_L(1024, 0), _L(1, 0)], 0), _P([_L(1, -60)], -60)], expect=(524289, 1, 0, 0)),
    'X6': dict(passes=[_A([-32768] * 16, 0), _A([-32768] * 16, 0)], expect=(524288, 16, 0, 0)),
    'X7': dict(passes=[_P([_L(-32768, 250)], 250), _P([_L(-32768, 250)], 250)],
               expect=(-1048576, 511, 0, 1)),
    'X8': dict(passes=[_P([_L(512, 0)], 0), _P([_L(512, 0)], 0)], expect=(524288, 0, 0, 0)),
    'X9': dict(passes=[_A(STAT_D0, 0), _A(STAT_D1, 0)], expect=(827736, 0, 0, 0)),
    'X11': dict(passes=[_A(STAT_D0, -3), _A(STAT_D1, -5)], expect=(541296, -6, 0, 0)),
}

# S9 raw port reference (prereg §74.1.4 raw table, module level; the judge recomputes with
# stat_raw_golden and requires table == this dict == golden).
STAT_H6_RAW = {
    'B1a': (0x8000000000, -39), 'B1f': (0x8000000000, -67), 'B2a': (0, 0),
    'B3a': (0x8000000000, -5), 'B4b': (0xC800000000, -35), 'B4d': (0xFFDE209A80, -19),
    'B5a': (0x9C40000000, 574), 'B6a': (0x8000000000, -1063), 'B8': (0x8000080000, -19),
}

# Golden-only fixed controls (prereg §74.1.4 F-table; J0 G0c only, NOT in ids_module).
#   expect = scheme-C output, rne_exact = stat_sumsq_golden(., exact=True)
_FCORE = [32767, 1015, 44, 3, 2, 1]
STAT_GOLDEN_CONTROLS = {
    'F-FTZ': dict(passes=[_P([_L(1, -247), _L(32767, -262)] + _A([1015, 44, 3, 2, 1], -264)
                             + _A([32767, 32767], -279))],
                  expect=(0, 0, 0, 0), rne_exact=(524288, -512, 0, 0)),
    'F-OVF': dict(passes=[_P([_L(1, 265), _L(32767, 250)] + _A([1015, 44, 3, 2, 1], 248)
                             + _A([32767, 32767], 233))],
                  expect=(1048575, 511, 0, 0), rne_exact=(-1048576, 511, 0, 1)),
}
del _L, _P, _A, _FCORE


def stat_random_vectors(seed, n, mode):
    """Frozen random-vector generator for the S-STAT v1.2 checks (prereg §74.1.5 JSON
    `generator`). Self-contained on purpose: the judge prints md5(inspect.getsource(this
    function)) as GEN_MD5 and J1/J2 require the same md5, so every byte of the generation
    logic must live inside this function body.

    mode = the JSON key naming the set: golden_cross, g0f_bitmodel, c12_block16, c3_pre,
    faithful_adv, nonU_err (J0) / module_U, module_nonU (module tb) / e2e_U (e2e tb).
    e2e_U is stratified by i % 4 over the full exp range [-512, 511] (the e2e lane exp is the
    block scale exp, saturated to [-512, 511] by vec_scale_adapter's abs path): 0 = each pass
    its own rbase() exp, 1 = both passes the same rbase() exp, 2 = both passes in the overflow
    band [235, 300], 3 = both passes in the flush-to-zero band [-300, -235]; so the random e2e
    group reaches Inf, FTZ and finite outputs (the judge checks this coverage independently).
    Returns a list of n records (tags, passes):
      passes : 1 or 2 passes of exactly 16 lane dicts (mant, exp, is_zero, is_nan, is_inf)
      tags   : one tag per pass naming the construction, which the judge turns into a
               per-pass predicate (GOLDEN-INVALID when it fails):
                 'U'     all contributing lanes share one exponent
                 'U_e2e' 'U' + e2e shape (zero lane = is_zero with mant 0 and the block
                         exponent, no NaN/Inf lane, no is_zero=0 & mant=0 lane)
                 'span2' max(e) - min(e) <= 2 over contributing lanes
                 'wide'  not P3: some contributing lane has e < G - 17
                 'empty' no contributing lane
                 'any' / 'adv' / 'c3'  range checks only
    c12_block16 needs n % 4 == 0 and yields n/4 each of U, span2, wide, any (in that order).
    """
    import random
    modes = ('golden_cross', 'g0f_bitmodel', 'c12_block16', 'c3_pre', 'faithful_adv',
             'nonU_err', 'module_U', 'module_nonU', 'e2e_U')
    if mode not in modes:
        raise ValueError('unknown mode %r' % (mode,))
    if mode == 'c12_block16' and n % 4:
        raise ValueError('c12_block16 needs n % 4 == 0')
    rng = random.Random(seed)
    NL, EMIN, EMAX = 16, -512, 511

    def L(m, e, z=0, nan=0, inf=0):
        return dict(mant=m, exp=e, is_zero=z, is_nan=nan, is_inf=inf)

    def ce(e):
        return max(EMIN, min(EMAX, e))

    def rmant():                       # non-zero mantissa, log-uniform magnitude
        r = rng.random()
        if r < 0.04:
            return -32768
        if r < 0.08:
            return rng.choice((32767, -32767, 1, -1))
        b = rng.randint(1, 15)
        mag = rng.randint(1 << (b - 1), (1 << b) - 1)
        return mag if rng.random() < 0.5 else -mag

    def rbase():                       # mostly moderate; sometimes range edges / OVF / FTZ zones
        r = rng.random()
        if r < 0.55:
            return rng.randint(-60, 60)
        if r < 0.75:
            return rng.randint(EMIN, EMAX)
        if r < 0.875:
            return rng.randint(230, 290)          # overflow boundary sits near G = 265
        return rng.randint(-280, -220)            # underflow boundary sits near G = -247

    def zl(e0, e2e):                   # a non-contributing zero lane
        if e2e:
            return L(0, e0, 1)
        r = rng.random()
        if r < 0.6:
            return L(0, e0, 1)
        if r < 0.85:
            return L(0, rng.randint(EMIN, EMAX), 1)
        return L(0, rng.randint(EMIN, EMAX), 0)   # is_zero = 0 but mant == 0

    def sl(e):                         # a NaN or Inf lane (mantissa arbitrary)
        return L(rmant(), e, 0, 1, 0) if rng.random() < 0.5 else L(rmant(), e, 0, 0, 1)

    def fill(exps, e0, pz, psp, e2e):
        out = []
        for e in exps:
            r = rng.random()
            if r < pz:
                out.append(zl(e0, e2e))
            elif r < pz + psp:
                out.append(sl(e))
            else:
                out.append(L(rmant(), e))
        if not e2e and all(l['is_zero'] or l['mant'] == 0 or l['is_nan'] or l['is_inf']
                           for l in out) and rng.random() < 0.7:
            i = rng.randrange(NL)
            out[i] = L(rmant(), exps[i])        # keep most passes non-empty
        return out

    def p_empty(e2e):
        e0 = rbase()
        return [zl(e0, e2e) for _ in range(NL)]

    def p_U(e0=None, psp=0.0, e2e=False, elo=EMIN, ehi=EMAX):
        e0 = max(elo, min(ehi, rbase() if e0 is None else e0))
        lanes = fill([e0] * NL, e0, rng.choice((0.0, 0.1, 0.3)), psp, e2e)
        if e2e and all(l['mant'] == 0 for l in lanes):
            lanes[0] = L(rmant(), e0)
        return lanes

    def p_span2(e0=None, psp=0.0):
        e0 = max(EMIN, min(EMAX - 2, rbase() if e0 is None else e0))
        lanes = fill([e0 + rng.randint(0, 2) for _ in range(NL)], e0,
                     rng.choice((0.0, 0.1, 0.3)), psp, False)
        return lanes

    def p_wide(e0=None, psp=0.0):
        e0 = max(EMIN + 58, min(EMAX, rbase() if e0 is None else e0))
        m0 = rmant()
        k0 = abs(m0).bit_length() - 1
        far = e0 + k0 - 18 - rng.randint(0, 40)          # e_far < G - 17 since G >= e0 + k0
        w = rng.choice((3, 10, 20, 40, 80, 300))
        exps = [ce(e0 - rng.randint(0, w)) for _ in range(NL - 2)]
        lanes = fill(exps, e0, rng.choice((0.0, 0.1, 0.3)), psp, False)
        lanes += [L(m0, e0), L(rmant(), far)]
        rng.shuffle(lanes)
        return lanes

    def p_any(e0=None, psp=0.0, wmin=0):
        e0 = rbase() if e0 is None else e0
        w = rng.choice(tuple(x for x in (0, 1, 2, 5, 17, 18, 19, 33, 34, 40, 100, 1023)
                             if x >= wmin))
        exps = [ce(e0 - rng.randint(0, w)) for _ in range(NL)]
        return fill(exps, ce(e0), rng.choice((0.0, 0.1, 0.3)), psp, False)

    def p_adv():                       # near-tie heads + tails around the window LSB
        e0 = rng.randint(-200, 200)
        fam = rng.random()
        if fam < 0.5:                  # 2^(2k) + 2^(2k-20): an exact rounding tie
            k = rng.randint(10, 15)
            a = -32768 if k == 15 else (1 << k) * rng.choice((1, -1))
            head = [L(a, e0), L(1 << (k - 10), e0)]
        else:                          # random head, squares pulled close to a tie
            a = rmant()
            while abs(a) < 1024:
                a = rmant()
            q = a * a
            p = q.bit_length() - 20
            head = [L(a, e0)]
            if p >= 2:
                delta = ((1 << (p - 1)) - (q & ((1 << p) - 1))) % (1 << p)
                for _ in range(3):
                    b = int(delta ** 0.5)
                    while b * b > delta:
                        b -= 1
                    while (b + 1) * (b + 1) <= delta:
                        b += 1
                    if b == 0:
                        break
                    head.append(L(min(b, 32767), e0))
                    delta -= min(b, 32767) ** 2
        G = max(l['exp'] + abs(l['mant']).bit_length() - 1 for l in head)
        tail = [L(rmant(), ce(G - rng.randint(14, 36))) for _ in range(rng.randint(0, 16 - len(head)))]
        if rng.random() < 0.25:        # block32: the tail rides in its own pass (sticky path)
            if not tail:
                tail = [L(rmant(), ce(G - rng.randint(14, 60)))]
            return [head + [L(0, e0, 1) for _ in range(NL - len(head))],
                    tail + [L(0, e0, 1) for _ in range(NL - len(tail))]]
        lanes = head + tail
        return [lanes + [L(0, e0, 1) for _ in range(NL - len(lanes))]]

    def p_kind(kind, psp, e0=None):
        if kind == 'U':
            return p_U(e0, psp)
        if kind == 'span2':
            return p_span2(e0, psp)
        if kind == 'wide':
            return p_wide(e0, psp)
        if kind == 'empty':
            return p_empty(False)
        return p_any(e0, psp)

    def mixed(two_prob, psp_vec):
        psp = rng.choice((0.1, 0.2)) if rng.random() < psp_vec else 0.0
        kinds = []
        for _ in range(2 if rng.random() < two_prob else 1):
            r = rng.random()
            kinds.append('empty' if r < 0.03 else 'U' if r < 0.33 else 'span2' if r < 0.48
                         else 'wide' if r < 0.68 else 'any')
        passes = [p_kind(kinds[0], psp)]
        if len(kinds) == 2:
            r = rng.random()
            e1 = (passes[0][0]['exp'] if r < 0.5 else
                  ce(passes[0][0]['exp'] + rng.randint(-40, 40)) if r < 0.75 else None)
            passes.append(p_kind(kinds[1], psp, e1))
        return tuple(kinds), passes

    out = []
    for i in range(n):
        if mode in ('golden_cross', 'g0f_bitmodel'):
            out.append(mixed(0.45, 0.05))
        elif mode == 'c12_block16':
            kind = ('U', 'span2', 'wide', 'any')[(4 * i) // n]
            out.append(((kind,), [p_kind(kind, 0.0 if kind != 'any' else
                                          (0.1 if rng.random() < 0.05 else 0.0))]))
        elif mode == 'c3_pre':
            e0 = rng.randint(-200, 200)
            lanes = p_any(e0, 0.0)
            if all(l['is_zero'] or l['mant'] == 0 for l in lanes):
                lanes[0] = L(rmant(), e0)
            out.append((('c3',), [lanes]))
        elif mode == 'faithful_adv':
            ps = p_adv()
            out.append((('adv',) * len(ps), ps))
        elif mode == 'nonU_err':
            kinds, ps = [], []
            for _ in range(2 if rng.random() < 0.4 else 1):
                if rng.random() < 0.5:
                    kinds.append('wide')
                    ps.append(p_wide())
                else:
                    kinds.append('any')
                    ps.append(p_any(wmin=18))
            out.append((tuple(kinds), ps))
        elif mode == 'module_U':
            out.append((('U',), [p_U(None, 0.1 if rng.random() < 0.05 else 0.0)]))
        elif mode == 'module_nonU':
            kind = rng.choice(('span2', 'wide', 'any', 'any'))
            out.append(((kind,), [p_kind(kind, 0.1 if rng.random() < 0.05 else 0.0)]))
        else:                                                           # e2e_U
            k = i % 4
            if k == 0:
                ps = [p_U(None, 0.0, True) for _ in range(2)]
            elif k == 1:
                e0 = rbase()
                ps = [p_U(e0, 0.0, True) for _ in range(2)]
            else:
                lo, hi = (235, 300) if k == 2 else (-300, -235)
                ps = [p_U(rng.randint(lo, hi), 0.0, True) for _ in range(2)]
            out.append((('U_e2e', 'U_e2e'), ps))
    return out
