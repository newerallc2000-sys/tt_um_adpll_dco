# tt_um_adpll_dco constraints. Every line carries the reason it is there --
# an SDC line without one is a line nobody can safely change later.

# ---------------------------------------------------------------- the TT clock
# 50 MHz. Tiny Tapeout's documented floor is "at least 50 MHz", and the demo
# board usually runs slower, so constraining here is conservative in the only
# direction that matters.
create_clock -name clk -period 20.0 [get_ports clk]

# ------------------------------------------------------------------- the ring
# dco_matrix is a combinational loop BY CONSTRUCTION: five inverting stages
# closed on themselves. STA must not attempt to time it -- the parent's
# macro.sdc cuts the same arc at the same cell. Cutting it deliberately is
# better than letting the tool find and break the loop wherever it likes.
set_disable_timing [get_cells -hierarchical *s1_gate*]

# The oscillator's output IS a clock, generated inside the design rather than
# arriving at a port. It is declared at the FAST-CORNER MAXIMUM the ring can
# reach: 1098.6 MHz at TT/25 C (the parent's tier-2.75 coverage) times the
# MEASURED 1.456x ff span (parent DR-021) = 1599.5 MHz = 0.625 ns. Not the
# nominal target -- the loop that would have kept it near 500 MHz is not on this
# chip, and the pins can command any code at any corner.
create_clock -name osc -period 0.625 [get_pins -hierarchical *obuf/X]

# The two clocks are physically unrelated: `clk` comes from the demo board and
# `osc` from a ring on the die. Nothing in the design tries to close a path
# between them except the counter's crossings, handled below.
set_clock_groups -asynchronous -group {clk} -group {osc}

# ------------------------------------------------------------ the bank buses
# The code pins reach the macro through combinational logic only. There is no
# capture edge to close against: changing a bank changes a FREQUENCY, not a
# sampled value, and the host waits two whole measurement windows afterwards.
# The parent false-paths the same buses into the same macro pins (DR-014).
set_false_path -from [get_ports ui_in*]
set_false_path -from [get_ports uio_in*]
set_false_path -from [get_ports ena]

# ------------------------------------------------------------------ the CDC
# Three crossings, argued in dco_fcounter.v's header:
#   win_tog  clk -> div : one bit, 2-flop synchroniser
#   cap      div -> clk : CNT_W bits, safe TEMPORALLY -- written once per window
#                         and sampled ~a full window away from that instant
#   cap_tog  div -> clk : one bit, 2-flop synchroniser
# All of them are between the two asynchronous groups above, which already cuts
# them; the explicit false path is here so that the reason is recorded where the
# next person will look for it.
set_false_path -from [get_clocks osc] -to [get_clocks clk]
set_false_path -from [get_clocks clk] -to [get_clocks osc]

# Reset is asserted asynchronously and released synchronously by the harness.
set_false_path -from [get_ports rst_n]
