**English** | [简体中文](README.zh-CN.md)

# ScaleNative

ScaleNative is a research prototype of one processing element (PE) of an AI
accelerator: the RTL, its simulation tests, the configuration files for an open-source
layout flow, and the draft of a paper. The PE has a matrix unit (the Tensor unit, a
systolic array for GEMM) and a vector unit (the Vector unit) behind one small control
core. The question studied is what happens when the matrix unit hands its results to
the vector unit as block-scaled data, that is, as blocks of mantissas that share one
scale, instead of converting them to scalar floating point first, and under which
conditions that is worth doing. The name refers to results staying in their native
block-scaled form across this hand-off.

This is work in progress. The paper is a draft with many placeholders, the RTL
implements only part of the design the paper describes, and this first public release
has not yet been exercised in the directory layout you see here. Please read
[Status](#status) and [Known limitations](#known-limitations) before using anything
in this repository.

> **MX status in release `v0.2.0`**
>
> This design covers a subset of the OCP Microscaling (MX) formats: MXFP8 with E4M3
> elements, MXFP4 and MXINT8, with E8M0 block scales. It is not a complete MX
> implementation, and we do not describe it as MX support.
>
> - **Done, checked for a single multiply-accumulate cell only:** multiply-accumulate
>   with MXFP8 (E4M3), MXFP4 and MXINT8 operands and E8M0 block scales. The array is
>   built for blocks of 32 elements along K.
> - **Done in the Vector unit, with unit-level tests:** a compact store for MXFP4 and
>   MXFP8. It writes one E8M0 scale for every 16 elements, so it is not an OCP MX
>   block-32 container.
> - **Not done:** GEMM with MX operands at array level (never simulated); scale
>   loading for K above 32; a path that takes GEMM results into MX storage; MXFP6
>   (planned).
> - **Not planned:** FP8 with E5M2 elements.
> - **Hand-off blocks:** the blocks that the Tensor unit hands to the Vector unit use
>   an internal format with NVFP4-style block-16 granularity (16 mantissas share one
>   power-of-2 exponent). We do not claim NVFP4 support.
>
> Details are in items 15 to 17 of [Known limitations](#known-limitations).

A Chinese version of this document is in [README.zh-CN.md](README.zh-CN.md). Where
the two differ, the English version is the reference.

## Status

Release `v0.2.0` is the first public release. It is meant for co-authors and other
readers of the paper draft. It is not a finished artifact.

**What the RTL in this release implements**

- One PE top level (`pe_top`): an Ibex RV32IMC control core (vendored from lowRISC),
  a 2 KiB instruction memory and a 4 KiB data memory, a command processor with four
  contexts that fetches 32-byte descriptors from rings and dispatches them, and a DMA
  engine with 32-bit ingress and egress stream ports.
- The Tensor unit: a 16 x 16 output-stationary systolic array of multiply-accumulate
  cells. Each cell is built from 4-bit by 4-bit multipliers and accepts BF16, MXINT8,
  two FP8 (E4M3) or four FP4 operands per step, with a wide floating-point
  accumulator. At the array exit, each row of 16 results is turned into one block:
  16 mantissas of 16 bits and one shared exponent, plus metadata.
- The hand-off: a small valid/ready FIFO carries these blocks from the Tensor unit
  to the Vector unit. The Vector unit checks the block size, scale format and epoch
  of each block on arrival.
- The Vector unit: one core with 16 lanes of 16-bit signed mantissas and a shared
  block exponent. The path that is wired from end to end at PE level is: take a
  GEMM result from the hand-off, add a second operand read from local memory
  (residual add), and store the sum to local memory. At PE level this path has been
  tested for its handshakes, not yet for its values. Other functions exist in the
  Vector RTL and have unit-level tests, among them a compact store for MXFP4 and
  MXFP8 and reduction units, but not all of them can be used from the PE top level
  (see Known limitations).
- A 32 KiB local memory (L2) shared by the Tensor unit, the Vector unit and the DMA
  engine.

**The paper describes the target design, not this RTL**

The paper and its architecture figures are written for the design we are working
towards. Where that design is not decided yet, or no data exist yet, the paper has
placeholders. The right-hand column of the table below lists targets and planning
points. None of them is implemented in this release, and none of the numbers in that
column is a measured result.

| Area | RTL in this release | Target design in the paper (not implemented) |
|---|---|---|
| Vector cores | One Vector unit with 16 lanes | Two Vector cores per PE. Each of the two drain ports of the Tensor unit feeds one core. The PE keeps all of its functions when one core is masked. Two forms are still candidates: a pipeline core plus a general core, or two identical cores |
| Vector operations | Pack and unpack, split and merge, residual add, rescaling, block reductions. No exponential, no general multiplication, no top-k selection | Adds the operations the workload needs. Index-score post-processing and top-k selection are placed in a Vector core, not at the entry of the hand-off. Which of the two cores hosts them is open |
| Tensor throughput | 1024, 512 and 256 multiply-accumulates per cycle with FP4, FP8 and BF16 operands (MXINT8 also runs at 256) | Planning point: the 4-bit and 8-bit tiers are enlarged to 2048 and 1024 per cycle. The BF16 tier stays at 256 |
| Fixed overhead per tile | The tile controller spends a fixed 56 cycles per tile outside the multiply-accumulate steps, in addition to the operand reload | Planning point: 5 cycles. It will be revisited when synthesis results exist |
| Tensor operands | Every command reloads all operands | One operand stays resident and is double-buffered. The other streams in from local memory |
| Local memory (L2) | 32 KiB | 128 KiB per PE as the starting point |
| Control memories | 2 KiB instructions, 4 KiB data | 4 KiB and 8 KiB |
| PE boundary | 32-bit stream ports and a separate boot port. No network interface | An on-chip network endpoint. Planning point: a local port with a payload of 64 bytes per cycle. Boot through the network. Design in progress |
| Beyond one PE | Nothing. There is no multi-PE RTL | A two-dimensional mesh of PEs with a shared memory (L3) at its edge. Planning range for L3: 128 to 256 MiB for one 8 x 8 mesh. Design in progress. System-level results in the paper come from modelling |
| PE types | One PE design | Identical PEs, with provision for a second PE type: capability bits in the idle report of a PE and in the task descriptor, and the second Vector core as a generation-time parameter |
| Errors | Execution errors do not reach the command processor | Errors are collected by the command processor. A failed hand-off ends in a visible error |
| Result identity and publication | Blocks carry no task identity. No object table, reader lease or publish step | Blocks carry context, tag and row index. Results are published or aborted through an object table |
| Storing block results | Mantissas only, except for the compact MXFP4 and MXFP8 store | Mantissas plus an exponent side record with metadata, so that a stored result can be read back and consumed |
| Number formats | The cell-level modes listed above. MX checked at cell level only | Adds MXFP6, array-level MX with scale loading for K > 32, and MX storage of GEMM results |
| Attention precision and kernels | Nothing specific. A tile has one format for both operands | The query of the attention core is quantized to 8 bits, so that the core runs in the 8-bit tier. Online softmax and top-k selection may differ from the reference software kernels, and the paper will state each difference. The effect on model quality is not evaluated in this project |
| Sparsity | Sparse descriptors are accepted but not implemented | N:M sparsity as an optional layer, limited to what has been verified |
| Hand-off variants | Block-scaled direct hand-off only | Several hand-off arrangements are compared: block-scaled or scalar, direct or through local memory, and fusion at the producer |

Three parts of the target design are still open, and the paper has placeholders for
them:

- the form of the two Vector cores, with their lane count, their division of work
  and the place of the output accumulator of attention. Both candidate forms have to
  be modelled first;
- the on-chip network and the plan for merging the RTL changes. Their design
  documents are still being revised;
- the effect of the per-tile overhead levels on the achievable frequency, which has
  not been measured.

The source of the paper's performance data is not decided either. The near-term
steps that close the gaps in the table, and the longer-term directions, are listed
in [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md).

**MX formats**

The MX status box at the top of this page is the reference. We call what this
release covers a subset of the OCP MX formats, and we do not call it MX support: the
three formats are checked for a single multiply-accumulate cell only, and the compact
store of the Vector unit is not an OCP MX block-32 container. FP8 with E5M2 elements
is not planned. MXFP6 is planned and not implemented. The blocks handed from the
Tensor unit to the Vector unit are an internal format with NVFP4-style block-16
granularity, and we do not claim NVFP4 support.

**What has been run**

- Simulation: the regression run by `run_all.py`, which covers 61 of the 66 test
  files, passed when it was last run in our private development tree, which uses a
  different directory layout. It has not been run in this repository's layout.
- Layout: the PE top level, the Tensor unit and the Vector unit have each been taken
  through synthesis, placement, routing and GDS generation with OpenROAD-flow-scripts
  on the ASAP7 predictive PDK. These runs used the RTL from before the latest RTL
  change (see Known limitations). The flow has not been set up from a clean checkout
  by following the instructions in this repository.

## Repository layout

```
rtl/         RTL written for this project
  IBEX_SRAM/   PE top level, command processor, memories, DMA, hand-off FIFO
  Tensor/      Tensor unit
  Vector/      Vector unit
tb/          cocotb tests, SystemVerilog test benches, the test runner
Model/       golden model in Python, used by the tests
designs/     design configurations for OpenROAD-flow-scripts
  asap7/       the seven configuration directories used for the paper's layouts,
               with the constraint files and hook scripts they share
  src/         the copy of the RTL that the flow reads, including the vendored Ibex core
patches/     patches to upstream flow scripts and to one SRAM library file
scripts/     helper scripts: fetch the external dependencies, start the flow
docs/        build guide and future work
paper/       paper draft and figures (not under the Apache-2.0 license, see below)
LICENSE, LICENSES/, NOTICE, AUTHORS
```

The seven configuration directories are `aichip_pe_top` (PE top level),
`aichip_vector` and `m1v_mc2f` (Vector unit), and `aichip_tensor_signoff`,
`m1t_adder`, `m1t_pnr` and `m1t_b58k1bv2` (Tensor unit). In each chain the later
directory includes the earlier ones. Two more directories, `m1t_b5` and `m1t_k1b`,
hold one hook script each that the Tensor chain uses. The directory names are
historical.

Only ASAP7 configurations are included. The RTL still contains `PDK_SKY130` and
placeholder `PDK_NANGATE45` branches in the memory and clock-gate wrappers. No
configuration for them is part of this repository.

OpenROAD, Yosys, OpenROAD-flow-scripts, the ASAP7 PDK and the ASAP7 SRAM macros are
not redistributed here. `scripts/aichip_setup.sh` fetches them from their upstream
repositories into `_ext/` and `third_party/`, which git ignores.

## Running the simulations and the layout flow

**Neither has been rehearsed in this repository's layout.** For the release, the
path problems found by reading the files were fixed in five files under `tb/`
(`Makefile`, `elaborate_smoke.sh`, `test_pe_top.py`, `test_l1i_real_a7.py` and
`test_srambank_real.py`; only paths were changed), and the golden model directory
was added. Other problems may remain. Treat the commands below as the intended
procedure, and see [docs/BUILD.md](docs/BUILD.md) for versions, dependencies and
details. Running the full test suite in this layout and setting up the flow from a
clean checkout are near-term items in [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md).

Simulation needs Verilator and cocotb. We used Verilator 5.032, cocotb 1.9.2 and
Python 3.13. cocotb 2.x does not work with these tests.

```sh
cd tb
python3 run_all.py              # every test_*.py that carries build information (61 of 66); one line per file and a total
python3 run_all.py mac_lru      # only the test files whose name contains "mac_lru"
```

The reference snapshots under `tb/baseline/` were captured from an earlier RTL
revision and have not been captured again on the RTL in this repository. The default
regression does not read them. They are compared only when `GEMM_SNAP_CHECK` is set.
Capture them again before you compare against them.

The layout flow needs OpenROAD-flow-scripts with its tools, the local patch in
`patches/`, and the ASAP7 SRAM macro package. We used OpenROAD
`26Q3-2676-g943a4d2c92` and Yosys 0.68 with the slang front end, on
OpenROAD-flow-scripts commit `49416916f08c`.

```sh
bash scripts/aichip_setup.sh    # fetch OpenROAD-flow-scripts and the SRAM macros, apply the patches
# build the tools inside _ext/OpenROAD-flow-scripts as its documentation describes, then:
bash scripts/aichip_run.sh asap7/m1v_mc2f/config.mk LEC_CHECK=0    # Vector unit, the smallest design
```

## Known limitations

This section lists the problems we know of that affect how the repository can be used
or what can be concluded from it. It is updated with every release. Planned work that
is not a defect is in [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md).

### This release

1. **Not exercised in this directory layout.** The tests and the flow were developed
   in a private tree with a different layout. In this layout the test suite has not
   been run and the flow has not been built from the instructions. Expect path
   problems.
2. **The layouts predate the current RTL.** The three layout runs that the paper reports
   were produced from the RTL as it was before a numerical correction to the
   sum-of-squares unit of the Vector unit (three files: `vec_pkg.sv`,
   `vector_unit.sv`, `vec_reduce_cluster.sv`). That earlier RTL revision is not in
   this repository. The synthesis and timing check planned for this correction has
   not been run, so its effect on area and timing is not known. After those runs the
   RTL also received two corrections that change comments only, one line in
   `vector_unit.sv` and two lines in `mac_cell.sv`. They do not change the logic.
3. **The layouts are not DRC-clean.** Four routing design-rule violations remain in
   the PE top-level run: one metal spacing violation on M2, and three end-of-line
   keep-out violations on M4 at SRAM macros of the Tensor unit. The Tensor unit run
   also ends with routing violations at its SRAM macros. The Vector unit run ends
   with none.
4. **Obsolete `fakeram` declarations.** Three configuration files still contain five
   lines that declare the ASAP7 `fakeram7_256x32` model: two lines each in
   `aichip_pe_top/config.mk` and `aichip_tensor_signoff/config.mk`, and one
   `GDS_ALLOW_EMPTY = fakeram.*` line in `m1t_adder/config.mk`. They are leftovers.
   The layouts contain no `fakeram` instance: all 33 memories of the PE (12 of them
   in the Tensor unit) are `srambank_128x4x64_6t122` macros, and the Vector unit has
   no memory macro. The lines are published as they are and will be removed when the
   layouts are next re-run. Some comments in these files that say `fakeram` must be
   kept are out of date.
5. **The Tensor base configuration cannot be run on its own.**
   `aichip_tensor_signoff` is the common root of the Tensor chain and does not
   declare the SRAM macro library. When we last ran it on its own it failed in the
   synthesis front end. Use `m1t_b58k1bv2`, which includes the rest of the chain.
6. **Only seven configurations are included.** Whether this reduced set is
   self-contained has been checked by reading the files, not by running them.

### RTL: function

7. **Vector errors do not reach the command processor.** `pe_top` leaves the Vector
   unit's error outputs unconnected, so a Vector command that ends in an error is
   reported as completed. Operand timeouts, operands arriving in the wrong order and
   block-size mismatches therefore produce wrong data without any error indication.
8. **Only one Vector command can be used on GEMM results at PE level.** It is the
   residual add with its second operand in local memory. The residual add of two
   blocks from the hand-off never receives its second operand, because the Tensor
   unit marks every block as a first operand. The load, activation and plain store
   commands are set up for block size 32, while the Tensor unit produces block size
   16, so blocks that arrive from the Tensor unit while one of them is active are
   flagged as a mismatch. Because of item 7, these cases end as "completed".
9. **Unimplemented sparse modes are accepted.** Descriptors that select 2:4 or 1:4
   sparsity (BF16 or MXINT8, output-stationary) are accepted and executed, but the
   per-cell selection path does not exist. The results are wrong and no error is
   raised. Do not use the sparse modes.
10. **A mismatch at the hand-off is not reported as such.** When a block does not
    match what the Vector unit expects, the pipeline stalls and the command ends
    about 1023 cycles later with an operand-timeout code.
11. **Blocks carry no task identity.** Context and tag are tied to 0 where blocks
    leave the Tensor unit, and the Vector unit does not check them. With two or more
    producer streams in the same epoch, a consumer could take another stream's
    block. This has not been simulated.
12. **Rows with special values are dropped.** A result row that contains NaN or
    infinity, or that cannot be represented with one shared exponent, is discarded
    at the entry of the hand-off FIFO instead of ending in an error. The effect of
    the missing row on the consumer has not been characterised.
13. **Clock gating and soft reset on the hand-off path.** If the Tensor clock is
    gated while its output is valid, the FIFO, which is always clocked, can accept
    the same block repeatedly. A soft reset issued while the Vector clock is gated
    is not seen by the Vector unit. Both follow from reading the RTL and have not
    been reproduced in simulation. A further soft-reset hazard that exists only in
    the netlist is described in item 32.
14. **Local memory behaves differently in simulation and in the ASAP7 netlist.** In
    simulation the memory wrapper is a true dual-port memory with byte masks. The
    ASAP7 branch maps it onto a single-port macro: a write wins over a read on port
    A, which wins over a read on port B, both ports share one output, and byte masks
    are ignored. A read that loses is still flagged valid and returns old data or
    the data of the other address. Nothing in the L2 arbiters prevents two such
    accesses to one bank in the same cycle.
15. **MX is verified at cell level only.** GEMM with MX operands has not been
    simulated at array level. The tile descriptor has no scale-format field, so the
    array always uses E8M0 scales, and scale loading is expected to be correct only
    for K up to 32. There is no path that takes GEMM results into MX storage.
16. **The compact store is not an OCP MX block-32 container.** It writes one E8M0
    scale for every 16 elements, also when block size 32 is selected. Statements
    about storage size that assume one scale per 32 elements do not apply to it.
17. **Silent fallbacks in the Vector store.** A store of MXINT8 data, or a compact
    store whose scale is not a power of 2, is written as the full 256-bit internal
    payload, without a scale side record and without an error flag.
18. **A stored block result cannot be read back with its scale.** The ordinary store
    writes mantissas only. Inside the PE there is also no path that feeds a stored
    result into the next GEMM: only the output-stationary mode is reachable and
    there is no transpose step. A second consumer exists only inside the Vector unit
    (the residual add of item 8). The direct path from the Vector unit back to the
    Tensor unit is tied off at the PE top level.
19. **Descriptor bounds are checked only at the start.** The command processor
    compares only the first row of an access with the region size. The address
    arithmetic can wrap, the address of the scale side record is not checked, and
    writes to the region table are not validated.
20. **The reduction units cannot be reached.** The maximum and sum-of-squares
    datapaths are in the Vector RTL, the latter with its numerical correction, but
    no command of the command processor uses them.
21. **The PE boundary is a placeholder.** The network address field of the stream
    port is not used and the `last` flag of the ingress stream is not checked. Local
    memory is not in the address space of the control core. Results leave the PE
    only through a DMA evict.
22. **No operand reuse.** Every Tensor command reloads all of its operands. Cycle
    counts taken from this RTL include that cost.

### Verification

23. **The hand-off is checked at PE level for handshakes only.** PE-level tests
    confirm that blocks leave the Tensor unit and are consumed by the Vector unit.
    The rows that the Vector unit then writes to local memory have not been read
    back and compared with the golden model. The parts of the path are tested for
    their values separately, at unit level. The PE-level hand-off tests
    (`test_fastlane_*`) are not run by `run_all.py`.
24. **All regression tests use the behavioural memory model.** The ASAP7 macro
    branch of the memory wrapper is exercised by one test at wrapper level
    (`test_l1i_real_a7`), which shows the differences in item 14. A second test
    (`test_srambank_real`) checks the Verilog model of the macro by itself. There is
    no test that compares the two branches under the same stimulus, and no test of
    L2 under contention with the macro branch.
25. **Some assertions do not check anything.** Of the 99 assertions bound to
    `pe_top`, three use constructs that Verilator turns into black boxes and are not
    evaluated. The overflow and underflow assertions of the hand-off FIFO, and its
    two sticky flags, can never fire because of how their conditions are written.
26. **Pitfalls of the test runner.** `run_all.py` exits with success when its filter
    matches no test. When `make` is called directly, its exit code does not tell
    whether the cocotb tests passed; read the `PASS=`/`FAIL=` summary. All tests
    share one build directory, so do not run two at the same time.
    `test_rv32_asm_xcheck` passes without checking anything when the RISC-V binutils
    are not installed.
27. **Missing resets are not detected by default.** Verilator initialises all
    signals to 0, which is also the reset value of most registers. Run with
    `XPROP=1` to randomise initial values.

### Physical implementation

28. **EDA estimates, not silicon.** ASAP7 is a predictive PDK. All physical results
    are post-route estimates from an open-source flow. No sign-off has been done, no
    logic equivalence check has been run on the layouts, and IR drop, antenna rules
    and timing have not been closed. The clock periods in the constraint files
    (12000 ps for the PE top level, 1670 ps for the two units) are flow settings,
    not achieved frequencies. Timing is not closed in any of the three layouts. In
    their final reports, the Tensor unit run and the Vector unit run end with setup
    violations at the 1670 ps setting, the PE top-level run and the Tensor unit run
    end with hold violations, and all three end with maximum-slew violations. The
    violations are on register-to-register paths inside the design as well as on I/O
    paths. We make no frequency claim. Frequency numbers quoted
    in comments are not claims either (see
    [Internal references in comments](#internal-references-in-comments)).
29. **Mixed corners.** The runs read the standard cells at the platform's default
    fast corner and the SRAM macros at their single 0.7 V, 25 °C characterisation.
    Setup and hold results from these runs do not describe one consistent operating
    condition.
30. **The SRAM macro views are approximate and inconsistent.** The macros come from
    the upstream `asap7_sram_0p0` package. Their timing library is generated, with
    leakage and minimum period given as 0. Their LEF and GDS views disagree in
    the lower half of the macro, so the merged GDS has not been shown to be
    connected at the macro pins; a sample check found open pins there. In the LEF,
    the access routes of three control pins land on the macro's own power stripe.
    The layouts avoid the resulting shorts by shifting the macro placement by 9 nm,
    which is a workaround and not a correction of the macro. One library attribute
    is patched (`patches/`).
31. **The L2 banks use wider macros than they need.** The banks are 32 bits wide
    and are mapped onto 64-bit wide macros with the upper half tied to 0, because
    the package has no usable 32-bit layout. Macro area is larger than a matching
    macro would need.
32. **Reset release is not timed, and soft reset has a known netlist-level hazard.** The
    PE has one asynchronous reset behind a two-stage synchronizer. In the wrapper of
    the Tensor unit this reset is combined with the soft reset of the command
    processor. The constraint files of the PE top level set a false path from the
    reset port and mask the recovery check at every asynchronous reset pin; the
    removal check is kept. The constraint files of the Tensor unit also set a false
    path from their reset port. The reset network that the flow builds is a buffer chain
    and is not balanced. An analysis of earlier netlists estimated that reset
    release differs by one to two clock cycles between regions, and judged this
    acceptable as long as the delay of the reset network plus its skew stays below
    about four cycles. The estimate dates from an earlier RTL revision and from runs
    that included another PDK. The skew was not measured then, and the estimate has
    not been repeated for the layouts of this release. With the recovery check
    masked, timing analysis does not watch this margin. The same analysis found two
    hazards after a soft reset. The asynchronous reset of the Tensor unit takes
    effect one to two cycles later than the synchronous flush of the hand-off FIFO
    and the gate on the completion signal of the Tensor unit. (a) A block in flight
    can therefore enter the flushed FIFO and be consumed by the next residual add as
    its first operand, which corrupts the result without an error. (b) A stale
    completion can pass the gate and leave the scheduler credit of the Tensor unit
    above its limit. Neither hazard can be seen in RTL simulation, and neither has
    been re-analysed on the current RTL and layouts. The analysis proposed a
    firmware workaround, which has not been tested: issue the soft reset twice, the
    second pulse at least five cycles after the first, with no doorbell write in
    between.
33. **The constraint files contain timing exceptions that are assumptions.** Besides
    the reset exceptions of item 32, the constraint files of the PE top level and of
    the Tensor unit contain two more. (a) They pin the dataflow select of the Tensor
    unit to the output-stationary mode with `set_case_analysis`, so paths that exist
    only in the other mode are not timed. (b) They relax a set of quasi-static
    control registers of the tile controller (mode, sparse mode, K and the latched
    tile descriptor) with `set_multicycle_path`, four cycles for setup and three for
    hold. According to the notes in these files, exception (b) relies on the load
    and clear states of the tile controller, which separate the latching of these
    registers from their first use, and it holds for the output-stationary mode
    only. It has to be derived again when those states change, which the planned
    reduction of the per-tile overhead will do. For the Tensor unit run, a hook
    script also removes the setup check on paths to the output ports. The constraint
    file of the Vector unit has none of these exceptions. Timing results from these
    runs hold under these assumptions only.

### The paper

34. **The paper is a draft.** Its text follows the target design. Results are
    placeholders, the source of the performance data is not decided, and the form of
    the two Vector cores is still open. The workload figures are derived from public
    model configurations and reference code, not measured, and the numerical
    experiments use synthetic data.

## Paper and figures

The paper is written in English, as LaTeX source in the `paper/` directory. It builds
through two entry files, `main-acm.tex` (acmart, the primary one) and `main-ieee.tex`
(IEEEtran). How to build either of them is described in
[paper/README-build.md](paper/README-build.md). The Chinese companion text is
[paper/paper.zh-CN.md](paper/paper.zh-CN.md), a Markdown file that follows the
English text paragraph by paragraph. The English text is the reference. The Chinese
text is there for comparison.

Pre-built PDFs of both entry files are in `paper/pdf/`:
[scalenative-draft-acm.pdf](paper/pdf/scalenative-draft-acm.pdf) and
[scalenative-draft-ieee.pdf](paper/pdf/scalenative-draft-ieee.pdf). They are the
share build described in the build guide, which prints the authors' names. The
figures and their source files are in `paper/figures/`.

The paper is work in progress. Many results and several design details are
placeholders, and it will change. The layout figure is an intermediate version and
will be replaced after each full layout run.

The contents of `paper/` are **not** covered by the Apache-2.0 license of this
repository. All rights are reserved by the authors. You may read and cite the paper
and its figures. Please do not redistribute or adapt them without the authors'
permission. See [paper/README.md](paper/README.md).

## Use of generative AI

Generative AI tools were used extensively in this project. Most of the RTL, the
tests, the flow configurations, the documentation and the paper draft were drafted,
revised and reviewed with AI assistants (Anthropic's Claude models, used through
Claude Code), working under the direction of the authors. The authors set the goals,
made the design decisions, and are responsible for the content of this repository.
Commits prepared with an AI assistant carry a `Co-Authored-By` trailer that names the
model. The paper draft does not contain an AI-use statement yet. One will be added in
the form the venue requires when the paper is submitted.

## Versions and tags

The first public commit is tagged `v0.2.0`. There is no `v0.1.0` in this repository:
`v0.1.0` was an earlier version that was not published. Version numbers below 1.0
mean that the project is still changing. Each release updates the Known limitations
section.

## Internal references in comments

The comments in the RTL, the tests, the configuration files and the patches are
published as they are in our development tree. Many of them are written in Chinese.
They are working notes of the authors and were not edited for this release. Please
read them with the following in mind.

- **"User" means the authors.** Many comments were drafted with an AI assistant (see
  [Use of generative AI](#use-of-generative-ai)). Where such a comment says "user",
  in Chinese or in English (for example "user decision"), it is the assistant's word
  for the author who was directing it. It does not mean a customer or any other
  outside party.
- **Reviews, votes and verdicts.** Comments speak of adversarial reviews, of a number
  of reviewers or agents (for example a "114-agent" review), of vote counts and of
  review verdicts. These were internal checks that AI tools ran in several rounds
  during development, and the votes are theirs. They are not peer review of the
  paper and not an audit by a third party.
- **Identifiers of the AI tooling.** A few comments carry identifiers that belong to
  the AI tooling: paths into the tool's configuration directory, run names, run
  identifiers that begin with `wf_`, and names of the tool's memory entries. What
  they refer to is not published, and none of them gives access to anything.
- **Internal documents.** Comments mention internal design notes, decision records
  and issue numbers. Some use the wording of those records, for example that a point
  was decided or approved on a certain date, or that it went through a review step.
  The documents are not published with this repository, and the references can be
  ignored.
- **Process notes.** Some comments tell at length how a mistake came about, or record
  working rules and wording rules that were set at the time (in the Chinese
  comments, with words such as "lesson", "price paid" and "do not write"). A few of
  them are written in the first person. Sentences struck through with `~~` are
  earlier wording that was kept on purpose. All of this can be skipped.
- **Messages printed at run time.** What this section says about comments also
  applies to the error messages, assertion messages and log lines in the RTL, the
  tests and the flow scripts. Many of them are in Chinese, and a few point to
  internal documents.
- **Defect history.** Markers such as `Bug #n`, `pre-fix`, `pre-tapeout audit`,
  `HW-REVIEW` and `chip-killer`, in comments and in test docstrings, mostly describe
  problems that were fixed at the time. Change records in file headers, written
  phase by phase, describe the state at that phase. For the problems that exist now,
  [Known limitations](#known-limitations) is the reference.
- **Old numbers.** Comments quote timing, area and frequency numbers from earlier
  experiments. Those experiments used other RTL revisions, constraints and flow
  recipes, and some of them ran on the SKY130 PDK. None of these numbers is a result
  or a claim of this repository.
- **SKY130 and tape-out wording.** Some comments refer to SKY130, to a tape-out and
  to a tape-out partner. They come from an earlier stage of the project. This
  repository contains ASAP7 configurations only and makes no silicon, sign-off or
  tape-out claim. A few comments call the ASAP7 SRAM macro `tape-out-ready`. That
  means only that the macro has a GDS view: ASAP7 is a predictive PDK and cannot be
  taped out.
- **Other products, commercial tools and "vendor".** Where a comment names another
  company's product or a commercial simulator (NVIDIA H100, VCS, Xcelium), it gives
  the authors' understanding, which was not verified on those products or tools.
  `synopsys translate_off` and `synopsys translate_on` are generic synthesis
  directives. Where Chinese comments speak of a "vendor" file or a "vendor" package,
  they mean the upstream open-source package `asap7_sram_0p0`. There is no
  commercial supply relationship.
- **Earlier wording of the paper.** Some comments use phrases from earlier outlines
  of the paper, for example a "converter-free dataflow" thesis or a "headline"
  result. They are not claims of the current draft.
- **Names of formats.** Comments name OCP MX and NVFP4 where they describe an
  encoding. That names the encoding and is not a statement of conformance. Many
  comments call the 16-element block of the hand-off "NVFP4", and a few call it
  "MX-16" or a "block16 MX block". It is the internal block format described in the
  MX status box: the scale-format field of these blocks carries the code that the
  comments label "NVFP4", but the Tensor unit always emits a power-of-2 scale.
  "compact-MX" and "C-MX" are internal names of the compact store, and "block32 =
  OCP MX (E8M0)" names the pairing of block size and scale format that a command
  selects. Neither means that the stored data is an OCP MX block. For what this
  design does with MX and NVFP4, the MX status box at the top of this page is the
  reference.
- **Earlier names, internal paths and commit identifiers.** File headers and
  comments use earlier names of this project (`H-Tensor`, `AI_Chip`, `aichip`).
  `UPE` and `upe_*` are earlier names of the Tensor unit and its modules, which are
  now called `tensor_*` and `mac_*`. The directory `rtl/Vector/Unchanged/` keeps its
  name from an early snapshot, and some of its files were changed later. "Deployed"
  and "production" refer to the configuration that the top level actually
  instantiates. They do not mean that a product is in use. Comments and docstrings
  also point to internal scripts, logs and directories that are not published; where
  a docstring tells you to write output to such a directory, use any path of your
  own. Run commands in docstrings may still follow the directory layout of the
  development tree (`AI_Chip/tb/`). Commit identifiers quoted in comments and in the
  headers of the reference snapshots under `tb/baseline/` belong to the private
  development history and do not exist in this repository.
- **Files that are not part of the regression.** In `tb/`, the files whose names
  begin with `pending_`, `scratch_`, `_r1_` or `wp0_`, and the files `duty_arm.py`
  and `test_fastlane_dp_rehearse.py`, are probes and measurement aids left from
  development. Some of them can no longer be run as they are. The headers of
  `scratch_pad_probe.py` and `test_vec_pipe6_regression.py` still give earlier file
  names (`retired_scratch_pad_probe.py` and `DRAFT_vec_pipe6_regression.py`).
- **Headers of the reference snapshots.** The header lines of the snapshots under
  `tb/baseline/`, such as `#CSR`, `#CYCLES`, `#TOOL` and `#GROUP`, record the state
  at the time of capture, which was an earlier RTL revision (see
  [Running the simulations and the layout flow](#running-the-simulations-and-the-layout-flow)).
  The snapshot headers under `tb/baseline/r1_dense_xprop1/` still say
  `#GROUP r1_dense`.
- **Comments and code.** Some comments describe earlier states of the design, and
  some references of the form "file:line" no longer point to the right line. Where
  a comment and the code disagree, the code is the reference: it is what was
  simulated and laid out.

## License and acknowledgments

Copyright 2026 The ScaleNative Authors. The authors are listed in [AUTHORS](AUTHORS).

- Files written for this project are licensed under the Apache License 2.0. See
  [LICENSE](LICENSE).
- Files derived from upstream files keep the upstream BSD 3-Clause license. These are
  the two patches in `patches/` and some constraint and configuration files under
  `designs/asap7/` that follow upstream examples. [NOTICE](NOTICE) lists them, and
  the license texts are in [LICENSES/](LICENSES/).
- The vendored Ibex core under `designs/src/aichip_sv/ibex/` is licensed under the
  Apache License 2.0 by lowRISC and its contributors, among them ETH Zurich and the
  University of Bologna.
- The `paper/` directory is not under an open-source license, as described above.

This project builds on the work of others, and we thank them: the Ibex RISC-V core
(lowRISC), OpenROAD and OpenROAD-flow-scripts (The OpenROAD Project), Yosys and the
slang front end, the ASAP7 predictive PDK (Arizona State University) and the ASAP7
SRAM macro package, Verilator, cocotb and KLayout.

## How to cite

A citation entry for the paper will be added when the paper is available. Until
then, please cite the repository at <https://github.com/fifakaka35357/ScaleNative>
and name the release tag you used:

```bibtex
@misc{scalenative2026,
  author       = {Yu, Zheqi and Deng, Jingjing},
  title        = {{ScaleNative}: RTL, tests and layout-flow configuration for a
                  block-scaled matrix-to-vector hand-off in one processing element},
  year         = {2026},
  howpublished = {\url{https://github.com/fifakaka35357/ScaleNative}},
  note         = {Source repository, version 0.2.0. Work in progress}
}
```
