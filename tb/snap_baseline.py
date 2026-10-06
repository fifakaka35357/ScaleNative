"""snap_baseline.py —— dense 位样本基线的 dump / check 双模式（阶段 3a 步骤 0 交付件）。

## 它是什么

规格 `Tensor/Idea/Tensor_Unit_Sparse_Doubling_Spec.md §8.2 R1`（dense 逐位不变）的
**执行件**。R1 的判据是「稀疏改造之后，dense 通路的 256×61b `snap_flat` 与改造前
逐位相同」——判据要能真的变红，就必须有：① 改造前的位样本；② 一个会比对它的消费者。
本模块两件都提供。判据与口径 = `Review/R1_Baseline_Criteria_2026-08-02.md`（发数前预登记）。

## 用法（默认全关，门禁路径逐字不变）

    GEMM_SNAP_DUMP=<root>  python3 run_all.py test_tensor_gemm_core   # 采集 → <root>/<group>/<case>.snap
    GEMM_SNAP_CHECK=<root> python3 run_all.py test_tensor_gemm_core   # 逐位回比，不同即红

两个都不设 = 完全 no-op。两个都设 = 硬报错（口径二义）。
驱动脚本 = `aichip_run_logs/r1_baseline_capture_20260802.sh`（采集）与
`aichip_run_logs/r1_recheck_20260802.sh`（回比，接进每片收口）。

## 🔴 为什么不是「一个大 hex 文件」

61 bit **不对齐 nibble**（61/4 = 15.25）⇒ 任何「在 hex 串上切 16 个字符取一个 cell」的
写法都会拿到被邻 cell 低位污染的值，而且污染只落在最高一个 nibble、值看起来完全正常。
故：一 case 一文件（寻址退化成 `open()`，前缀混淆与重复块在文件系统层不可能发生）+
正文只放逐 cell 行 + 整片只留 `#FLAT_SHA256`（由 256 个 cell 重算校验，两套编码互证）。

## 🔴 fail-open 防线（对照 `PROJECT_RULES §5.0d` 型号表）

- 型 1（缺段读成通过）：`#END <n> <sha256>` 完整性哨兵，缺 `#END` 即 INVALID。
- 型 3（空集/子集计 0）：check 侧文件不存在 = **硬失败，禁 SKIP**；覆盖率闭合由驱动脚本
  按 `EXPECTED_CASES` 断言 `R1-CHECK-CONSUMED` 行数。
- 型 7（记录生效自证）：同组内各 case 的 FLAT 必须两两不等（`r1_dense` 组的 K/salt 互异
  ⇒ 金标已实证两两不等）；相同 = `RECORD-INEFFECTIVE`。
- 型 9（闸只在文档不在代码）：check 每比完一个 case 打一行 `R1-CHECK-CONSUMED`，
  「绿」不许由 `PASS=N` 单独证明。
- 型 10（解析器空输入返回邻值）：解析规则逐条硬失败，禁 warning；行号↔(r,c) 必须自洽。
- 型 14（守卫恒读 0）：`is_nan/is_inf` 一律经 `bfp_golden.decode_fp_acc_out` 取，**禁自拆位**
  （按 hex 字符位置拆位会稳定读到 0，自证从此永远绿）。
"""
import hashlib
import os
import sys

# --- bfp_golden 是 61b 位域的唯一权威解码器（禁自拆位，见头注型 14）---
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Model"))
import bfp_golden as _g   # noqa: E402

# ── 口径常量（改这里 = 改 R1 的定义，须同批改判据文件）────────────────────────
ENV_DUMP  = "GEMM_SNAP_DUMP"
ENV_CHECK = "GEMM_SNAP_CHECK"
ENV_TOOL  = "GEMM_SNAP_TOOLTAG"   # 由驱动脚本注入（XPROP/XSEED 是 make 变量，python 看不见）

FMT_VERSION = "r1-snap v1"
ROWS = COLS = 16
CELLS       = ROWS * COLS          # 256
CELL_BITS   = 61                   # fp_acc_output_t
FLAT_BITS   = CELLS * CELL_BITS    # 15616
FLAT_HEX    = (FLAT_BITS + 3) // 4 # 3904
MODE_BF16   = 4
RTL_ANCHOR  = "96fe783"            # 采集基线的 AI_Chip RTL 锚 commit

