# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The ScaleNative Authors
#
# KLayout batch script: write a copy of a GDS file whose single top cell has a
# new name. Called by scripts/aichip_setup.sh:
#
#   klayout -b -r rename_gds_top.py -rd gds_in=<in.gds> -rd gds_out=<out.gds> \
#           -rd top_name=<new top cell name>
#
# KLayout defines gds_in, gds_out and top_name as global variables (-rd).
# Status: not run from a clean checkout yet (see "Known limitations" in README.md).
import pya

layout = pya.Layout()
layout.read(gds_in)  # noqa: F821

tops = layout.top_cells()
if len(tops) != 1:
    raise RuntimeError("expected exactly one top cell in %s, found %d" % (gds_in, len(tops)))  # noqa: F821

tops[0].name = top_name  # noqa: F821
layout.write(gds_out)  # noqa: F821
print("top cell renamed to %s -> %s" % (top_name, gds_out))  # noqa: F821
