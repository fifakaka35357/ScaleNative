# =============================================================================
# m1_vector_1670.sdc — B+2 600MHz-pressure SDC (clone of the 2000 instrument at 1670) for the vector A/B synthesis matrix
# (m1v_base / m1v_adder / m1v_vt / m1v_both), 2026-07-23.
#
# 🔴 The 2000 ps period is a MEASUREMENT INSTRUMENT, NOT a frequency claim.
#    Its sole purpose is to pin ABC in DELAY (not area) mode so the four cells
#    are comparable — the stock 10000 ps vector SDC leaves post-route period_min
#    at ~7467 ps, i.e. ABC in area mode (the Battle Plan «发现 2» phantom-Fmax
#    condition). ONLY cell-to-cell delta of report_clock_min_period is meaningful;
#    the absolute number constitutes no ASAP7 Fmax claim (single-corner BC=FF
#    0.77V/25C; see M1_Scoping_Plan §C1/§E1/§F-2).
# Identical to designs/asap7/aichip_vector/constraint.sdc except clk_period.
# =============================================================================
set clk_name      core_clock
set clk_port_name clk_i
set clk_period    1670
set clk_io_pct    0.2

set clk_port [get_ports $clk_port_name]
create_clock -name $clk_name -period $clk_period $clk_port

set clk_io_name vclk_$clk_name
create_clock -name $clk_io_name -period $clk_period

set non_clock_inputs [all_inputs -no_clocks]
set_input_delay  [expr $clk_period * $clk_io_pct] -clock $clk_io_name $non_clock_inputs
set_output_delay [expr $clk_period * $clk_io_pct] -clock $clk_io_name [all_outputs]
