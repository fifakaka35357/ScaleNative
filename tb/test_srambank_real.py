"""
[M-SRAM-A7 2026-08-04] ASAP7 真 SRAM 宏行为模型的首次仿真。

被测件 = third_party/asap7_sram_0p0/generated/verilog/srambank_128x4x64_6t122.v
（22 行，供应商件）。**该文件在本项目里从未被任何仿真跑过** —— 决策条目
`D-A7-REALSRAM-GDS-2026-08-03` 的必交付③ 点的就是它。

🔴 归因订正（2026-08-04 对抗审查）：决策条目把③ 的对象写成「规格 §6.1 的
   真宏 dout 保持语义 never-simulated」。实测那条**两造已等价建模**
   （真宏 :20 「output is latched until next read, independent of writes」
    vs sram_1rw1r_wrapper 行为臂的 douta_q 同样只在 cea&~wea 更新）
   ⇒ 照字面验必然 100% 全绿，是个没有分辨力的用例。
   **真正 never-simulated 的是单端口塌缩的三条后果**，本文件验的是它们：
     · 写优先丢读（write&read 同拍 ⇒ 写赢，dataout 不更新且不报错）
     · 无字节掩码（任何写都是整 64 b，子字写会覆盖整字）
     · deselect 语义（banksel=0 ⇒ 读写都不发生，dataout 保持）
   A/B 端口塌缩那条在 wrapper 层，不在本宏内，归 test_l1i_real_a7（另开）。

口径登记（这些是判据的一部分，换了要重新登记）：
  · `mem [511:0]` 无复位、无 initial ⇒ **未写地址的读值由工具决定**。
    XPROP=0（run_all 默认，tb/Makefile 的 --x-initial 包在 ifeq XPROP,1 内）下
    Verilator 零初始化 ⇒ 读未写地址得 0。本文件把它登记为
    **口径依赖观测**（T6），不作为宏的架构语义主张。
  · 本宏无复位脚 ⇒ 不走 tbreset.preclock_reset；改为「起时钟前把所有输入驱成确定值」。
  · LEF 有 `sdel[N]` 脚而本 verilog 模型与 LIB 都没有（`[WARNING ORD-2001]` 实证）
    ⇒ 该脚在仿真侧不可观测，**本文件不主张它的语义**。

Run: cd tb && make MODULE=test_srambank_real TOPLEVEL=srambank_128x4x64_6t122 \
        VERILOG_SOURCES="../third_party/asap7_sram_0p0/generated/verilog/srambank_128x4x64_6t122.v"
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

DEPTH, DW = 512, 64
MASK = (1 << DW) - 1
CLK_NS = 10


class RefModel:
    """独立重写的参考模型（禁抄 RTL 的写法 —— 抄了就退化成同源复制）。

    契约按供应商注释重述，不按它的 if/else 结构重述：
      · 每个上升沿，只有 banksel=1 时才发生任何事
      · write 与 read 同时为 1 时，**写发生、读不发生**（单端口，写优先）
      · dataout 只在「真的发生了读」的那一拍更新，其余时刻保持
    """

    def __init__(self):
        self.mem = [0] * DEPTH
        self.dataout = 0

    def tick(self, banksel, write, read, addr, wd):
        if not banksel:
            return                      # deselect：读写都不发生，dataout 保持
        if write:
            self.mem[addr] = wd & MASK  # 写优先；同拍的 read 被丢弃
        elif read:
            self.dataout = self.mem[addr]


class Harness:
    def __init__(self, dut):
        self.dut, self.ref = dut, RefModel()
        self.mismatches = []

    async def drive(self, banksel=0, write=0, read=0, addr=0, wd=0, tag=""):
        """驱一拍并做逐拍 diff。返回该拍之后的 dataout。"""
        d = self.dut
        d.banksel.value, d.write.value, d.read.value = banksel, write, read
        d.ADDRESS.value, d.wd.value = addr, wd
        await RisingEdge(d.clk)
        self.ref.tick(banksel, write, read, addr, wd)
        await FallingEdge(d.clk)          # 采样点取下降沿（稳定中拍）
        got = int(d.dataout.value)
        if got != self.ref.dataout:
            self.mismatches.append(
                "%s: dataout got=0x%016x exp=0x%016x (banksel=%d w=%d r=%d addr=0x%03x wd=0x%016x)"
                % (tag, got, self.ref.dataout, banksel, write, read, addr, wd))
        return got

    def check(self, name):
        assert not self.mismatches, "%s —— 与独立参考模型逐拍 diff 失配 %d 处:\n  %s" % (
            name, len(self.mismatches), "\n  ".join(self.mismatches[:10]))


async def setup(dut):
    """本宏无复位脚 ⇒ 起时钟【之前】把所有输入驱成确定值（批5 X-prop 纪律的等价形态）。

    🔴 **本宏没有 reset 端口** —— 这是它的真属性，不是用例缺陷，首跑当场抓到：
       `dataout` 与 `mem` 在整个仿真里**跨用例残留**（cocotb 所有 test 共用一次仿真）。
       ⇒ 参考模型必须**从 DUT 当前状态起手**，不能假定干净上电。
       真硅上的后果 = 上电初值不定、且**没有任何硬件手段可以把 dataout/mem 归零**；
       集成侧要归零只能靠软件先写一遍。这条属规格 §6.1 的披露义务。
    🔴 因此各用例必须用**互不相交的地址块**（T1 0x01x / T2 0x02x / T3 0x03x /
       T4 0x04x / T5 边界探点 / T6 只读 0x1AB），否则会互相污染。
    """
    dut.banksel.value = 0
    dut.write.value = 0
    dut.read.value = 0
    dut.ADDRESS.value = 0
    dut.wd.value = 0
    await Timer(1, "ns")
    # 🔴 时钟必须【每个 test 重起】：cocotb 在 test 结束时会杀掉 start_soon 的协程。
    #    （首版加了「只起一次」的守卫，结果 T2 起全部停在 0 ns —— 已实测纠正。）
    #    寄存器状态不受影响，仍跨 test 残留（本宏无复位脚），故下面仍要播种。
    cocotb.start_soon(Clock(dut.clk, CLK_NS, "ns").start())
    await FallingEdge(dut.clk)
    h = Harness(dut)
    h.ref.dataout = int(dut.dataout.value)     # 从 DUT 现态起手（无复位脚的直接后果）
    return h


@cocotb.test()
async def test_srambank_write_read_roundtrip(dut):
    """T1 基础往返 + 写不改 dout：写那一拍 dataout 必须【保持】前值。"""
    h = await setup(dut)
    await h.drive(banksel=1, write=1, addr=0x011, wd=0xDEADBEEF12345678, tag="T1-w")
    pre = int(dut.dataout.value)
    await h.drive(banksel=1, write=1, addr=0x012, wd=0x0F0F0F0F0F0F0F0F, tag="T1-w2")
    assert int(dut.dataout.value) == pre, "写操作改动了 dataout —— 违反 :20 的 latched 语义"
    await h.drive(banksel=1, read=1, addr=0x011, tag="T1-r1")
    assert int(dut.dataout.value) == 0xDEADBEEF12345678, "回读 0x011 不符"
    await h.drive(banksel=1, read=1, addr=0x012, tag="T1-r2")
    assert int(dut.dataout.value) == 0x0F0F0F0F0F0F0F0F, "回读 0x012 不符"
    h.check("T1")
    dut._log.info("T1 OK: 写往返 + 写不改 dataout")


@cocotb.test()
async def test_srambank_deselect_holds(dut):
    """T2 deselect：banksel=0 时读写都不发生，dataout 保持。"""
    h = await setup(dut)
    await h.drive(banksel=1, write=1, addr=0x020, wd=0xA5A5A5A5A5A5A5A5, tag="T2-w")
    await h.drive(banksel=1, read=1, addr=0x020, tag="T2-r")
    held = int(dut.dataout.value)
    assert held == 0xA5A5A5A5A5A5A5A5
    # deselect 下发一个【会改值的】读写组合：都必须无效
    await h.drive(banksel=0, write=1, addr=0x020, wd=0x0, tag="T2-ds-w")
    await h.drive(banksel=0, read=1, addr=0x0FF, tag="T2-ds-r")
    assert int(dut.dataout.value) == held, "deselect 期间 dataout 被改动"
    # 复选后回读：deselect 那个写必须没落进 mem
    await h.drive(banksel=1, read=1, addr=0x020, tag="T2-post")
    assert int(dut.dataout.value) == 0xA5A5A5A5A5A5A5A5, "deselect 期间的写落进了 mem"
    h.check("T2")
    dut._log.info("T2 OK: deselect 读写双向无效且 dataout 保持")


@cocotb.test()
async def test_srambank_write_beats_read_silently(dut):
    """🔴 T3 单端口塌缩之一：write 与 read 同拍 ⇒ 写赢、读【被静默丢弃】。

    这是本文件最要害的一条：供应商源码 :16 自己写着
    「should have an error assert on read & write at once...」—— 那条 assert
    **不存在**。丢读没有任何错误标志、没有 valid 拉低，下游只会拿到陈旧 dataout。
    集成侧的对应缺陷 = tensor_external_modules 的 .read(re & ~we)（写优先丢读，
    而 act_rd_valid 照拉）。
    """
    h = await setup(dut)
    await h.drive(banksel=1, write=1, addr=0x030, wd=0x1111111111111111, tag="T3-seed0")
    await h.drive(banksel=1, write=1, addr=0x031, wd=0x2222222222222222, tag="T3-seed1")
    await h.drive(banksel=1, read=1, addr=0x030, tag="T3-r0")
    stale = int(dut.dataout.value)
    assert stale == 0x1111111111111111
    # 同拍 write+read：写 0x031，同时想读 0x031
    await h.drive(banksel=1, write=1, read=1, addr=0x031,
                  wd=0x3333333333333333, tag="T3-collide")
    got = int(dut.dataout.value)
    assert got == stale, (
        "写读同拍时 dataout 变了（=0x%016x）—— 与写优先语义不符" % got)
    # 写确实生效了（读被丢的同时写没被丢）
    await h.drive(banksel=1, read=1, addr=0x031, tag="T3-verify-write")
    assert int(dut.dataout.value) == 0x3333333333333333, "同拍的写没有生效"
    h.check("T3")
    dut._log.info("T3 OK: 写优先、读被静默丢弃（无错误标志）——单端口塌缩已取证")


@cocotb.test()
async def test_srambank_no_byte_mask(dut):
    """🔴 T4 单端口塌缩之二：本宏【无字节掩码端口】⇒ 子字写会覆盖整个 64 b 字。

    集成侧后果：sram_1rw1r_wrapper 的 REAL_MACRO 臂把 wmaska_i 静默忽略、
    并把高 (64-DW) 位 tie 0 ⇒ 任何按字节掩码写的调用者都会丢数据。
    """
    h = await setup(dut)
    await h.drive(banksel=1, write=1, addr=0x040, wd=0xFFFFFFFFFFFFFFFF, tag="T4-seed")
    # 只想改低 32 位（LEF/verilog 都没有 wmask 端口可用）
    await h.drive(banksel=1, write=1, addr=0x040, wd=0x00000000CAFEBABE, tag="T4-partial")
    await h.drive(banksel=1, read=1, addr=0x040, tag="T4-read")
    got = int(dut.dataout.value)
    assert got == 0x00000000CAFEBABE, (
        "期望整字被覆盖（无 wmask），实得 0x%016x" % got)
    assert (got >> 32) == 0, "高 32 位没有被覆盖 —— 与「无字节掩码」不符"
    h.check("T4")
    dut._log.info("T4 OK: 无字节掩码，子字写覆盖整字（高 32 b 被清）")


@cocotb.test()
async def test_srambank_addr_span_and_aliasing(dut):
    """T5 地址跨度：ADDRESS[8:0] = 512 字，边界地址与去混叠。

    去混叠：写入的每个字两两互异 ⇒ 任何地址错接都会被读出来
    （PROJECT_RULES §5.0 的去混叠纪律：断言下在可观测量上）。
    """
    h = await setup(dut)
    probes = [0x000, 0x001, 0x0FF, 0x100, 0x1FE, 0x1FF]
    vals = {a: (0x5A5A0000_00000000 | (a * 0x0001_0001)) for a in probes}
    assert len(set(vals.values())) == len(probes), "激励自混叠 —— 用例无分辨力"
    for a in probes:
        await h.drive(banksel=1, write=1, addr=a, wd=vals[a], tag="T5-w%03x" % a)
    for a in probes:
        await h.drive(banksel=1, read=1, addr=a, tag="T5-r%03x" % a)
        got = int(dut.dataout.value)
        assert got == vals[a], "addr 0x%03x 读回 0x%016x 期望 0x%016x" % (a, got, vals[a])
    h.check("T5")
    dut._log.info("T5 OK: 512 字跨度 6 个探点、值两两互异、零错接")


@cocotb.test()
async def test_srambank_unwritten_read_is_caliber_dependent(dut):
    """T6 未写地址的读 —— **口径依赖观测，不是架构语义主张**。

    `mem [511:0]` 无复位无 initial。XPROP=0（run_all 默认）下 Verilator 零初始化
    ⇒ 读未写地址得 0。本用例把该值**登记**下来，并显式声明它不可被引用为
    「真宏上电后读出 0」—— 真硅上是不定值。规格 §6.1 的披露义务落点即此。
    """
    h = await setup(dut)
    await h.drive(banksel=1, read=1, addr=0x1AB, tag="T6")
    got = int(dut.dataout.value)
    dut._log.info("T6 登记：XPROP=0 下未写地址 0x1AB 读出 0x%016x（工具零初始化，"
                  "**禁引用为真宏上电语义**）" % got)
    assert got == 0, ("XPROP=0 下期望工具零初始化得 0，实得 0x%016x —— "
                      "口径变了，判据需重新登记" % got)
    h.check("T6")