#: 权威 case 集合。驱动脚本用 `python3 -c 'import snap_baseline; ...'` 取它做覆盖率闭合，
#: **禁止在别处手抄第二份**（两处手抄 = 名字漂移时静默子集比对）。
EXPECTED_CASES = {
    # R1 判据组 —— 8 个 dense 形状，见判据文件 §2.2
    "r1_dense": (
        "gemm_core_k24",
        "gemm_core_b2b_k20_tileA",
        "gemm_core_b2b_k20_tileB",
        "gemm_core_k25",
        "gemm_core_k23",
        "gemm_core_k26",
        "gemm_core_b2b_k25_tileA",
        "gemm_core_b2b_k25_tileB",
    ),
    # 存档组 —— **不进 R1 判据**，退役条件见判据文件 §2.3
    "r1_archive": (
        "scu_tile_control",
        "scu_tile_bit_reserved",
        # ▲[3a-1 2026-08-02] "sparse_nostall_control" 退役：其载体
        #   test_tensor_sparse_stall.py 已改名 pending_（前提被规格 §4.1 推翻），
        #   .snap 保留在 baseline/r1_archive/ 作历史证据但不再有产生者。
        #   🔴 实测事实：该 case 自入库起【从未被任何执行件消费过】——
        #   r1_recheck_20260802.sh 只数 r1_dense ⇒ 这不是「从有守门退化成无守门」，
        #   是「从来就没有」。判据文件 §2.3 已追加订正框。
    ),
    # 自包含性红绿自证组 —— 采基线【之前】用【改造前的激励】跑一遍，证明判据文件 §4 的
    # 三处 tb 修改（各 tile 自写 PAD / b2b tileB 基址回到 SRAM_DEPTH 界内 / 垃圾值域排除 0）
    # 对 dense 位样本【逐位无影响】。不同 ⇒ 今天的 os_zero_pad 尾窗掩蔽就有洞，
    # 是比 R1 更早的红，停机报用户。载体 = tb/_r1_preproof.py（一次性，用完即删）。
    "r1_preproof": (
        "gemm_core_k24",
        "gemm_core_b2b_k20_tileA",
        "gemm_core_b2b_k20_tileB",
    ),
}

#: 只有这些组做「同组各 case 位样本两两不等」的记录生效自证。
#: 🔴 `r1_archive` 不在其中 —— `scu_tile_control` 与 `scu_tile_bit_reserved`
#: 按 `D-SCU-RESERVED` 的守门语义**必须**逐位相同。
DISTINCT_GROUPS = ("r1_dense", "r1_preproof")

#: 进程内已写入的记录（跨 case 互异自证 + 重复写拦截）。
_written = {}


class SnapError(AssertionError):
    """位样本协议违例。一律硬失败，禁 warning（WARNING 级静默回退比 ERROR 危险）。"""


# ── 模式 ────────────────────────────────────────────────────────────────────
def mode():
    """返回 (mode, root)。mode ∈ {None, 'dump', 'check'}。"""
    d = os.environ.get(ENV_DUMP, "")
    c = os.environ.get(ENV_CHECK, "")
    if d and c:
        raise SnapError("%s 与 %s 同时设置 —— 口径二义，拒绝执行" % (ENV_DUMP, ENV_CHECK))
    if d:
        return "dump", d
    if c:
        return "check", c
    return None, ""


def _tooltag():
    return os.environ.get(ENV_TOOL, "UNSET")


def _forensic_guard():
    """取证钩子会跳过去混叠/零 cell 两闸 ⇒ 它产出的位样本绝不许进基线。"""
    if os.environ.get("GEMM_LEGACY_OPERANDS", "0") == "1" or os.environ.get("GEMM_D_MISWIRE", ""):
        raise SnapError(
            "FORENSIC 模式（GEMM_LEGACY_OPERANDS/GEMM_D_MISWIRE）下禁止 dump/check 位样本："
            "取证激励跳过了去混叠与零 cell 两闸，其位样本不是基线")


