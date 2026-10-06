**English** | [简体中文](BUILD.zh-CN.md)

# Build and run guide

This guide describes how the simulation tests and the layout flow of ScaleNative are
meant to be run. A Chinese version is in [BUILD.zh-CN.md](BUILD.zh-CN.md). Where the
two differ, the English version is the reference.

## 1. Read this first

**Nothing in this guide has been rehearsed in this repository's directory layout.**
The tests and the flow were developed and run in a private tree with a different
layout. For this release the files were moved into the layout you see here, the
path problems found by reading the files were fixed (in five files under `tb/`,
listed in section 2), and the golden model directory was added. The test suite has
not been run here, and the flow has not been set up from a clean checkout by
following this guide. The helper scripts in `scripts/` were written for this release
and have not been run from a clean checkout.

What this means in practice:

- A command below may fail because of a path that was not adjusted. If it does, the
  cause is most likely in this repository and not in your setup.
- The tool versions listed are the ones we used. We have not tried others.
- Running the full test suite in this layout, and setting up the flow from a clean
  checkout, are near-term items in [FUTURE_WORK.md](FUTURE_WORK.md). This guide will be
  corrected when that is done.

The limitations of the RTL, the tests and the layouts themselves are listed in the
[README](../README.md#known-limitations).

## 2. What is in the repository and what is not

In the repository:

| Path | Content |
|---|---|
| `rtl/` | The RTL written for this project (`IBEX_SRAM/`, `Tensor/`, `Vector/`) |
| `tb/` | cocotb tests (`test_*.py`), SystemVerilog test benches (`tb_*.sv`), the cocotb `Makefile`, the runner `run_all.py`, and the lint sweep `elaborate_smoke.sh` |
| `Model/` | The golden model in Python (`bfp_golden.py`) that the tests import |
| `designs/asap7/` | Seven design configuration directories, the two constraint files they share, and two directories (`m1t_b5/`, `m1t_k1b/`) that hold only a hook script used by the Tensor chain |
| `designs/src/aichip_sv/` | The copy of the RTL that the flow reads, with the vendored Ibex core in `ibex/` |
| `patches/` | `orfs-local.patch` for the flow scripts of OpenROAD-flow-scripts, and `sram-bitwidth.patch` for one library file of the SRAM macro package |
| `scripts/` | `aichip_setup.sh` (fetch dependencies, apply patches), `aichip_run.sh` (start the flow for one configuration), `rename_gds_top.py` (used by the setup script) |
| `docs/` | This guide and the future-work document |
| `paper/` | The paper draft: LaTeX sources, the Chinese companion text and the figures. It is built separately, see [paper/README-build.md](../paper/README-build.md) |

Not in the repository, to be obtained separately:

- OpenROAD, Yosys and the other tools of the flow.
- OpenROAD-flow-scripts, which also provides the ASAP7 platform files.
- The ASAP7 SRAM macro package `asap7_sram_0p0`.
- Layout results. No GDS, DEF, netlist, report or log file of our runs is included.

`rtl/` and `designs/src/aichip_sv/` hold the same project RTL twice: the tests read
the first, the flow reads the second. The second also contains the Ibex core, which
the PE-level test reads from there.

Compared with our development tree, five files under `tb/` were edited, and only in
their paths: `Makefile`, `elaborate_smoke.sh`, and the source lists in the
docstrings of `test_pe_top.py`, `test_l1i_real_a7.py` and `test_srambank_real.py`.
All other files under `rtl/`, `tb/`, `Model/` and `designs/` are unchanged copies.

Eight files under `tb/` are not part of the regression: `_r1_preproof.py`,
`pending_test_tensor_sparse_stall.py`, `scratch_guard_probe.py`,
`scratch_ivd_probe.py`, `scratch_pad_probe.py`, `scratch_sticky_probe.py`,
`wp0_bind_rehearse.py` and `wp0_min_probe.py`. Seven of them are probes written for
single experiments, some of them retired. `pending_test_tensor_sparse_stall.py` is a
retired test whose test bench has been removed, so it cannot be run. `run_all.py`
does not pick these files up, because their names do not start with `test_`. They
are kept because comments in the RTL refer to four of them. The launch scripts that
their header notes mention are not published.

## 3. Versions

These are the versions on the machine that produced the most recent simulation and
layout runs. Other versions have not been tried, except where noted.

| Item | Version we used | Note |
|---|---|---|
| Operating system | Ubuntu 26.04.1 LTS | |
| Verilator | 5.032 | Distribution package |
| cocotb | 1.9.2 | cocotb 2.x does not work: some tests use interfaces that 2.x removed or renamed |
| Python for cocotb | 3.13 | In a virtual environment. cocotb 1.9.2 with Python 3.14 is untested |
| GNU make, GCC | 4.4.1, 15.2 | |
| RISC-V binutils | `riscv64-unknown-elf-as` 2.45 | Needed by one test only, see 4.5 |
| OpenROAD-flow-scripts | upstream commit `49416916f08ca3640464c755aed883c25d25a153` | Plus `patches/orfs-local.patch` |
| OpenROAD | `26Q3-2676-g943a4d2c92` | The submodule commit of the flow scripts at that commit |
| Yosys | 0.68+ (`a5af9d690`), with the slang front end | The submodule commit of the flow scripts at that commit |
| KLayout | 0.30.12 | For the GDS merge and for the setup script |
| ASAP7 platform files | As shipped in OpenROAD-flow-scripts at the commit above | |
| `asap7_sram_0p0` | commit `9f5af0939e8dd3cc1a9693a50b23441691dd7d25` | Plus `patches/sram-bitwidth.patch` |

The upstream container image tagged `26Q3-661-g49416916f` corresponds to the same
flow-scripts commit. We used it once to cross-check the upstream `gcd` example, not
for the designs in this repository.

## 4. Simulation

### 4.1 Setup

Install Verilator and create a Python environment with cocotb 1.9.2:

```sh
python3.13 -m venv ~/.venvs/scalenative
. ~/.venvs/scalenative/bin/activate
pip install "cocotb==1.9.2"
```

### 4.2 Run all tests

```sh
cd tb
python3 run_all.py > run_all.txt 2>&1
tail -n 80 run_all.txt
```

`run_all.py` reads, from the docstring of each `test_*.py`, the top-level module and
the list of source files, and calls `make` once per test file. It cleans the build
directory before each test. At the end it prints one line per test file and a total:

```
  ----- TOTAL: PASS=<n> FAIL=<f> across <k> files -----
```

Five test files have no build information in their docstring (the four
`test_fastlane_*` files and `test_wd124_poscontrol`). They are listed as `NO-META`
and are not run by `run_all.py`. On our machine the whole suite takes about 50
minutes. It runs on one thread and rebuilds the simulator for every test file.

### 4.3 Run part of the suite, or one test

```sh
cd tb
python3 run_all.py mac_lru        # the test files whose name contains "mac_lru"

make clean
make MODULE=test_mac_lru TOPLEVEL=mac_lru \
     VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_lru.sv"
```

The exact `make` line of every test is in the `Run:` block of its docstring.

### 4.4 Reading the result

- Look at the `PASS=`/`FAIL=` numbers. When `make` is called directly, its exit code
  does not tell whether the cocotb tests passed.
- `run_all.py` exits with 0 when its filter matches no test file. Check that the
  number of files in the total line is what you expect.
- All tests build into the same `tb/sim_build` directory. Do not run two tests, or
  a test and `run_all.py`, at the same time. Run `make clean` when you change the
  top-level module by hand.

### 4.5 Tests with extra requirements

| Test | Needs |
|---|---|
| `test_rv32_asm_xcheck` | `riscv64-unknown-elf-as`. The test compares the small assembler in `tb/rv32_asm.py` with the real one. Without the tool it passes without checking anything |
| `test_pe_top` | The Ibex sources under `designs/src/aichip_sv/ibex/`, which are in the repository |
| `test_l1i_real_a7`, `test_srambank_real` | The Verilog model of the SRAM macro, `third_party/asap7_sram_0p0/generated/verilog/srambank_128x4x64_6t122.v`. It is not in the repository; `scripts/aichip_setup.sh` fetches the package (section 5.1). `test_l1i_real_a7` also needs the compile flags given in its docstring; `run_all.py` passes them |

### 4.6 Options

- `XPROP=1 XSEED=<n>` randomises the initial value of every signal instead of
  setting it to 0. Use it with two different seeds to find registers that depend on
  their initial value: `XPROP=1 XSEED=1 python3 run_all.py <filter>`.
- `TEST_EXTRA="..."` appends compile flags for one `make` call. Do not pass
  `EXTRA_ARGS` or `COMPILE_ARGS` on the command line: a command-line assignment
  replaces the flags that the `Makefile` and cocotb set.

### 4.7 Lint sweep

```sh
bash tb/elaborate_smoke.sh
```

This runs `verilator --lint-only` over the packages and a set of representative
modules and prints PASS or FAIL for each. One of its targets reads the SRAM macro
model mentioned in 4.5.

## 5. Layout flow

### 5.1 Fetch the dependencies

```sh
bash scripts/aichip_setup.sh
```

The script creates two directories in the repository root. Both are ignored by git.

- `_ext/OpenROAD-flow-scripts/`: OpenROAD-flow-scripts at the commit in section 3,
  with its submodules, and with `patches/orfs-local.patch` applied.
- `third_party/asap7_sram_0p0/`: the SRAM macro package at the commit in section 3,
  with `patches/sram-bitwidth.patch` applied, and with one extra GDS file (see
  below).

It stops at the first step that fails. If a patch does not apply, do not force it:
the patches were written for the pinned commits.

The script does not build the tools. Build OpenROAD, Yosys and the rest inside
`_ext/OpenROAD-flow-scripts/` as the OpenROAD-flow-scripts documentation describes.

Three details, in case you set things up by hand:

- **The flow patch.** It changes four flow scripts (`cts.tcl`, `detail_route.tcl`,
  `floorplan.tcl`, `util.tcl`). It adds `SKIP_FLOORPLAN_REPAIR`, which skips timing
  repair in the floorplan stage; the configurations set this variable, and without
  the patch it is ignored and the results differ. It also adds two optional
  arguments (`DPL_MAX_DISPLACEMENT` for legalisation after clock-tree synthesis,
  `MAX_BUFFER_PERCENT` for timing repair) and a checkpoint of the routed database
  before antenna repair.
- **The location of the SRAM package.** The configuration files find it relative to
  the flow directory, as `$(FLOW_HOME)/../../../third_party/asap7_sram_0p0`. With
  the flow scripts at `<A>/<B>/OpenROAD-flow-scripts`, the package has to be at
  `<A>/third_party/asap7_sram_0p0`. The script's layout satisfies this.
- **The renamed GDS.** The configurations read
  `gds/srambank_128x4x64_6t122_renamed.gds`, which the package does not ship. It is
  a copy of the package's `gds/srambank_64b.gds` in which the top cell
  `srambank_64b` is renamed to `srambank_128x4x64_6t122`, the name of the LEF macro.
  Despite its file name, `srambank_64b.gds` is the layout of this macro;
  `srambank_128b.gds` is a different one. The setup script makes the copy with
  KLayout. If the cell is missing, the GDS merge step stops with an error. Some
  comments in the configuration files describe this step differently and are out of
  date.

### 5.2 The three designs

| Design | Configuration | Top module | Clock period in the constraints |
|---|---|---|---|
| Vector unit | `asap7/m1v_mc2f/config.mk` (includes `aichip_vector`) | `vector_unit` | 1670 ps |
| Tensor unit | `asap7/m1t_b58k1bv2/config.mk` (includes `m1t_pnr`, `m1t_adder`, `aichip_tensor_signoff`) | `tensor_unit_top` | 1670 ps |
| PE top level | `asap7/aichip_pe_top/config.mk` | `pe_top` | 12000 ps |

The clock periods are flow settings, not achieved frequencies.

`aichip_tensor_signoff` is the base of the Tensor chain and cannot be run on its
own. Use `m1t_b58k1bv2`.

### 5.3 Run a design

```sh
export QT_QPA_PLATFORM=offscreen      # report images without a display
export COLUMNS=4096                   # see section 6
bash scripts/aichip_run.sh asap7/m1v_mc2f/config.mk LEC_CHECK=0
```

`aichip_run.sh` changes into `_ext/OpenROAD-flow-scripts/flow` and calls `make` with
`DESIGN_HOME` set to the `designs/` directory of this repository, so the designs
stay outside the flow tree. Anything after the configuration path is passed to
`make`, for example a target such as `synth` or a `FLOW_VARIANT=<name>`.

Start with the Vector unit. It has no SRAM macro and is by far the smallest of the
three.

`LEC_CHECK=0` turns off the logic equivalence check of the flow. All our runs had it
off. The example commands in the header of `scripts/aichip_run.sh` and in the
closing hint of `scripts/aichip_setup.sh` do not carry this argument.

For the Tensor unit, set one more variable:

```sh
B58_SQ_ABSENT_OK=1 bash scripts/aichip_run.sh asap7/m1t_b58k1bv2/config.mk LEC_CHECK=0
```

Without it, a hook that runs before clock-tree synthesis
(`designs/asap7/m1t_b58k1bv2/b58_caliber_align_v2.tcl`) stops the flow with exit
code 91.

### 5.4 How our runs were started

The layouts in the paper were produced in the private tree as follows. The wrapper
configurations mentioned are not in this repository.

| Design | Variant name | Difference from the command in 5.3 |
|---|---|---|
| Vector unit | `nm20261002` | `FLOW_VARIANT=nm20261002` on the command line. Nothing else |
| Tensor unit | `py_s42` | A wrapper configuration that includes `m1t_b58k1bv2/config.mk` and adds the variant name and a hook that fixes the global-routing seed (`set_global_routing_random -seed 42` before global routing) |
| PE top level | `py` | A wrapper configuration that includes `aichip_pe_top/config.mk` and replaces the macro placement script with one that shifts the SRAM macros by -9 nm in Y. This shift has since been merged into the published `manual_macro_place.tcl` and is selected by `AICHIP_MACRO_Y_DY = -9` in the configuration. The published files are therefore a later version of the ones used for that run, not the identical files |

All three were run on the RTL from before the latest RTL change (see the README).

### 5.5 Resources

On our machine (24 threads, 90 GiB of memory plus swap), one full run took roughly
an hour and a half for the Vector unit, nine hours for the Tensor unit and ten hours
for the PE top level. The last stages of the PE top-level run used all of the memory
and several tens of GiB of swap. One PE top-level run writes about 100 GB of results.

### 5.6 What to expect

- The PE top-level run ends with four routing design-rule violations (README, Known
  limitations).
- Our runs ended with timing violations in the final report: setup violations for
  the Vector and Tensor unit runs, hold violations for the Tensor and PE top-level
  runs, and maximum-slew violations for all three (README, Known limitations, item
  28). Seeing them does not mean that your setup is broken.
- `aichip_pe_top/config.mk` and `aichip_tensor_signoff/config.mk` still load the
  LEF and library of `fakeram7_256x32`. No instance of it is created.
- Log messages and comments refer to internal notes that are not published.

## 6. Environment notes

These are problems we ran into. They may or may not apply to your machine.

- **Yosys can hang in ABC.** With this Yosys version, synthesis waited forever when
  the flow ran without a terminal (no `TERM`, for example under a service manager)
  and with a long `TMPDIR` path. Setting `COLUMNS=4096`, or `TERM`, or a short
  `TMPDIR` avoids it.
- **Report images need a display setting.** Set `QT_QPA_PLATFORM=offscreen` when
  running without a display.
- **A Python shim in `~/.local/bin` can break the tool build.** When a Python
  installed under the home directory came first in `PATH` while the flow tools were
  built, the equivalence
  checker was linked against a Python library that was not found at run time, and
  the flow stopped at its first equivalence check. Build the tools with a clean
  `PATH`.
- **The large runs need the machine to themselves.** Do not run the tests or a
  second flow next to a PE top-level or Tensor run.

## 7. Not rehearsed

To be explicit, none of the following has been done in this repository's layout:

- running `python3 run_all.py` or any single test;
- running `tb/elaborate_smoke.sh`;
- running `tb/baseline/regen_r1_dense.sh`, which rebuilds the reference snapshots
  under `tb/baseline/` from a git commit through a temporary git worktree;
- running `scripts/aichip_setup.sh` from a clean checkout, including the GDS
  renaming step;
- running any of the three designs through `scripts/aichip_run.sh`;
- running the Tensor chain with only the seven configuration directories and the
  two hook directories present.
