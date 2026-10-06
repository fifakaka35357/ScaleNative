"""
WP0-a-min 探针 —— 把权威 11 项表里【7 项】从推导变成实测（预登记 soc600_prereg §52）

🔴 本件【不带 test_ 前缀】⇒ run_all.py 的 glob("test_*.py") 结构上看不见它
   ⇒ 回归四个面（elaborate 靶 / test_*.py 数 / @cocotb.test 数 / 运行面）一个不动。

🔴 本件【只读采样】：不驱动任何 DUT 信号。八个包装与 duty 的八个逐字同参
   ⇒ 同一趟既产 FLDUTY-*（给 G-EXTRACT-2 与 L0 逐位比）又产 WP0MIN-*（给 Y1–Y4）。

🔴 采样循环体内【只有一处 await】（RisingEdge(clk_i)）—— 这是 §52.3-4 那条
   「cocotb 事件驱动 ⇒ 结构上不漏拍」披露所依赖的前提，改它之前先改那条披露。

手动跑法 = aichip_run_logs/launch_wp0_min.sh（它会用一个全新的构建目录，不删任何东西）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cocotb
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time

from duty_arm import _run_arm

# ── 状态编码（逐字取自 RTL 的 typedef 顺序）────────────────────────────────────
# tensor_operand_stream.sv:73  { S_IDLE, S_NEXT, S_REQ, S_RESP, S_WRITE, S_DONE }
STR_NAMES = ["S_IDLE", "S_NEXT", "S_REQ", "S_RESP", "S_WRITE", "S_DONE"]
# tensor_tile_controller.sv:253-261  显式编码 3'd0..3'd6
TILE_NAMES = ["ST_IDLE", "ST_LOAD_WEIGHT", "ST_CLEAR_ACC", "ST_COMPUTE",
              "ST_DRAIN", "ST_CAPTURE", "ST_DONE"]
STR_IDLE, TILE_IDLE, TILE_LOAD_W = 0, 0, 1

_ROOTS = {
    "stream": lambda core: core.i_tens.u_stream.state_q,
    "tile":   lambda core: core.i_tens.u_tensor.u_tile_controller.state_q,
}
# 🔴 反控：不存在的实例名必须绑不到。绑到了 ⇒ 解析器恒真 ⇒ Y1 判红。
_NEGCTL = lambda core: core.i_tens.u_NOSUCH_WP0_ZZZ.state_q

_REC = {}


def _bind(dut):
    """→ (handles, missing, negctl_missing)。🔴 绑得到 ≠ 读得动，当场读一次（§4.aq）。"""
    core = dut.dut
    h, missing = {}, []
    for k, getter in _ROOTS.items():
        try:
            x = getter(core)
            int(x.value)
            h[k] = x
        except Exception as e:                        # noqa: BLE001
            missing.append(f"{k}: {e!r}")
    try:
        _NEGCTL(core)
        neg_missing = 0                               # 🔴 绑到了 = 反控失效
    except Exception:                                 # noqa: BLE001
        neg_missing = 1
    return h, missing, neg_missing


async def _sampler(dut, tag, K, T, dual, budget):
    """逐拍只读采样。🔴 循环体内只有一处 await（见模块 docstring）。"""
    h, missing, neg_missing = _bind(dut)
    rec = _REC[tag] = {"c": [], "s": [], "t": [], "xz": {"stream": 0, "tile": 0},
                       "missing": missing, "neg_missing": neg_missing,
                       "bind_hard": len(h)}
    if len(h) != len(_ROOTS):
        return                                        # 量具不全 ⇒ 不采，让 Y1 判红
    hs, ht = h["stream"], h["tile"]
    for _ in range(budget):
        await RisingEdge(dut.clk_i)
        c = int(get_sim_time("ns")) // 10             # 🔴 拍号来自仿真时间，与采样计数无关
        try:
            sv = int(hs.value)
        except Exception:                             # noqa: BLE001  X/Z 不吞成 0
            rec["xz"]["stream"] += 1
            sv = -1
        try:
            tv = int(ht.value)
        except Exception:                             # noqa: BLE001
            rec["xz"]["tile"] += 1
            tv = -1
        rec["c"].append(c)
        rec["s"].append(sv)
        rec["t"].append(tv)


def _count_both(a, b):
    """并发计数器：同一位置两侧都「活跃」的个数。
    🔴 本函数是 `ovl` 的唯一实现，也是 `ovl_selftest` 的被测对象。"""
    return sum(1 for x, y in zip(a, b) if x and y)


def _emit(dut, tag, K, T, dual, run_id):
    """窗口切分与打印 —— 离线做（采样已结束），切分逻辑因此可单独自测。"""
    L = dut._log.info
    rec = _REC.get(tag)
    if rec is None:
        L("WP0MIN-ARM %s K=%d T=%d dual=%d n_win=0 bind_hard=0 bind_miss=%d "
          "negctl_missing=0 xz=0", tag, K, T, int(dual), len(_ROOTS))
        return
    c, s, t = rec["c"], rec["s"], rec["t"]
    xz = rec["xz"]["stream"] + rec["xz"]["tile"]
    # 窗口起点 = tile 发生 ST_IDLE → ST_LOAD_WEIGHT 跃迁的那一拍
    starts = [i for i in range(1, len(t)) if t[i] == TILE_LOAD_W and t[i - 1] == TILE_IDLE]
    n_win = max(len(starts) - 1, 0)
    L("WP0MIN-ARM %s K=%d T=%d dual=%d n_win=%d bind_hard=%d bind_miss=%d "
      "negctl_missing=%d xz=%d",
      tag, K, T, int(dual), n_win, rec["bind_hard"], len(rec["missing"]),
      rec["neg_missing"], xz)
    for k, v in rec["xz"].items():
        if v:
            L("WP0MIN-XZ %s root=%s n=%d", tag, k, v)
    for j in range(n_win):
        lo, hi = starts[j], starts[j + 1]
        sw, tw = s[lo:hi], t[lo:hi]
        c0, c1 = c[lo], c[hi - 1]
        L("WP0MIN-WIN %s j=%d c0=%d c1=%d L=%d", tag, j, c0, c1, c[hi] - c[lo])
        sb = [sw.count(i) for i in range(len(STR_NAMES))]
        tb = [tw.count(i) for i in range(len(TILE_NAMES))]
        L("WP0MIN-STR %s j=%d %s sum=%d", tag, j,
          " ".join(f"{n}={v}" for n, v in zip(STR_NAMES, sb)), sum(sb))
        L("WP0MIN-TILE %s j=%d %s sum=%d", tag, j,
          " ".join(f"{n}={v}" for n, v in zip(TILE_NAMES, tb)), sum(tb))
        ovl = _count_both([x != STR_IDLE for x in sw], [y != TILE_IDLE for y in tw])
        L("WP0MIN-OVL %s j=%d ovl=%d", tag, j, ovl)


def _emit_run_header(dut, run_id):
    """🔴 `ovl_selftest` 是【计数函数的单元测试】，不涉及 RTL、不是关于重叠的证据。
       v5 原写的 `ovl_shift1`（把 tile 桶右移 1 拍）被第五轮审查证明**结构恒 0**
       （两 FSM 活跃段之间最窄隔 2 拍、另一侧 12 拍，要移 ≥3 拍）⇒ 已换成本式。"""
    ctl = _count_both([True] * 5, [True] * 5)
    dut._log.info("WP0MIN-RUN %s ovl_selftest=%d(expect 5) probe=%s",
                  run_id, ctl, os.path.basename(__file__))


async def _arm(dut, tag, **kw):
    run_id = os.environ.get("WP0MIN_RUN", "r1")
    _emit_run_header(dut, run_id)
    await _run_arm(dut, tag, extra_probe=_sampler, **kw)
    _emit(dut, tag, kw["K"], kw["T"], kw.get("dual", False), run_id)


@cocotb.test()
async def test_fastlane_duty_c1_k4(dut):
    await _arm(dut, "C1-K4-T3", K=4, T=3)


@cocotb.test()
async def test_fastlane_duty_c2_k24(dut):
    await _arm(dut, "C2-K24-T3", K=24, T=3)


@cocotb.test()
async def test_fastlane_duty_pc_halfsel1(dut):
    # 🔴 T=1 ⇒ 只有一次跃迁 ⇒ 结构上产 0 个窗口。**这是结论不是故障**，它只进 G-EXTRACT-2。
    await _arm(dut, "PC-HALFSEL1", K=4, T=1, half_sel=1)


@cocotb.test()
async def test_fld_s_k4(dut):
    await _arm(dut, "S-K4", K=4, T=6, budget=120000)


@cocotb.test()
async def test_fld_s_k48(dut):
    await _arm(dut, "S-K48", K=48, T=6, budget=120000)


@cocotb.test()
async def test_fld_d_k4(dut):
    await _arm(dut, "D-K4", K=4, T=6, budget=120000, dual=True)


@cocotb.test()
async def test_fld_d_k24(dut):
    await _arm(dut, "D-K24", K=24, T=6, budget=120000, dual=True)


@cocotb.test()
async def test_fld_d_k48(dut):
    await _arm(dut, "D-K48", K=48, T=6, budget=120000, dual=True)