# ── 编解码 ──────────────────────────────────────────────────────────────────
def cell_of(snap_int, r, c):
    """取 cell (r,c) 的 61b 原始值。索引口径与 test_tensor_gemm_core.snap_cell 逐字一致。"""
    return (snap_int >> ((r * COLS + c) * CELL_BITS)) & ((1 << CELL_BITS) - 1)


def flat_hex(snap_int):
    """规范化整片 hex：小写、定宽 3904 字符、零填。这是 #FLAT_SHA256 的唯一原像。"""
    return "%0*x" % (FLAT_HEX, snap_int)


def _sha(text):
    return hashlib.sha256(text.encode("ascii")).hexdigest()


def _meta_line(key, meta):
    return "#%s %s" % (key, meta[key]) if key in meta else None


def _render(group, case, snap_int, meta):
    body = "".join("%02d %02d %016x\n" % (r, c, cell_of(snap_int, r, c))
                   for r in range(ROWS) for c in range(COLS))
    head = [
        "#FMT %s" % FMT_VERSION,
        "#CASE %s" % case,
        "#GROUP %s" % group,
        "#RTL %s" % RTL_ANCHOR,
        "#TB %s" % meta["tb"],
        "#DEFORDER %d" % meta["deforder"],
        "#ANCHOR %s" % meta["anchor"],
        "#CYCLES start_to_capture=%d" % meta["cycles"],
        "#SHAPE ROWS=%d COLS=%d CELLBITS=%d CELLS=%d IDX=(r*COLS+c)*%d_LSB MODE=BF16(%d)"
        % (ROWS, COLS, CELL_BITS, CELLS, CELL_BITS, MODE_BF16),
        "#PARAM %s" % meta["param"],
        "#SRAMSPAN %s" % meta["sramspan"],
        "#DISTINCT cells=%d golden=%d" % (meta["distinct_cells"], meta["distinct_golden"]),
        "#TOOL %s" % _tooltag(),
    ]
    if "csr" in meta:
        head.append("#CSR %s" % meta["csr"])
    head.append("#FLAT_SHA256 %s" % _sha(flat_hex(snap_int)))
    return "\n".join(head) + "\n" + body + "#END %d %s\n" % (CELLS, _sha(body))


def _parse(text, where):
    """解析 + 逐条校验。任一不满足即硬失败（禁 warning）。"""
    def bad(msg):
        raise SnapError("[%s] %s" % (where, msg))

    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    head, body_lines, tail = {}, [], None
    for ln in lines:
        if ln.startswith("#END "):
            if tail is not None:
                bad("出现多个 #END")
            tail = ln
        elif ln.startswith("#"):
            if tail is not None:
                bad("#END 之后还有头字段：%r" % ln)
            k, _, v = ln[1:].partition(" ")
            if k in head:
                bad("头字段 #%s 重复出现" % k)
            head[k] = v
        else:
            if tail is not None:
                bad("#END 之后还有数据行")
            body_lines.append(ln)

    if tail is None:
        bad("缺 #END 完整性哨兵 ⇒ SNAP-TRUNCATED（文件被截断或写盘中断）")
    for k in ("FMT", "CASE", "GROUP", "RTL", "TB", "ANCHOR", "CYCLES", "SHAPE",
              "PARAM", "DISTINCT", "TOOL", "FLAT_SHA256"):
        if k not in head:
            bad("缺头字段 #%s" % k)
    if head["FMT"] != FMT_VERSION:
        bad("格式版本不符：%r != %r" % (head["FMT"], FMT_VERSION))

    if len(body_lines) != CELLS:
        bad("数据行 %d 条，应为 %d 条" % (len(body_lines), CELLS))
    cells = []
    for i, ln in enumerate(body_lines):
        parts = ln.split(" ")
        if len(parts) != 3 or ln != " ".join(parts):
            bad("第 %d 条数据行格式非法（须『rr cc 16位小写hex』单空格分隔）：%r" % (i, ln))
        r, c, v = parts
        if len(r) != 2 or len(c) != 2 or len(v) != 16 or v != v.lower():
            bad("第 %d 条数据行字段宽度/大小写非法：%r" % (i, ln))
        if int(r) != i // COLS or int(c) != i % COLS:
            bad("第 %d 条数据行的 (r,c)=(%s,%s) 与行序不自洽" % (i, r, c))
        val = int(v, 16)
        if val >> CELL_BITS:
            bad("第 %d 条数据行超出 %d bit（高 %d bit 非零）：%r" % (i, CELL_BITS, 64 - CELL_BITS, v))
        cells.append(val)

    body = "".join(ln + "\n" for ln in body_lines)
    t = tail.split(" ")
    if len(t) != 3:
        bad("#END 行格式非法：%r" % tail)
    if int(t[1]) != len(body_lines):
        bad("#END 声明 %s 条数据行，实际 %d 条 ⇒ SNAP-TRUNCATED" % (t[1], len(body_lines)))
    if t[2] != _sha(body):
        bad("#END 正文 sha256 不符 ⇒ 文件被篡改或截断")

    snap_int = 0
    for i, v in enumerate(cells):
        snap_int |= v << (i * CELL_BITS)
    if _sha(flat_hex(snap_int)) != head["FLAT_SHA256"]:
        bad("由 256 cell 重算的 #FLAT_SHA256 不符 ⇒ 两套编码互证失败（取位/偏移错）")

    head["_cells"] = cells
    head["_snap_int"] = snap_int
    head["_flat"] = flat_hex(snap_int)
    return head


