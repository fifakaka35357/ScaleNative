"""GEMM 激励构造 + 去混叠闸（批 4a 搭载件，2026-07-29）。

🔴 背景 —— fail-open 第 5 员「金标自混叠」：

原激励（本模块取代之）为
    A[r][k] = ((r + 2*k) % 7) - 3     → 行向量以 7 为周期 ⇒ A[r] ≡ A[r±7]
    B[k][c] = ((3*k + c) % 5) - 2     → 列向量以 5 为周期 ⇒ B[:,c] ≡ B[:,c±5]

在 16x16 阵列上，这让【整整一类 D 通路错接】对金标完全不可见：
  · 行互换 r ↔ r±7 共 9 对：(0,7)(1,8)…(8,15)
  · 列互换 c ↔ c±5 共 11 对：(0,5)(1,6)…(10,15)
两类都跨象限边界（含 8/8 与 5/10 分界），即"象限化"类改动最需要看见的那些错接。
后果实测：A2 类变异灵敏度只有 61/64 —— 缺的 3 个正是金标恰为 0.0 的假绿。

本模块用确定性整数散列打散索引，**值域逐位不变**：
  A ∈ [-3,3]（7 个取值）、B ∈ [-2,2]（5 个取值） ⇒ |C| ≤ 6K，
  BF16 精确、零值密度（≈1/7、1/5）、饱和/溢出包络与旧激励同量级 ——
  只消除周期性，不改变被测的数值行为。

并提供 assert_dealiased()：把"可观测量两两互异且非零"做成硬断言。
其中【金标 C 的行/列互异】才是充要判据 —— 操作数互异只是必要条件，
真正决定 D 错接可不可见的是 C 本身。

用法：
    import gemm_operands as go
    A = go.make_A(K); B = go.make_B(K)
    C = g.gemm_bf16_golden(A, B)
    go.assert_dealiased(A, B, C, tag="gemm_core")
"""


def _mix(x):
    """Thomas Wang 32-bit 整数散列（确定性、无 random 依赖、跨 Python 版本稳定）。"""
    x &= 0xFFFFFFFF
    x = (x ^ 61) ^ (x >> 16)
    x = (x + (x << 3)) & 0xFFFFFFFF
    x ^= x >> 4
    x = (x * 0x27D4EB2D) & 0xFFFFFFFF
    x ^= x >> 15
    return x


def make_A(K, rows=16, salt=0):
    """A[r][k] ∈ [-3,3]（7 值）。行向量无周期 —— 行错接可见。"""
    return [[(_mix(0x51ED2701 ^ (salt << 20) ^ (r << 10) ^ k) % 7) - 3
             for k in range(K)] for r in range(rows)]


def make_B(K, cols=16, salt=0):
    """B[k][c] ∈ [-2,2]（5 值）。列向量无周期 —— 列错接可见。"""
    return [[(_mix(0x2545F491 ^ (salt << 20) ^ (k << 10) ^ c) % 5) - 2
             for c in range(cols)] for k in range(K)]


def assert_dealiased(A, B, C=None, tag=""):
    """去混叠硬闸。A 为 rows x K，B 为 K x cols，C（可选）为金标 rows x cols。

    给了 C 就把闸下在【可观测量】上——那才是 D 错接可不可见的充要判据。
    """
    pfx = ("[%s] " % tag) if tag else ""

    a_rows = [tuple(row) for row in A]
    assert len(set(a_rows)) == len(a_rows), \
        pfx + "A 的行向量有重复 → 行(r)错接对金标不可见（激励自混叠）"
    assert all(any(v != 0 for v in row) for row in a_rows), \
        pfx + "A 有全零行 → 该行的错接不可见"

    b_cols = [tuple(row[c] for row in B) for c in range(len(B[0]))]
    assert len(set(b_cols)) == len(b_cols), \
        pfx + "B 的列向量有重复 → 列(c)错接对金标不可见（激励自混叠）"
    assert all(any(v != 0 for v in col) for col in b_cols), \
        pfx + "B 有全零列 → 该列的错接不可见"

    if C is not None:
        c_rows = [tuple(row) for row in C]
        assert len(set(c_rows)) == len(c_rows), \
            pfx + "金标 C 的行向量有重复 → 行错接不可观测"
        c_cols = [tuple(row[j] for row in C) for j in range(len(C[0]))]
        assert len(set(c_cols)) == len(c_cols), \
            pfx + "金标 C 的列向量有重复 → 列错接不可观测"
        assert all(any(v != 0 for v in row) for row in c_rows), \
            pfx + "金标 C 有全零行 → 该行错接不可观测"


