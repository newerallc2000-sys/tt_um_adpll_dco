// dco_divider — the ripple prescaler that makes the ring observable.
//
// Tiny Tapeout's pad (sky130_ef_io_gpiov2_pad) is specified to 33 MHz, and the
// signal reaches it through the project mux and a cross-die wire. The ring runs
// to 1098.6 MHz at TT/25 C and the MEASURED fast-corner span is 1.456x on top of
// that (parent DR-021), so nothing above ~1.6 GHz may ever reach a pad and the
// first divide-by-2 is the block the whole experiment depends on.
//
// WHY A RIPPLE CHAIN AND NOT A SYNCHRONOUS PRESCALER. The parent project's
// DR-011 rejected exactly this structure for its dco_counter, because a ripple
// chain cannot hand a coherent multi-bit count to another clock domain. That
// objection does not apply here: this chain is asked for a FREQUENCY RATIO, not
// a count, and the counter that does need a coherent value is fed from a tap
// running 16x slower. A ripple T-flop's only timing arc is its own clk->Q back
// to its own D, which is the shortest arc a flop can have and is inherently
// hold-safe. That is why it reaches frequencies a synchronous counter cannot.
//
// WHY THE FLOPS ARE RESET. Phase is irrelevant to a frequency measurement, so
// an unreset chain would be functionally adequate and marginally faster. It
// would also power up in an unknown state that gate-level simulation reports as
// X and never resolves. Determinism at bring-up is worth more than the few
// percent of ceiling an async-reset flop costs, and the corner argument below
// says the ceiling is not where the risk is.
//
// WHY STAGE 1 IS AN EXPLICITLY INSTANTIATED CELL. It was not, at first. Generic
// RTL was synthesised and OpenLane mapped the first stage -- the single fastest
// path on the chip -- to a `dfrtp_1`, the WEAKEST flop in the library, whose
// clk->Q is 687 ps at ss/100C/1.60V. Nothing was wrong with the mapper: the
// constraint it was given (0.625 ns, the fast-corner ring maximum) is
// unreachable at the slow corner, so the resizer reported it could not repair
// and left the cell alone. An inferred flop also has no stable instance name --
// it came out as `_0883_` -- so it cannot even be protected by a don't-touch
// regex. The parent's DR-016 is the same lesson from the other direction: what
// the tool does to an unconstrained cell is not a design decision.
//
// So both first stages are named cells, and they are DIFFERENT cells on purpose:
//
//   chain A  dfrtp_4 + inv_2 feedback   strongest drive, one inverter of extra
//                                       delay in the loop
//   chain B  dfrbp_2, native Q_N        no feedback inverter at all, but half
//                                       the drive
//
// Which one is faster is not obvious from the datasheet and is measured in
// SPICE (T5) rather than argued. Two chains that fail for different reasons are
// worth more here than two copies of the same guess.
//
// WHY THE CEILING IS NOT WHERE THE RISK IS. The divider and the ring are the
// same silicon. At the fast corner the ring is 1.456x faster and the flop is
// faster in the same proportion; at the slow corner both slow down together. A
// slow-corner flop is never asked to divide a fast-corner ring. Comparing them
// is the category error the parent's M7 had to correct (m7_counter_corners.py),
// so the T5 gate here is per-corner: divider maximum at a corner against RING
// maximum at THAT corner, never across corners.
//
// The chain is instantiated twice with different first-stage edges. See
// tt_um_adpll_dco.v for why there are two.
`default_nettype none

module dco_divider #(
  parameter integer STAGES     = 10,      // /2 .. /2^STAGES
  parameter integer FIRST_CELL = 0        // 0 = dfrtp_4 + inv_2, 1 = dfrbp_2 (Q_N)
) (
  input  wire              osc,           // the ring output, undivided
  input  wire              rst_n,
  output wire [STAGES:1]   q              // q[k] is osc / 2^k
);

  // split_var: each element of `c` is driven by one stage and read by the next.
  // The linter's dependency analysis is per-VECTOR, so without the split it
  // reports the chain as a combinational loop (UNOPTFLAT). It is not a loop --
  // every element is a flop output -- and tb_divider proves the ratios exact at
  // twelve frequencies across the whole envelope.
  wire [STAGES:1] c /* verilator split_var */;
  assign q = c;

  // ---- stage 1: the only stage whose speed is in question ------------------
  // Named instances, so that they survive flattening with their names intact
  // and can be held by RSZ_DONT_TOUCH_RX and found again in the hardened
  // netlist by scripts/census_netlist.py.
  generate
    if (FIRST_CELL != 0) begin : g_first_qn
      // dfrbp_2: Q_N comes out of the cell, so the toggle loop is clk->Q_N->D
      // with nothing in between. Shortest possible loop, weaker drive.
      wire qn;
      (* keep *) sky130_fd_sc_hd__dfrbp_2 ff (
        .CLK(osc), .D(qn), .RESET_B(rst_n), .Q(c[1]), .Q_N(qn));
    end else begin : g_first_drive
      // dfrtp_4: strongest flop in the family, at the cost of an inverter in
      // the toggle loop.
      wire qb;
      (* keep *) sky130_fd_sc_hd__dfrtp_4 ff (
        .CLK(osc), .D(qb), .RESET_B(rst_n), .Q(c[1]));
      (* keep *) sky130_fd_sc_hd__inv_2 fb (.A(c[1]), .Y(qb));
    end
  endgenerate

  // ---- stages 2..STAGES: each clocked by the one below it ------------------
  genvar i;
  generate
    for (i = 2; i <= STAGES; i = i + 1) begin : g_stage
      reg d;
      always @(posedge c[i-1] or negedge rst_n)
        if (!rst_n) d <= 1'b0;
        else        d <= ~d;
      assign c[i] = d;
    end
  endgenerate

endmodule

`default_nettype wire
