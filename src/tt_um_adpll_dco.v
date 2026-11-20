// tt_um_adpll_dco — the ADPLL's oscillator, alone, instrumented, on TTSKY26d.
//
// One `dco_matrix` (the parent project's signed-off 167-cell tri-state ring,
// vendored unmodified), the three thermometer encoders that drive it, two
// independent divider chains, and an on-chip frequency counter. No loop: the
// code is set from the pins and held, and the frequency is read back.
//
// WHAT THIS CHIP IS FOR. Every frequency the parent project quotes is a
// simulated frequency on a declared basis (tier 2.75: source-cell SPICE plus
// measured per-node wire capacitance, parent DR-020). This chip measures the
// f(code) surface instead of fitting it, on more than one die, which is the
// only way to close the parent's open item 4: device mismatch was never
// simulated, and the Monte Carlo that was written measured nothing at all
// (18 bit-identical draws, because `set rndseed` runs after sky130 evaluates
// mismatch at parse time). The parent's whole dead-zone fix rests on
// WEIGHT[mid] = 0.2188 against its geometric 0.2; that ratio has held across
// TT, SS, FF and the addition of interconnect, which are four GLOBAL
// perturbations. Whether it holds across DIES is what this chip asks.
//
// ------------------------------------------------------------------ the pins
// 15 code bits plus one enable is exactly 16, and TT supplies 8 dedicated
// inputs plus 8 bidirectionals. The code is therefore STATIC and PARALLEL:
// nothing has to be shifted in, no state machine has to work, and the divided
// outputs can be observed with no clock at all. A shift register would have
// freed pins this design does not need and would have made first-power-on
// depend on a loader being correct -- if the loader has a bug, the die returns
// nothing. See DR-T003.
//
// -------------------------------------------------- the three inherited traps
// Each of these is a documented failure of the parent project. Repeating one
// here costs a shuttle slot and six months.
//
// (a) osc_en ALONE DOES NOT STOP THE RING. dco_matrix's own header says so:
//     stage 1's backbone NAND2 is gated, but every coarse and mid tri-state
//     cell drives a ring node in parallel with it and follows n5 regardless.
//     The parent's adpll_core therefore ANDs the DRIVE buses with its enable
//     (adpll_core.v:165-166). This wrapper does the same and ANDs in `ena` as
//     well -- a tile that free-runs a 1.6 GHz ring while somebody else's
//     project is selected is a power and supply-noise problem for the whole
//     die. The FINE bus is deliberately NOT masked: it is a load bank, and with
//     no drive the ring cannot oscillate whatever the loads do.
//
// (b) FINE POLARITY IS INVERTED. fine_en[k]=1 makes load k switch with the ring
//     and SLOW it, so the encoder output is inverted to make a higher fine code
//     mean a higher frequency (parent adpll_core.v:177). V1's source comments
//     claimed the opposite sense and were wrong; its own SPICE anchor caught
//     it. Copied here, not re-derived, and asserted in the testbench.
//
// (c) THE RESIZER WILL EAT THE BANK RATIO IF IT IS ALLOWED TO. The parent's
//     DR-016 records what OpenROAD's design-repair pass did to this exact
//     macro when left unconstrained: all 75 weight-2 mid units upsized to
//     weight 8, the backbone inverters swapped for clkinv_16, and 262 antenna
//     diodes hung on ring nodes. Every ring node reports a max-transition
//     violation BY CONSTRUCTION -- the slew on those nodes is the
//     frequency-setting mechanism, not a defect -- so a repair pass aimed at
//     transition violations will always find work to do here. `(* keep *)` is a
//     synthesis attribute and says nothing to OpenROAD. Tiny Tapeout hardens
//     with its own configuration, so the defence is verification, not
//     configuration: scripts/census_netlist.py checks the hardened netlist
//     against the parent's architecture definition on every run.
`default_nettype none
`include "tt_arch.vh"