def assert_no_zero_cells(C, tag=""):
    """卡零可观测性闸：金标里任何一个 C[r][c]==0 的 cell，都【无法】区分
    "算对了" 与 "这个 cell 死了输出 0"。

    实证（批 3）：K1c-b 的 A2 变异打死 SE 象限 64 个 cell（输出恒 0），测试只
    抓到 61 个 —— 漏掉的 3 个正是金标恰为 0.0 的那 3 个。旧激励的零 cell 还
    高度结构化（行 {4,5,11,12} × 列间隔 5），是周期激励的直接产物。

    ⚠️ 本闸守着 make_A/make_B 的 salt 取值：那对 salt 是在 64x64 salt 空间里
    按"零 cell 数 = 0 且 C 行/列两两互异"搜出来的（K=24 共 5 组解）。改 K、
    改构造、改 salt 都会让本闸炸响 —— 这正是要的：魔数不能静默失效。
    """
    pfx = ("[%s] " % tag) if tag else ""
    zeros = [(r, c) for r, row in enumerate(C) for c, v in enumerate(row) if v == 0]
    assert not zeros, (pfx + "金标有 %d 个零 cell → 这些 cell 的'卡零'故障不可观测: %s"
                       % (len(zeros), zeros[:8]))

# ──────────────────────────────────────────────────────────────────────────────
# 🔴 旧（周期性）构造 —— **仅供 fail-open 红样本取证使用，禁止用于门禁**
#
# 批 5 补的那个"零红证"缺口（审查裁决 §3.5 / 手册 §2 步骤 2）：
# 「r±7 / c±5 错接可见性」此前只有推断，从未做过真 D 错接的红样本。
# 要做那个样本就必须能重建旧激励，用来证明【旧激励在同一个错接下必绿】
# —— 这才是 fail-open 的实证，而不是"新激励能红"的单边证据。
#
# 这两个函数带 `_legacy` 后缀且不被任何门禁路径调用；调用方必须显式传
# `allow_aliased=True` 才能跳过去混叠闸（见 assert_dealiased）。
# ──────────────────────────────────────────────────────────────────────────────
def make_A_legacy(K, rows=16):
    """旧构造 A[r][k] = ((r + 2k) % 7) - 3 —— 行向量以 7 为周期（r ≡ r±7）。"""
    return [[((r + 2 * k) % 7) - 3 for k in range(K)] for r in range(rows)]


def make_B_legacy(K, cols=16):
    """旧构造 B[k][c] = ((3k + c) % 5) - 2 —— 列向量以 5 为周期（c ≡ c±5）。"""
    return [[((3 * k + c) % 5) - 2 for c in range(cols)] for k in range(K)]


def miswire_swap_rows(A, r1=0, r2=7):
    """把 A 的第 r1 与 r2 行互换 —— 模拟 DUT 把两条激活行接反。
    只作用在【喂给 DUT 的操作数】上，金标仍用原 A ⇒ 等价于阵列把
    row r1 的激活线接到了 row r2 上。

    🔴 为什么是【互换】而不是手册写的 `r -> (r+7)%16` 整体循环移位：
       旧激励 A[r][k]=((r+2k)%7)-3 的混叠关系是 r ≡ r' (mod 7)，
       即 0≡7≡14、1≡8≡15、2≡9、…。循环移位在 r>=9 处把 r 映到 r+7-16 = r-9，
       而 r 与 r-9 一般【不】同余于 mod 7（例：9 vs 0，2≠0）⇒ 循环移位对旧激励
       **可见**，用它做不出 fail-open 实证。互换一对同余行才是旧激励真正瞎的那类。
       （实测：K=20/24 下循环移位后旧激励的金标会变；互换 0↔7 则逐位不变。）
    """
    B = [list(row) for row in A]
    B[r1], B[r2] = B[r2], B[r1]
    return B


def miswire_swap_cols(B, c1=0, c2=5):
    """把 B 的第 c1 与 c2 列互换 —— 模拟 DUT 把两条权重列接反。
    旧激励 B[k][c]=((3k+c)%5)-2 的混叠关系是 c ≡ c' (mod 5)：0≡5≡10≡15、…。"""
    out = []
    for row in B:
        r = list(row)
        r[c1], r[c2] = r[c2], r[c1]
        out.append(r)
    return out
