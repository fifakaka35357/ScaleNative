#!/usr/bin/env bash
# =============================================================================
# regen_r1_dense.sh —— 从指定 commit 现取重采 R1 dense 基线（权威是【本脚本】，
# 不是 .snap；.snap 只是它的缓存）。
#
# 为什么这样组织：`Review/preflight_c6e/regen_baseline.sh:6-9` 已有裁决 ——
# 「一份『基线』的静态副本会随主线演进而变成陈旧品……改为从**指定 commit** 现取，
#  出处不可伪造」，与 `PROJECT_RULES §2.7`（旧产物会骗人）同源。
#
# 两个用途：
#   ① 复现自证：证明在盘的 .snap 确实来自它自称的那个 commit（逐字节 cmp）；
#   ② 工具链换版后的重采：判据 §8 的 `R1-INVALID-CALIBER` 三态要求先在新工具链上
#      重采 dense 基线再继续 —— 那就是跑本脚本。
#
# 用法:  bash tb/baseline/regen_r1_dense.sh [commit]      # 默认 HEAD
#        REGEN_INSTALL=1 bash ... [commit]                # 重采结果覆盖在盘基线（换工具链时用）
#
# 🔴 注意：commit 必须**同时**含 RTL 与本套采集脚手架（snap_baseline.py / 新形状用例），
#    即「步骤 0 收口那个 commit」及其后代。指向 96fe783 本身是不行的 —— 那时脚手架还不存在。
#    ▲同理 MANIFEST 里的 `#AICHIP_HEAD` 记的是**采集时**的 HEAD（判据文件那个 commit），
#    那一刻脚手架尚未提交（鸡生蛋）⇒ **不能拿它当 regen 的默认值**，它只是出处记录。
#    默认改用 `HEAD`：基线与脚手架同仓同 checkout，HEAD 天然两者都有。
# =============================================================================
set -euo pipefail

TB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"        # AI_Chip/tb
AI="$(cd "$TB/.." && pwd -P)"
ROOT="$(cd "$AI/.." && pwd -P)"
BASE="$TB/baseline/r1_dense"

[ -f "$BASE/MANIFEST.sha256" ] || { echo "🔴 找不到 $BASE/MANIFEST.sha256"; exit 9; }
COMMIT="${1:-HEAD}"
CAPTURED_AT="$(grep '^#AICHIP_HEAD ' "$BASE/MANIFEST.sha256" | awk '{print $2}')"

WT="$(mktemp -d /tmp/r1regen_XXXXXX)"
trap 'git -C "$AI" worktree remove --force "$WT" 2>/dev/null || true; rm -rf "$WT"' EXIT

echo "== regen_r1_dense =="
echo "commit    : $COMMIT (= $(git -C "$AI" rev-parse --short "$COMMIT"))"
echo "采集时 HEAD: $CAPTURED_AT （MANIFEST 记录，仅作出处，不作 regen 默认值）"
echo "worktree  : $WT"
git -C "$AI" worktree add --detach "$WT" "$COMMIT" >/dev/null
[ -f "$WT/tb/snap_baseline.py" ] \
  || { echo "🔴 该 commit 不含 tb/snap_baseline.py —— 采集脚手架不存在，换一个 commit"; exit 9; }

OUT="$(mktemp -d /tmp/r1regen_out_XXXXXX)"
TOOLTAG="verilator=$(verilator --version | awk '{print $2}') cocotb=$(python3 -c 'import cocotb;print(cocotb.__version__)') python=$(python3 -c 'import platform;print(platform.python_version())') xprop=0 xseed=1"

n_sim=$(ps -eo comm | grep -cE '^(Vtop|Vtb_)' || true)
[ "$n_sim" -eq 0 ] || { echo "🔴 已有仿真在跑 (Vtop=$n_sim)"; exit 9; }

VS=$(python3 - "$WT/tb/test_tensor_gemm_core.py" <<'PY'
import re, sys
m = re.search(r'VERILOG_SOURCES="(.*?)"', open(sys.argv[1]).read(), re.S)
print(" ".join(m.group(1).replace("\\", " ").split()))
PY
)
unset GEMM_LEGACY_OPERANDS GEMM_D_MISWIRE 2>/dev/null || true
( cd "$WT/tb" && make -s clean >/dev/null 2>&1 )
set +e
( cd "$WT/tb" && env GEMM_SNAP_DUMP="$OUT" GEMM_SNAP_TOOLTAG="$TOOLTAG" RANDOM_SEED=20260802 \
    make -s MODULE=test_tensor_gemm_core TOPLEVEL=tb_tensor_gemm_core VERILOG_SOURCES="$VS" ) \
    > "$OUT/regen.log" 2>&1
set -e
res=$(grep -oE 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+' "$OUT/regen.log" | tail -1 || true)
[ -n "$res" ] || { tail -20 "$OUT/regen.log"; echo "🔴 未找到 cocotb 结果行"; exit 9; }
echo "$res" | grep -q 'FAIL=0' || { tail -20 "$OUT/regen.log"; echo "🔴 重采跑不绿：$res"; exit 9; }
echo "重采 : $res"

if [ "${REGEN_INSTALL:-0}" = "1" ]; then
  echo "REGEN_INSTALL=1 → 覆盖在盘基线（工具链换版重采）"
  cp "$OUT"/r1_dense/*.snap "$BASE/"
  n=$(ls "$BASE"/*.snap | wc -l)
  { grep '^#' "$BASE/MANIFEST.sha256" | grep -vE '^#(TOOL|CASES|END) ' | head -4
    echo "#TOOL $TOOLTAG"; echo "#CASES $n"
    ( cd "$BASE" && sha256sum *.snap ); echo "#END $n"; } > "$BASE/MANIFEST.sha256.new"
  mv "$BASE/MANIFEST.sha256.new" "$BASE/MANIFEST.sha256"
  ( cd "$BASE" && sha256sum -c --quiet MANIFEST.sha256 )
  echo "✅ 已覆盖并重签 MANIFEST（$n 个 case）"
  exit 0
fi

# 复现自证：位样本必须逐位相同（.snap 头里的 #TOOL 可能不同，故比 FLAT 而非整文件）
bad=0
for f in "$BASE"/*.snap; do
  b="$(basename "$f")"
  [ -f "$OUT/r1_dense/$b" ] || { echo "  🔴 重采缺 $b"; bad=1; continue; }
  a=$(grep '^#FLAT_SHA256 ' "$f" | cut -d' ' -f2)
  c=$(grep '^#FLAT_SHA256 ' "$OUT/r1_dense/$b" | cut -d' ' -f2)
  if [ "$a" = "$c" ]; then echo "  ✅ $b 逐位相同"; else echo "  🔴 $b 位样本不同"; bad=1; fi
done
[ "$bad" -eq 0 ] || { echo "🔴 复现失败 —— 在盘基线与从 $COMMIT 现取的结果不一致"; exit 9; }
echo "✅ 复现自证通过：在盘 .snap 确实可由 $COMMIT + 当前工具链重现"
