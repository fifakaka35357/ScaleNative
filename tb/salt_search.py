#!/usr/bin/env python3
"""
金标 salt 搜索工具 —— 批 5 任务 #11 的前置件（2026-07-30 新建）。

## 为什么需要它

`gemm_operands.assert_no_zero_cells` 的头注说 gemm_core 的 salt 对 (24,50) 由
「64×64 搜索」得出，但**全仓没有任何搜索代码或搜索日志**（批5 侦察实测：
`grep -rn salt` 只命中 gemm_operands.py、三个 test 的实参、以及三篇 Review 文档；
`find -iname "*salt*"` 项目侧零命中）。于是：

  · 那 4 个只调 `assert_dealiased`、不调 `assert_no_zero_cells` 的点，
    其 salt 从未被「零 cell = 0」这条闸筛过 —— 实测它们现在各有 5/9/6/12 个零 cell；
  · 想补挂 `assert_no_zero_cells` 就必须先找到能过闸的 salt，而工具不存在。

本文件把搜索固化成可复现的脚本，输出**逐场景的解集**，供 TB 直接引用。

## 判据（与 gemm_operands 的两条闸逐字一致）

一组 salt 合格 ⟺
  1) `assert_dealiased(A, B, C_golden)` 全过：A 行两两互异且非全零、
     B 列两两互异且非全零、金标 C 的行/列两两互异、C 无全零行；
  2) `assert_no_zero_cells(C_golden)` 全过：C 里**没有任何**零 cell。
     （零 cell 无法区分「算对了」与「这个 cell 卡零」= fail-open 第 5 员。）

## 用法

    python3 salt_search.py                # 跑全部场景，打印解集
    python3 salt_search.py --range 128    # 扩大搜索范围
    python3 salt_search.py --json out.json

## 🔴 纪律

选定的 salt 必须**同时**写进 TB 并补挂 `assert_no_zero_cells`，否则下一次改激励
时这条约束会再次静默丢失（本工具的存在本身就是那次丢失的后果）。
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bfp_golden as g          # noqa: E402
import gemm_operands as go      # noqa: E402

ROWS = COLS = 16


# ──────────────────────────────────────────────────────────────────────────────
# 判据（不要在这里重新实现闸 —— 直接调 gemm_operands 的那两个，保证同一口径）
# ──────────────────────────────────────────────────────────────────────────────
def evaluate(A, B):
    """返回 (ok, C, why)。ok=True 表示两条闸全过。"""
    try:
        C = g.gemm_bf16_golden(A, B)
    except AssertionError as e:
        return False, None, "golden: %s" % e
    try:
        go.assert_dealiased(A, B, C, tag="search")
    except AssertionError as e:
        return False, C, "dealiased: %s" % str(e).split("→")[0].strip()
    try:
        go.assert_no_zero_cells(C, tag="search")
    except AssertionError as e:
        return False, C, "zero_cells: %s" % str(e).split("→")[0].strip()
    return True, C, ""


def zero_cells(C):
    return [(r, c) for r, row in enumerate(C) for c, v in enumerate(row) if v == 0]


# ──────────────────────────────────────────────────────────────────────────────
# 场景：每个 = (名字, K, 构造函数(saltA, saltB) -> (A, B), 备注)
#   构造函数必须【逐字复刻】对应 TB 的操作数生成（含撒零等后处理），
#   否则搜出来的 salt 在 TB 里不成立。
# ──────────────────────────────────────────────────────────────────────────────
def plain(K):
    def f(sa, sb):
        return go.make_A(K, ROWS, salt=sa), go.make_B(K, COLS, salt=sb)
    return f


def scu_tile_sprinkled(K):
    """逐字复刻 test_scu_tile.py:118-131 的撒零后处理。"""
    def f(sa, sb):
        A = go.make_A(K, ROWS, salt=sa)
        B = go.make_B(K, COLS, salt=sb)
        for k in range(K):
            if k % 4 == 1:
                for r in range(ROWS):
                    if r in (5, 6, 11):
                        A[r][k] = 0
            if k % 3 == 0:
                for c in (2, 9, 14):
                    B[k][c] = 0
        return A, B
    return f


SCENARIOS = [
    # name                       K   builder                 note
    ("gemm_core",                24, plain(24),
     "现值 A=24 B=50，已挂 assert_no_zero_cells —— 本行是【工具自证】：必须复现它"),
    ("b2b_tileA",                20, plain(20),
     "test_tensor_gemm_core.py:241-242，现值 1/1 -> 5 个零 cell，未挂闸"),
    ("b2b_tileB",                20, plain(20),
     "test_tensor_gemm_core.py:243-244，现值 2/2 -> 9 个零 cell（3 在 SE），未挂闸"),
    ("scu_tile",                 24, scu_tile_sprinkled(24),
     "test_scu_tile.py:120-121 + 撒零，现值 3/3 -> 6 个零 cell，未挂闸"),
    ("sparse_stall_K24",         24, plain(24),
     "test_tensor_sparse_stall.py:244 salt=seed_r*16+seed_c；K=24 seed(1,3)=19 -> 12 个零 cell"),
    ("sparse_stall_K20",         20, plain(20),
     "同上 K=20；seed(1,3)=19 -> 14 个零 cell、seed(2,1)=33 -> 5 个零 cell"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--range", type=int, default=64,
                    help="salt 搜索上界（不含）。salt<<20 与索引位 (r<<10|k) 不重叠，"
                         "故 salt 可安全取到 4095")
    ap.add_argument("--max-solutions", type=int, default=6)
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    out = {}
    for name, K, build, note in SCENARIOS:
        sols = []
        for sa in range(args.range):
            for sb in range(args.range):
                A, B = build(sa, sb)
                ok, C, why = evaluate(A, B)
                if ok:
                    sols.append((sa, sb))
                    if len(sols) >= args.max_solutions:
                        break
            if len(sols) >= args.max_solutions:
                break
        out[name] = {"K": K, "note": note, "solutions": sols,
                     "searched": args.range}
        print("── %-20s K=%d  搜索 %d×%d" % (name, K, args.range, args.range))
        print("   %s" % note)
        if sols:
            print("   ✅ 解（前 %d）: %s" % (len(sols), sols))
            sa, sb = sols[0]
            A, B = build(sa, sb)
            _, C, _ = evaluate(A, B)
            print("   选定 saltA=%d saltB=%d  零 cell=%d  C 行/列互异=%d/%d, %d/%d"
                  % (sa, sb, len(zero_cells(C)),
                     len({tuple(r) for r in C}), ROWS,
                     len({tuple(row[j] for row in C) for j in range(COLS)}), COLS))
        else:
            print("   ❌ 在 [0,%d)² 内无解 —— 扩大 --range" % args.range)

    # 交叉约束：b2b 两块的金标必须不同（test_tensor_gemm_core.py:249）
    if out["b2b_tileA"]["solutions"] and out["b2b_tileB"]["solutions"]:
        aA, aB = out["b2b_tileA"]["solutions"][0]
        for cand in out["b2b_tileB"]["solutions"]:
            if cand != (aA, aB):
                A1, B1 = plain(20)(aA, aB)
                A2, B2 = plain(20)(*cand)
                if g.gemm_bf16_golden(A1, B1) != g.gemm_bf16_golden(A2, B2):
                    out["b2b_tileB"]["chosen_distinct"] = list(cand)
                    print("── b2b 交叉约束: tileA=%s tileB=%s，两块金标不同 ✅"
                          % ((aA, aB), cand))
                    break
        else:
            print("── 🔴 b2b 交叉约束不满足：找不到与 tileA 金标不同的 tileB 解")

    if args.json:
        with open(args.json, "w") as f:
            json.dump(out, f, indent=2)
        print("\nJSON -> %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
