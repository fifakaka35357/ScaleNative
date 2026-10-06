# =============================================================================
# vector_unit — ASAP7 canary SDC (liberty time unit = ps, per platform libs).
# 10000 ps is a deliberately loose synthesis clock: the canary validates the
# slang+ASAP7+ps-SDC pipeline, it does NOT publish an ASAP7 Fmax. The
# measurement-grade ASAP7 STA idiom (uncertainty/latency/IO budgets in ps
# conventions, NOT sky130 values x1000) is defined separately before any
# ASAP7 number enters Paper/PPA_Tables_SSOT.md.
# =============================================================================
set clk_name      core_clock
set clk_port_name clk_i
set clk_period    10000
set clk_io_pct    0.2

set clk_port [get_ports $clk_port_name]
create_clock -name $clk_name -period $clk_period $clk_port

set clk_io_name vclk_$clk_name
create_clock -name $clk_io_name -period $clk_period

set non_clock_inputs [all_inputs -no_clocks]
set_input_delay  [expr $clk_period * $clk_io_pct] -clock $clk_io_name $non_clock_inputs
set_output_delay [expr $clk_period * $clk_io_pct] -clock $clk_io_name [all_outputs]