module tt_um_adpll_dco (
  input  wire [7:0] ui_in,      // dedicated inputs
  output wire [7:0] uo_out,     // dedicated outputs
  input  wire [7:0] uio_in,     // bidirectional: inputs here
  output wire [7:0] uio_out,    // bidirectional: unused, driven 0
  output wire [7:0] uio_oe,     // bidirectional enable: 0 = input
  input  wire       ena,        // high only while this project is selected
  input  wire       clk,        // measurement time base AND readout clock
  input  wire       rst_n
);

  // ------------------------------------------------------------ pin unpacking
  // Bit positions come from tt_arch.vh, generated from arch/tt_arch.py. They
  // are not typed here, in this module's comments, in the docs or in the
  // firmware: the parent kept its bank widths in six places and re-proportioning
  // them meant editing all six and hoping.
  wire [`DCO_FINE_W-1:0]   fine_bin   = ui_in[`DCO_FINE_W-1:0];
  wire [`DCO_MID_W-1:0]    mid_bin    = { uio_in[`TT_UIO_MID_HI +: 4],
                                          ui_in[`TT_UI_MID_LO] };
  wire [`DCO_COARSE_W-1:0] coarse_bin = uio_in[`TT_UIO_COARSE +: `DCO_COARSE_W];
  wire                     osc_en_pin = uio_in[`TT_UIO_OSC_EN];

  // ------------------------------------------------------------ enable gating
  // Trap (a). `run` is the only thing that reaches the ring, and it needs BOTH
  // the pin and the mux's project-select.
  wire run     = ena & osc_en_pin;
  wire rst_all_n = rst_n & ena;      // digital half is held quiet when unselected

  // ------------------------------------------------------- thermometer encode
  wire [`DCO_COARSE_CODES-1:0] coarse_therm;
  wire [`DCO_MID_CODES-1:0]    mid_therm;
  wire [`DCO_FINE_CODES-1:0]   fine_therm;

  therm_enc #(.BW(`DCO_COARSE_W), .TW(`DCO_COARSE_CODES))
    e_c (.bin(coarse_bin), .therm(coarse_therm));
  therm_enc #(.BW(`DCO_MID_W),    .TW(`DCO_MID_CODES))
    e_m (.bin(mid_bin),    .therm(mid_therm));
  therm_enc #(.BW(`DCO_FINE_W),   .TW(`DCO_FINE_CODES))
    e_f (.bin(fine_bin),   .therm(fine_therm));

  // therm[i] = (bin > i), so a fine code above 95 saturates at all-ones rather
  // than wrapping. 7 bits reach 127 and the bank has 95 codes; the saturation
  // is deliberate and the testbench asserts it.
  wire [`DCO_COARSE_CODES-1:0] coarse_row = coarse_therm & {`DCO_COARSE_CODES{run}};
  wire [`DCO_MID_CODES-1:0]    mid_col    = mid_therm    & {`DCO_MID_CODES{run}};
  wire [`DCO_FINE_CODES-1:0]   fine_en    = ~fine_therm;   // trap (b): NOT masked

  // ------------------------------------------------------------- the oscillator
  wire osc_raw;
  dco_matrix u_dco (
    .osc_en     (run),
    .coarse_row (coarse_row),
    .mid_col    (mid_col),
    .fine_en    (fine_en),
    .osc_out    (osc_raw)
  );

  // ------------------------------------------------------------- the dividers
  // Two chains, of different construction, on different pins. The first
  // divide-by-2 is asked for ~1.6 GHz at the fast corner and it is the single
  // point of failure for the entire experiment: if it drops cycles it does not
  // fail visibly, it reports a plausible WRONG frequency. Chain A is
  // rising-edge and carries the taps and the counter; chain B is falling-edge,
  // drives nothing but its own next stage, and exists so that a chip whose
  // chain A front end is marginal is still a measurement. Bring-up cross-checks
  // the two before believing any frequency (BRINGUP step 4).
  wire [`TT_DIV_STAGES:1]  div_a;
  wire [`TT_DIVB_STAGES:1] div_b;

  dco_divider #(.STAGES(`TT_DIV_STAGES),  .FIRST_CELL(0))
    u_div_a (.osc(osc_raw), .rst_n(rst_all_n), .q(div_a));
  dco_divider #(.STAGES(`TT_DIVB_STAGES), .FIRST_CELL(1))
    u_div_b (.osc(osc_raw), .rst_n(rst_all_n), .q(div_b));

  // --------------------------------------------------------------- the counter
  wire cnt_data, cnt_valid, cnt_strobe, cnt_alive, cnt_ovf;
  dco_fcounter #(.WIN_LOG2(`TT_WIN_LOG2), .CNT_W(`TT_CNT_W))
    u_cnt (
      .clk    (clk),
      .rst_n  (rst_all_n),
      .div_in (div_a[`TT_TAP_CTR]),
      .data   (cnt_data),
      .valid  (cnt_valid),
      .strobe (cnt_strobe),
      .alive  (cnt_alive),
      .ovf    (cnt_ovf)
    );

  // ---------------------------------------------------------------- the outputs
  assign uo_out[`TT_UO_DIV1024_A ] = div_a[`TT_TAP_DIV1024];
  assign uo_out[`TT_UO_DIV64_A   ] = div_a[`TT_TAP_DIV64];
  assign uo_out[`TT_UO_DIV8_A    ] = div_a[`TT_TAP_DIV8];
  assign uo_out[`TT_UO_DIV1024_B ] = div_b[`TT_TAP_DIV1024];
  assign uo_out[`TT_UO_CNT_DATA  ] = cnt_data;
  assign uo_out[`TT_UO_CNT_VALID ] = cnt_valid;
  // `strobe` carries the bit clock; `alive` and `ovf` have no pin of their own,
  // so they ride on it: the strobe is squelched when the counter has never seen
  // a capture, and inverted-sense when a window overflowed. Both conditions are
  // also visible in the frame itself (all-zero, or the maximum), so this is
  // redundancy rather than the only path -- but a squelched strobe tells the
  // host "the ring is not running" without it having to decode 20 bits first.
  assign uo_out[`TT_UO_CNT_STROBE] = cnt_strobe & cnt_alive & ~cnt_ovf;
  assign uo_out[`TT_UO_OSC_BUF   ] = osc_raw;

  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;    // every bidirectional is an input

endmodule

`default_nettype wire
