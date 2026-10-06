#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The ScaleNative Authors
#
# Run one design configuration through OpenROAD-flow-scripts, with designs/ of
# this repository as the design home (the designs stay outside the flow tree).
#
# Usage: bash scripts/aichip_run.sh asap7/<design>/config.mk [make arguments...]
#   bash scripts/aichip_run.sh asap7/m1v_mc2f/config.mk
#   bash scripts/aichip_run.sh asap7/m1v_mc2f/config.mk FLOW_VARIANT=try1 synth
#
# Note for asap7/m1t_b58k1bv2: its PRE_CTS hook
# (designs/asap7/m1t_b58k1bv2/b58_caliber_align_v2.tcl) stops with exit code 91
# unless B58_SQ_ABSENT_OK=1 is set in the environment.
#
# Status: not run from a clean checkout yet (see "Known limitations" in README.md).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW="$HERE/_ext/OpenROAD-flow-scripts/flow"
export DESIGN_HOME="$HERE/designs"

CFG="${1:?usage: aichip_run.sh asap7/<design>/config.mk [make arguments...]}"
shift
DESIGN_CONFIG="$DESIGN_HOME/$CFG"

[ -f "$DESIGN_CONFIG" ] || { echo "ERROR: no such configuration: $DESIGN_CONFIG" >&2; exit 3; }
[ -d "$FLOW" ] || { echo "ERROR: $FLOW is missing; run scripts/aichip_setup.sh first." >&2; exit 3; }

cd "$FLOW"
exec make DESIGN_HOME="$DESIGN_HOME" DESIGN_CONFIG="$DESIGN_CONFIG" "$@"
