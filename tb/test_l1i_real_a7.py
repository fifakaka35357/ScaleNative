"""[N-5] `sram_1rw1r_wrapper` 在 **REAL_MACRO=1（ASAP7 真宏）** 下的 A/B 端口塌缩 —— 首次仿真。

🔴 **它是什么**：`soc600_prereg §26` 的 `N-5`「A/B 端口塌缩零仿真」。
   在盘文档多处以 `test_l1i_real_a7` 这个名字引用它 —— 本文件**就用这个名字**，
   免得下一个人按名字搜、搜不到、又判「不存在」（`#94` 的假阴性形态）。

🔴 **前作与分工（`§1` 第④条自证）**：
   `AI_Chip/tb/test_srambank_real.py`（2026-08-04）已验**宏自己**的三条语义
   （写优先丢读 / 无字节掩码 / deselect），并**逐字写明**：
       「A/B 端口塌缩那条在 wrapper 层，不在本宏内，归 test_l1i_real_a7（另开）。」
   ⇒ 本文件**不重测宏**，只测 **wrapper 把 1RW1R 塌到单口** 这一层。

被测实现（`sram_1rw1r_wrapper.sv:204-270` 现读，不是凭注释）：
    rd_a     = cea_i & ~wea_i
    mac_re   = rd_a | ceb_i
    mac_we   = cea_i & wea_i
    mac_ra   = rd_a ? addra_i : addrb_i        # 🔴 A 读优先，B 的地址被丢
    mac_addr = mac_we ? addra_i : mac_ra
    read     = mac_re & ~mac_we                # 🔴 写把读整个杀掉
    douta_pre = doutb_pre = mac_do[DW-1:0]     # 🔴 两个口拿【同一份】数据
    (wmaska_i 一根线都没接到宏上)

🔴 **判据的形态 = 「差异必须恰好落在登记过的那几处，别处必须逐位一致」**。
   只测「有差异」是没有分辨力的（差异是已知的）；本文件要**给差异划边界**。
   ⇒ `N6` 是**正控**：互斥前提成立时，DUT 必须与「真 1RW1R」参考模型**逐位相同**。
   没有 N6，前面几条红了也分不清是「塌缩的锅」还是「我的参考模型写错了」。

🔴 **口径登记（换了要重新登记）**：
   · `OUT_REG=0` ⇒ 读延迟 **1 拍**（模块头 `:69` 逐字）。
   · `DEPTH=512, DW=32` —— ASAP7 臂的 `$fatal` 守卫只放行这一组（`:196-201`）。
   · 未写地址的读值**由工具决定**（宏的 `mem` 无复位无 initial）⇒ 本文件
     **只比较写过的地址**，不主张未写地址的值（沿用 `test_srambank_real.py` 的 T6 口径）。

Run:
  cd AI_Chip/tb && make MODULE=test_l1i_real_a7 TOPLEVEL=sram_1rw1r_wrapper \
    VERILOG_SOURCES="../rtl/IBEX_SRAM/sram_1rw1r_wrapper.sv \
      ../third_party/asap7_sram_0p0/generated/verilog/srambank_128x4x64_6t122.v" \
    TEST_EXTRA="-DPDK_ASAP7 -GREAL_MACRO=1"

🔴 **[2026-09-06 订正] 本行原写 `EXTRA_ARGS=`，那条命令【复现不出】上面那次运行。**
   make 的命令行赋值会**覆盖 makefile 里的全部赋值（含 `+=`）** ⇒ 命令行写 `EXTRA_ARGS=`
   会把 `Makefile:19-44` 累积的 `-Wno-*`/`--assert`/`--bbox-unsup` 全部冲掉。
   实证：真宏臂的原始日志 `aichip_run_logs/n5_l1i_real_a7_20260904.log` 里
   `-DPDK_ASAP7` 与 `-Wno-*` **同时出现**（各 2 / 8 次）⇒ 那次用的是 `TEST_EXTRA=`。
   `TEST_EXTRA` 是 `Makefile:74-82` 为此专设的**只增不覆盖**入口。

🔴 **[2026-09-06] 本文件在 `run_all` 口径下会红 —— 这是【实测】不是预测（欠账 `#121`）。**
   `run_all.py:34-36` 只传 `MODULE`/`TOPLEVEL`/`VERILOG_SOURCES`，**不传** `TEST_EXTRA`
   ⇒ 编到 wrapper 的**行为臂**（`sram_1rw1r_wrapper.sv:308` 起的 `else` 分支：真双口、掩码生效）
   ⇒ `N3`/`N4`/`N5` 三条「塌缩后果」当然不成立。
   实测：`run_all` 口径 `TESTS=6 PASS=3 FAIL=3`（`d121_runall_facsimile_20260906.log`）
   vs 真宏臂 `TESTS=6 PASS=6 FAIL=0`（`n5_l1i_real_a7_20260904.log`）。
   ⇒ **测试没毛病，是被跑在了错的配置里。** 处置待拍板（`#121`）。
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

DW, AW, CLK_NS = 32, 9, 10
MASK = (1 << DW) - 1


class True1RW1R:
    """**真 1RW1R** 的参考模型 —— 即调用方【以为】自己拿到的东西。

    🔴 刻意**不照抄 wrapper 的 if/else**（抄了就退化成同源复制，`§4.ap`）：
    这里写的是 1RW1R 的契约本身 —— A 口读写，B 口只读，**两口互不干扰**，
    同拍 A 写 + B 读时 B 仍读到**旧值**（真双口的语义）。
    """

    def __init__(self):
        self.mem = {}
        self.douta = None
        self.doutb = None

    def step(self, cea, wea, wmaska, addra, dina, ceb, addrb):
        # B 口：只读，且在写之前采样（真 1RW1R 的读端口独立于写端口）
        nb = self.mem.get(addrb) if ceb else self.doutb
        na = self.douta
        if cea and not wea:
            na = self.mem.get(addra)
        if cea and wea:
            old = self.mem.get(addra, 0)
            keep = 0
            for b in range(DW // 8):
                if not ((wmaska >> b) & 1):
                    keep |= 0xFF << (8 * b)
            self.mem[addra] = ((dina & ~keep) | (old & keep)) & MASK
        self.douta, self.doutb = na, nb
        return na, nb


async def _init(dut):
    dut.cea_i.value = 0
    dut.wea_i.value = 0
    dut.wmaska_i.value = (1 << (DW // 8)) - 1
    dut.addra_i.value = 0
    dut.dina_i.value = 0
    dut.ceb_i.value = 0
    dut.addrb_i.value = 0
    cocotb.start_soon(Clock(dut.clk_i, CLK_NS, units="ns").start())
    await RisingEdge(dut.clk_i)
    await Timer(1, units="ns")


async def _drive(dut, *, cea=0, wea=0, wmaska=None, addra=0, dina=0, ceb=0, addrb=0):
    dut.cea_i.value = cea
    dut.wea_i.value = wea
    dut.wmaska_i.value = (1 << (DW // 8)) - 1 if wmaska is None else wmaska
    dut.addra_i.value = addra
    dut.dina_i.value = dina
    dut.ceb_i.value = ceb
    dut.addrb_i.value = addrb
    await RisingEdge(dut.clk_i)
    await Timer(1, units="ns")


async def _write(dut, addr, data, wmaska=None):
    await _drive(dut, cea=1, wea=1, addra=addr, dina=data, wmaska=wmaska)
    await _drive(dut)


async def _read_a(dut, addr):
    await _drive(dut, cea=1, wea=0, addra=addr)
    v = int(dut.douta_o.value)
    await _drive(dut)
    return v


async def _read_b(dut, addr):
    await _drive(dut, ceb=1, addrb=addr)
    v = int(dut.doutb_o.value)
    await _drive(dut)
    return v


# ---------------------------------------------------------------- 基线（先证明观测方法有效）
@cocotb.test()
async def test_n1_port_a_roundtrip(dut):
    """N1 正控：A 口写—读回环。它红了 ⇒ 后面所有用例的观测方法都不可信。"""
    await _init(dut)
    await _write(dut, 5, 0xDEADBEEF)
    assert await _read_a(dut, 5) == 0xDEADBEEF, "A 口写读回环坏了 ⇒ 观测方法无效"


@cocotb.test()
async def test_n2_port_b_read_alone(dut):
    """N2 正控：B 口单独读（无并发）必须拿到自己地址的数据。"""
    await _init(dut)
    await _write(dut, 9, 0x11223344)
    await _write(dut, 10, 0x55667788)
    assert await _read_b(dut, 9) == 0x11223344
    assert await _read_b(dut, 10) == 0x55667788


# ---------------------------------------------------------------- N-5 的三条后果
@cocotb.test()
async def test_n3_write_a_kills_read_b_silently(dut):
    """🔴 N3：同拍 A 写 + B 读 ⇒ **B 的读被整个丢掉**，且【不报错】。

    实现依据：`read = mac_re & ~mac_we` ⇒ 写在场时 read 恒 0。
    真 1RW1R 下 B 应当读到 addrb 的旧值。
    """
    await _init(dut)
    await _write(dut, 20, 0xAAAA5555)
    await _write(dut, 21, 0x0F0F0F0F)
    # 🔴 夹具的关键：先让 doutb 停在【与期望值不同】的数上，否则「读发生了」与
    #    「读被丢了」在输出上逐字不可区分（初稿就是这么写的，是个没有分辨力的用例）。
    prev = await _read_b(dut, 21)
    assert prev == 0x0F0F0F0F, "夹具没造出来：doutb 没停在 0x0F0F0F0F"
    # 同拍：A 写 21，B 读 20。若 B 的读发生了 ⇒ doutb 应变成 mem[20]=0xAAAA5555。
    await _drive(dut, cea=1, wea=1, addra=21, dina=0x99999999, ceb=1, addrb=20)
    got = int(dut.doutb_o.value)
    await _drive(dut)
    cocotb.log.info("N3 观测：同拍 A 写 21 + B 读 20 ⇒ doutb_o = 0x%08X"
                    "（真 1RW1R 应为 0x%08X = mem[20]；塌缩则保持 0x%08X）",
                    got, 0xAAAA5555, 0x0F0F0F0F)
    assert got != 0xAAAA5555, "🔴 若 B 拿到了 mem[20]，说明读没被丢 ⇒ 本条登记要重写"
    assert got == 0x0F0F0F0F, "🔴 登记的塌缩后果：B 的读被整个丢掉，doutb 保持上一次的值"
    # 前提自证：这一拍的写确实发生了（否则「读被写杀掉」这个因果链不成立）
    assert await _read_a(dut, 21) == 0x99999999, "写没发生 ⇒ 本用例的前提不成立"


@cocotb.test()
async def test_n4_concurrent_reads_port_b_gets_port_a_data(dut):
    """🔴🔴 N4：同拍 A 读 + B 读【不同地址】⇒ **B 口拿到的是 A 的数据**。

    这比「丢读」更坏 —— 它不是保持旧值，是**返回另一个地址的值**，
    而调用方无法从数值上分辨。实现依据：
        mac_ra = rd_a ? addra_i : addrb_i   （A 读优先，B 地址被丢）
        doutb_pre = mac_do                  （两口同一份数据）
    """
    await _init(dut)
    await _write(dut, 30, 0xCAFEBABE)
    await _write(dut, 31, 0x12345678)
    await _drive(dut, cea=1, wea=0, addra=30, ceb=1, addrb=31)
    da = int(dut.douta_o.value)
    db = int(dut.doutb_o.value)
    await _drive(dut)
    cocotb.log.info("N4 观测：A 读 30 / B 读 31 同拍 ⇒ douta=0x%08X doutb=0x%08X", da, db)
    assert da == 0xCAFEBABE, "A 口应拿到自己的数据"
    assert db == da, "🔴 登记的塌缩后果：B 口拿到的是 A 的数据（不是 addrb 的）"
    assert db != 0x12345678, "🔴 若 B 真拿到了 addrb 的数据，说明塌缩语义变了 ⇒ 本条登记要重写"


@cocotb.test()
async def test_n5_byte_mask_is_ignored(dut):
    """🔴 N5：`wmaska_i` 被完全忽略 ⇒ 子字写会**覆盖整字**。

    实现依据：`wmaska_i` 在 `g_real_macro` 里一根线都没接到宏上。
    对照：`l2_rw_arbiter.sv:402` 的 DMA fill **会**产出部分字节使能。
    """
    await _init(dut)
    await _write(dut, 40, 0xFFFFFFFF)
    await _write(dut, 40, 0x000000AA, wmaska=0b0001)   # 只想写最低字节
    got = await _read_a(dut, 40)
    cocotb.log.info("N5 观测：掩码 0b0001 写 0x000000AA 之后读回 0x%08X", got)
    assert got == 0x000000AA, "🔴 登记的塌缩后果：掩码被忽略，整字被覆盖"
    assert got != 0xFFFFFFAA, "🔴 若高字节被保住，说明掩码生效了 ⇒ 本条登记要重写"


# ---------------------------------------------------------------- 🔴 正控：给差异划边界
@cocotb.test()
async def test_n6_matches_true_1rw1r_when_premise_holds(dut):
    """🔴🔴 N6 正控：**互斥前提成立时**（任一拍最多一个口在用），
    DUT 必须与「真 1RW1R」参考模型**逐位相同**。

    没有这一条，N3/N4/N5 的红票分不清是「塌缩」还是「我的参考模型写错了」
    —— 两者在输出上不可区分（`§4.ap`：两道防线共用一个前提就只是一道）。
    """
    await _init(dut)
    ref = True1RW1R()
    seq = [
        dict(cea=1, wea=1, addra=100, dina=0x01020304),
        dict(cea=1, wea=1, addra=101, dina=0x05060708),
        dict(cea=1, wea=0, addra=100),
        dict(ceb=1, addrb=101),
        dict(cea=1, wea=1, addra=100, dina=0xA0B0C0D0),
        dict(cea=1, wea=0, addra=100),
        dict(ceb=1, addrb=100),
    ]
    for i, st in enumerate(seq):
        cea, wea = st.get("cea", 0), st.get("wea", 0)
        ceb = st.get("ceb", 0)
        assert not (cea and ceb), "本用例的前提就是互斥，夹具自己不许违反"
        ea, eb = ref.step(cea, wea, (1 << (DW // 8)) - 1,
                          st.get("addra", 0), st.get("dina", 0), ceb, st.get("addrb", 0))
        await _drive(dut, **st)
        if cea and not wea:
            assert int(dut.douta_o.value) == ea, f"步 {i}: A 口与真 1RW1R 不符"
        if ceb:
            assert int(dut.doutb_o.value) == eb, f"步 {i}: B 口与真 1RW1R 不符"
        await _drive(dut)
