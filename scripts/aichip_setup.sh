#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The ScaleNative Authors
#
# Fetch the external dependencies of the layout flow and apply the patches in
# patches/. OpenROAD-flow-scripts (with its tools and the ASAP7 PDK) and the
# ASAP7 SRAM macro package are not stored in this repository; they are fetched
# here.
#
# Directories created (both are git-ignored):
#   _ext/OpenROAD-flow-scripts/   OpenROAD-flow-scripts at ORFS_PIN, with
#                                 patches/orfs-local.patch applied
#   third_party/asap7_sram_0p0/   the ASAP7 SRAM macro package at SRAM_PIN, with
#                                 patches/sram-bitwidth.patch applied and one GDS
#                                 copy whose top cell is renamed
#
# The two locations are fixed. The configuration files under designs/ find the
# SRAM macro views at $(FLOW_HOME)/../../../third_party/asap7_sram_0p0, so the
# flow must sit two directory levels below the repository root.
#
# Status: this script has not been run end to end from a clean checkout yet
# (see "Known limitations" in README.md). It stops at the first step that fails.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ORFS_URL="https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts"
ORFS_PIN="49416916f08ca3640464c755aed883c25d25a153"
SRAM_URL="https://github.com/The-OpenROAD-Project/asap7_sram_0p0"
SRAM_PIN="9f5af0939e8dd3cc1a9693a50b23441691dd7d25"

ORFS_DIR="$HERE/_ext/OpenROAD-flow-scripts"
SRAM_DIR="$HERE/third_party/asap7_sram_0p0"

# apply_once <repository> <patch>: apply a patch unless it is already applied.
apply_once() {
  if git -C "$1" apply --reverse --check "$2" 2>/dev/null; then
    echo "   already applied: $(basename "$2")"
  elif git -C "$1" apply --check "$2"; then
    git -C "$1" apply "$2"
    echo "   applied: $(basename "$2")"
  else
    echo "ERROR: $(basename "$2") does not apply to $1." >&2
    echo "       Do not force it. Check that the checkout is at the pinned commit" >&2
    echo "       and review each hunk before changing the patch." >&2
    exit 3
  fi
}

echo "== 1. OpenROAD-flow-scripts at $ORFS_PIN"
mkdir -p "$HERE/_ext"
[ -d "$ORFS_DIR/.git" ] || git clone "$ORFS_URL" "$ORFS_DIR"
git -C "$ORFS_DIR" checkout -q --detach "$ORFS_PIN"
git -C "$ORFS_DIR" submodule update --init --recursive

echo "== 2. patches/orfs-local.patch (four files under flow/scripts/)"
apply_once "$ORFS_DIR" "$HERE/patches/orfs-local.patch"

echo "== 3. asap7_sram_0p0 at $SRAM_PIN"
mkdir -p "$HERE/third_party"
[ -d "$SRAM_DIR/.git" ] || git clone "$SRAM_URL" "$SRAM_DIR"
git -C "$SRAM_DIR" checkout -q --detach "$SRAM_PIN"

echo "== 4. patches/sram-bitwidth.patch (one line of one liberty file)"
apply_once "$SRAM_DIR" "$HERE/patches/sram-bitwidth.patch"

echo "== 5. GDS copy with the top cell renamed"
# The file gds/srambank_64b.gds holds the layout of the macro that the LEF, the
# liberty file and the Verilog model call srambank_128x4x64_6t122 (the number in
# the GDS file name does not match the word count in the macro name). Its top
# cell is named srambank_64b, so a renamed copy is needed for the final GDS merge.
GDS_IN="$SRAM_DIR/gds/srambank_64b.gds"
GDS_OUT="$SRAM_DIR/gds/srambank_128x4x64_6t122_renamed.gds"
if [ -s "$GDS_OUT" ]; then
  echo "   present: $(basename "$GDS_OUT")"
else
  command -v klayout >/dev/null || { echo "ERROR: klayout is needed for this step." >&2; exit 3; }
  klayout -b -r "$HERE/scripts/rename_gds_top.py" \
    -rd gds_in="$GDS_IN" -rd gds_out="$GDS_OUT" -rd top_name=srambank_128x4x64_6t122
  [ -s "$GDS_OUT" ] || { echo "ERROR: $GDS_OUT was not written." >&2; exit 3; }
fi

cat <<EOF
Done.
Next: build the tools inside $ORFS_DIR as described in the
OpenROAD-flow-scripts documentation, then start a design with
  bash scripts/aichip_run.sh asap7/m1v_mc2f/config.mk
EOF
