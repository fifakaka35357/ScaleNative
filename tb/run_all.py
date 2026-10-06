#!/usr/bin/env python3
"""
run_all.py — full cocotb regression runner for the H-Tensor numeric datapath.

Each test_*.py carries its own VERILOG_SOURCES + TOPLEVEL in its module docstring
(the `Run: cd tb && make MODULE=... TOPLEVEL=... VERILOG_SOURCES="..."` block).
This runner extracts those and runs every test, so the whole suite can be checked
with one command (the Makefile alone only builds the default mac_lru target).

[2026-09-06 · 决策 D-RUNALL-TESTEXTRA · 欠账 #121] A THIRD, OPTIONAL field is parsed:
`TEST_EXTRA="..."`. Some tests only mean anything in a specific compile
configuration -- `test_l1i_real_a7` characterises the ASAP7 REAL macro's port
collapse and needs `-DPDK_ASAP7 -GREAL_MACRO=1`; without them the wrapper compiles
its behavioural (true dual-port, byte-mask-honouring) arm and three of its six arms
legitimately fail. Measured, not predicted: PASS=3 FAIL=3 under this runner's exact
call surface vs PASS=6 FAIL=0 with the flags.
    Why TEST_EXTRA and not EXTRA_ARGS: a make COMMAND-LINE assignment overrides every
    assignment in the makefile (including `+=`), so `EXTRA_ARGS=...` on the command
    line would wipe the Makefile's -Wno-*/--assert/--bbox-unsup. `TEST_EXTRA` is the
    append-only hook the Makefile added (Makefile:74-82) for exactly this.
    🔴 Files WITHOUT the field must get a byte-identical command to before this
    change -- that is the negative control, and it is checked by
    aichip_run_logs/runall_testextra_control_20260906.py.

Usage:
    cd tb && python3 run_all.py            # run all test_*.py
    cd tb && python3 run_all.py m37        # only tests whose name matches 'm37'

[2026-09-07 · 欠账 #130] 🔴 REDIRECT THE OUTPUT TO A `.txt`, NEVER A `.log`:
    python3 run_all.py > ../../aichip_run_logs/runall_<date>_<tag>.txt 2>&1
The authoritative fact source (`.claude/skills/hw-record/scripts/pull_facts.py`, `gates()`)
globs `aichip_run_logs/*runall*.{txt,log}` -- the `.log` half was only added on 2026-09-07,
and BOTH halves now skip `_VOID_*` and require the TOTAL line to be a whole line in this
script's own `  ----- TOTAL: ... -----` form (line 72). Two independent reasons to keep
writing `.txt`: (a) it is what every launcher and every prereg section already says, and
(b) `.log` in this directory is the historical suffix for single-arm/partial runs, which
are NOT regression baselines. Controls: aichip_run_logs/pullfacts_glob_control_20260907.py

🔴🔴 [2026-09-11 · 欠账 #143] **加/删任何 test_*.py（含 NO-META）之前先读这一段。**
本套件的规模被【四个面】同时钉着，改一个 tb 件要【同批】过完四面，缺一就漂：
    ① elaborate 面  grep -c '^run ' AI_Chip/tb/elaborate_smoke.sh
    ② 文件面(件数)  ls AI_Chip/tb/test_*.py | wc -l
    ③ 文件面(用例)  grep -h '^@cocotb.test' AI_Chip/tb/test_*.py | wc -l
    ④ 运行面        本脚本末行 `TOTAL: PASS=<n> FAIL=<f> across <k> files`
🔴 **NO-META 只保得住 ④ 的 `PASS=`，保不住 ②③** —— `tests` 是按 glob 数的（见下面第 35 行），
   与有没有 META 无关；而 `^@cocotb.test` 只数**装饰器在不在**，**不问跑不跑**。
   2026-09-07 就是在这里栽的：新增一个 NO-META 件，注释写「CASES 不变因为 NO-META 不产用例」
   —— 拿【运行面】事实去冻结一个【文件面】分母，理由与数字一起错。
要回写的地方（四处，别只改一处）：
    aichip_run_logs/launch_petop_b6_regression.sh  的 EXP_ELAB/EXP_TESTS/EXP_CASES 声明行
                                                   + 同件里那句「其中 N 个是 NO-META」
    aichip_run_logs/runall_baseline_judge_20261002.py  的 B2 / B4 / NOMETA_EXPECT（I3 合入起的现行版；20260907 版只判旧日志）
    aichip_run_logs/soc600_prereg_20260902.md  §41.2.3 / §41.2.4
🔴 改完跑两条自证：`bash aichip_run_logs/launch_petop_b6_regression.sh --selftest`（应 14/14）
   与 `bash aichip_run_logs/resume_check.sh <台账>` 的 `## 5.` 段（应三面逐一吻合）。

Exit code is non-zero if any test FAILs or errors — suitable for a review gate.
"""
import re, glob, subprocess, sys, os

os.chdir(os.path.dirname(os.path.abspath(__file__)))
flt = sys.argv[1] if len(sys.argv) > 1 else ""
tests = sorted(t for t in glob.glob("test_*.py") if flt in t)

results, tot_p, tot_f = {}, 0, 0
for f in tests:
    src = open(f).read()
    mod = f[:-3]
    mtop = re.search(r"TOPLEVEL=([A-Za-z_0-9]+)", src)
    msrc = re.search(r'VERILOG_SOURCES="(.*?)"', src, re.S)
    if not (mtop and msrc):
        results[mod] = "NO-META (no TOPLEVEL/VERILOG_SOURCES in docstring)"
        continue
    top = mtop.group(1)
    vsrc = " ".join(msrc.group(1).replace("\\", " ").split())
    # 🔴 optional third field; absent for every test but test_l1i_real_a7 (see docstring)
    mext = re.search(r'TEST_EXTRA="(.*?)"', src, re.S)
    cmd = ["make", "-s", f"MODULE={mod}", f"TOPLEVEL={top}", f"VERILOG_SOURCES={vsrc}"]
    if mext:
        cmd.append("TEST_EXTRA=" + " ".join(mext.group(1).replace("\\", " ").split()))
    subprocess.run(["make", "-s", "clean"], capture_output=True)
    p = subprocess.run(cmd, capture_output=True, text=True)
    out = p.stdout + p.stderr
    m = re.findall(r"PASS=(\d+) FAIL=(\d+) SKIP=(\d+)", out)
    if m:
        pa, fa, sk = m[-1]
        results[mod] = f"PASS={pa} FAIL={fa} SKIP={sk}" + ("   <-- FAIL" if fa != "0" else "")
        tot_p += int(pa); tot_f += int(fa)
    elif "%Error" in out or "CAUGHT" in out:
        results[mod] = "BUILD/RUN ERROR"; tot_f += 1
        print(f"--- {mod} error tail ---")
        print("\n".join(out.splitlines()[-15:]))
    else:
        results[mod] = "??? " + (out.splitlines()[-1] if out.splitlines() else "")
        tot_f += 1

print("\n===== cocotb regression =====")
for k in sorted(results):
    print(f"  {k:24s} {results[k]}")
print(f"  ----- TOTAL: PASS={tot_p} FAIL={tot_f} across {len(tests)} files -----")
sys.exit(1 if tot_f else 0)