# ── dump 侧四条自证 ─────────────────────────────────────────────────────────
def _self_checks(group, case, snap_int, meta):
    if not (0 <= snap_int < (1 << FLAT_BITS)):
        raise SnapError("[%s] snap_int 越出 %d bit 定宽" % (case, FLAT_BITS))

    cells = [cell_of(snap_int, r, c) for r in range(ROWS) for c in range(COLS)]

    zeros = [i for i, v in enumerate(cells) if v == 0]
    if zeros:
        raise SnapError(
            "[%s] 自证②失败：%d 个 cell 的 61b 快照为全 0（复位值就是 '0，说明该 cell 未捕获）；"
            "前几个 (r,c)=%s" % (case, len(zeros), [(i // COLS, i % COLS) for i in zeros[:8]]))

    # 自证③：位样本的 distinct 数必须 **≥** 金标值的 distinct 数。
    # 🔴 不能写「相等」：61b 原始编码不是规范形（同一个数值可由不同 (mant,exp) 表示，
    #    value = mant·2^(exp−F)）⇒ distinct_raw ≥ distinct_value 是恒成立的严格关系，
    #    实测 K=24 时 70 vs 61。这条差额本身就是「R1 位级判据严格强于金标值判据」的实证。
    #    该闸的作用域 = 拦住「整片退化成同一个值」这类未捕获/卡死形态。
    n_distinct = len(set(cells))
    if n_distinct < meta["distinct_golden"]:
        raise SnapError(
            "[%s] 自证③失败：位样本 distinct=%d < 金标值 distinct=%d —— 不同数值必须有"
            "不同的 61b 编码，小于说明位样本退化（整片同值/部分未捕获）"
            % (case, n_distinct, meta["distinct_golden"]))
    meta["distinct_cells"] = n_distinct

    bad = []
    for r in range(ROWS):
        for c in range(COLS):
            d = _g.decode_fp_acc_out(cell_of(snap_int, r, c), MODE_BF16)
            if d["is_nan"] or d["is_inf"]:
                bad.append((r, c, d["is_nan"], d["is_inf"]))
    if bad:
        raise SnapError("[%s] 自证④失败：%d 个 cell 带 is_nan/is_inf：%s"
                        % (case, len(bad), bad[:8]))

    if group in DISTINCT_GROUPS:
        f = flat_hex(snap_int)
        for other, of in _written.items():
            if other[0] == group and of == f:
                raise SnapError(
                    "RECORD-INEFFECTIVE：[%s] 与 [%s] 位样本逐位相同。"
                    "同组各 case 的 K/salt 互异（金标已实证两两不等）⇒ 相同意味着"
                    "记录路径拿到了同一个对象，check 会自己跟自己比、永远绿" % (case, other[1]))


# ── 对外唯一入口 ────────────────────────────────────────────────────────────
def record(group, case, snap_int, meta, snap_int_recheck=None, log=None):
    """在【金标逐 cell 比对通过之后】调用。

    group / case  : 必须已登记在 EXPECTED_CASES（未登记 = 硬失败，防名字漂移）
    snap_int      : 已求得的整数快照。🔴 本函数**不接受 dut 句柄** —— 否则它会在钩子里
                    二次采样，落库的就不是金标验证过的那一份。
    meta          : dict，须含 tb/deforder/anchor/cycles/param/sramspan/distinct_golden，
                    可选 csr。
    snap_int_recheck : 窗内第二个时点（tu_scan_done 拍）再采一次的值，用于「稳定窗恒定」
                    的每跑必验实证；不传即跳过该项自证。
    """
    m, root = mode()
    if m is None:
        return                              # 门禁路径：完全 no-op
    _forensic_guard()

    if group not in EXPECTED_CASES:
        raise SnapError("未登记的组名 %r（登记处 = snap_baseline.EXPECTED_CASES）" % group)
    if case not in EXPECTED_CASES[group]:
        raise SnapError("未登记的 case 名 %r（组 %s 已登记：%s）"
                        % (case, group, list(EXPECTED_CASES[group])))
    if (group, case) in _written:
        raise SnapError("同一进程内 case %r 被记录两次 —— 追加写会产生重复块" % case)

    if snap_int_recheck is not None and snap_int_recheck != snap_int:
        raise SnapError(
            "[%s] 稳定窗自证失败：capture 后与 tu_scan_done 拍两次采样不等。"
            "快照 bank 唯一写点是 mac_cell.sv 的 capture_fire ⇒ 窗内应恒定；"
            "不等意味着 bank 被移位/清零/改写，或采样跨到了下一次 capture" % case)

    _self_checks(group, case, snap_int, meta)
    text = _render(group, case, snap_int, meta)
    _written[(group, case)] = flat_hex(snap_int)

    d = os.path.join(root, group)
    path = os.path.join(d, case + ".snap")
    say = (log.info if log is not None else print)

    if m == "dump":
        os.makedirs(d, exist_ok=True)
        with open(path, "x") as f:          # O_EXCL：已存在即拒写（防中断后追加污染）
            f.write(text)
        say("R1-SNAP-DUMPED %s %s sha=%s" % (group, case, _sha(text)))
        return

    # ---- check ----
    if not os.path.exists(path):
        raise SnapError(
            "基线文件不存在：%s —— **硬失败，禁 SKIP**。"
            "「找不到就跳过」会让 R1 在一个悄悄缩小的 case 集合上全绿（型 3）" % path)
    with open(path) as f:
        ref = _parse(f.read(), path)

    # 身份自证：文件名对上了不等于内容对得上（整份文件被复制/改名 = 拿邻 case 的位样本比，
    # 与解析器返回邻族值同构，型 10）。
    if ref["CASE"] != case or ref["GROUP"] != group:
        raise SnapError(
            "基线身份不符：%s 的 #CASE/#GROUP = %r/%r，期望 %r/%r —— 文件被复制或改名"
            % (path, ref["CASE"], ref["GROUP"], case, group))

    if ref["TOOL"] != _tooltag():
        raise SnapError(
            "R1-INVALID-CALIBER [%s]：工具链口径不同（基线 %r vs 本次 %r）。"
            "**既不判绿也不判红** —— 先用 tb/baseline/regen_r1_dense.sh %s 在新工具链上重采"
            % (case, ref["TOOL"], _tooltag(), RTL_ANCHOR))

    # 激励身份自证：K/salt 是「逻辑激励冻结」的三元组（判据 §4.5）。若它们变了而位样本
    # 也变了，那是**激励改了**不是 RTL 坏了 —— 两者的处置完全不同，必须分开报。
    # 🔴 只比 K/saltA/saltB，**不比 #SRAMSPAN**：规格 §2.2 路线 (A) 会让 act 行数从
    #    K+PAD 变成 ⌈K/2⌉ 量级，跨度合法地变，比它会制造假红。
    def _stim(param):
        return dict(kv.split("=", 1) for kv in param.split() if "=" in kv)
    a, b = _stim(ref["PARAM"]), _stim(meta["param"])
    drift = {k: (a.get(k), b.get(k)) for k in ("K", "saltA", "saltB") if a.get(k) != b.get(k)}
    if drift:
        raise SnapError(
            "R1-STIMULUS-CHANGED [%s]：激励三元组变了 %s —— 这不是 RTL 回归，是用例被改了。"
            "要么改回去，要么按判据 §4.5 走「基线作废重采」（禁直接判绿或判红）" % (case, drift))

    cur_flat = flat_hex(snap_int)
    if cur_flat != ref["_flat"]:
        diff = [(i // COLS, i % COLS, ref["_cells"][i], cell_of(snap_int, i // COLS, i % COLS))
                for i in range(CELLS)
                if ref["_cells"][i] != cell_of(snap_int, i // COLS, i % COLS)]
        # 🔴 全量落盘，禁截断（截断后「失配集中在哪」只能靠预测，拿不到穷举实证）
        dpath = os.path.join(root, "%s__%s.r1diff" % (group, case))
        with open(dpath, "w") as f:
            for (r, c, e, g_) in diff:
                f.write("cell(%02d,%02d) base=%016x now=%016x xor=%016x\n" % (r, c, e, g_, e ^ g_))
        raise SnapError("R1-MISMATCH [%s]：%d/%d cell 与基线不同（全量 diff → %s），"
                        "前 8 个 %s" % (case, len(diff), CELLS, dpath,
                                       [(r, c) for (r, c, _e, _g) in diff[:8]]))

    # status_csr 读口不变性：dense 通路的 8 个 CSR 在 tile 收官后的取值。
    # 🔴 为什么值得单独一态：`0x0c/0x10 = issue_count/step_count = K + DRAIN_CYCLES_OS(35)  # [K1b] 34→35，c6g 缝`
    #    （实测 K=23→0x39 / 24→0x3a / 25→0x3b / 26→0x3c），是 controller 改写后
    #    「dense 发行/步进拍数一个不多一个不少」的**计数器级**证据，与 §3.3 的 cycles 锚互补。
    #    此前 #CSR 只采不比 = 记录了却无消费者（型 9 的邻居）。
    if ("CSR" in ref) != ("csr" in meta):
        raise SnapError(
            "R1-CSR-CARRIER-CHANGED [%s]：基线%s带 #CSR 而本次%s带 —— 采集载体被改，"
            "不是 RTL 回归；要么改回去，要么走「基线作废重采」"
            % (case, "" if "CSR" in ref else "不", "" if "csr" in meta else "不"))
    if "CSR" in ref and ref["CSR"] != meta["csr"]:
        a = dict(kv.split("=", 1) for kv in ref["CSR"].split())
        b = dict(kv.split("=", 1) for kv in meta["csr"].split())
        d = {k: (a.get(k), b.get(k)) for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)}
        raise SnapError(
            "R1-CSR-DRIFT [%s]：dense 通路的 status_csr 读值变了 %s。"
            "0x0c/0x10 = issue/step count = K+34 ⇒ 它们一变就说明 dense 的发行拍数变了；"
            "其余地址变化同样是 dense 不变性被破" % (case, d))

    ref_cyc = ref["CYCLES"].split("=")[-1]
    if int(ref_cyc) != int(meta["cycles"]):
        raise SnapError(
            "R1-CADENCE-DRIFT [%s]：位样本逐位相同，但 start→capture 拍数 %s → %d。"
            "dense 档规格声称「零气泡逐位等价」⇒ 节拍变化即该声称被推翻，停机定位"
            % (case, ref_cyc, meta["cycles"]))

    say("R1-CHECK-CONSUMED %s %s sha=%s" % (group, case, ref["FLAT_SHA256"]))
