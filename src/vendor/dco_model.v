// dco_model — real-valued behavioral DCO (SIMULATION ONLY; never synthesized).
// Stands in for the structural `dco_matrix` macro in RTL simulation, where a
// tri-state standard-cell ring cannot be modelled meaningfully by an event
// simulator.
//
// Every coefficient comes from dco_params.vh, written by scripts/run_m2_model.py
// from the SAME analytic model the Python system model uses — one source of
// truth, so the Verilog and Python halves cannot drift apart. This module
// contains no numbers of its own.
//
// V2 note: the code word is 14 bits over three banks, and the drive banks are
// summed by WEIGHT rather than by a hard-coded 8c+2m. WEIGHT_MID in particular
// is a MEASURED quantity — the claim that one einvp_1 on one of five ring
// stages is worth a fifth of a full row is the assumption the dead-zone fix
// rests on, so it is fitted from SPICE and carried here, not divided by 5 in
// three different files.
//
// Baseline note: this model used to implement injection (edge replacement via
// inj_win_n/inj_edge plus a lock-range test). There is no injection path — the
// loop corrects the oscillator only through `code` — so those ports and that
// behavior are gone along with the macro's injection pins (DR-012/DR-013).
`timescale 1ns/1fs
`include "dco_arch.vh"
module dco_model #(parameter real MISM = 0.0, parameter SEED = 1,
                   parameter real JIT_SCALE = 1.0) (   // 0 disables jitter (fast sim)
  input  wire [`DCO_CODE_W-1:0] code,
  input  wire        osc_en,
  output reg         osc
);
`include "dco_params.vh"
  // TB-pokeable state: temperature, supply and jitter scale are variables (not
  // parameters) so one testbench can ramp them mid-simulation.
  real temp_c = 25.0, vdd = 1.8, jit_scale = JIT_SCALE;
  integer c, m, f, sd;
  real u;
  // f_free_mhz starts at a sane value, not 0.0: the OSC block below and the
  // combinational block are both live at time 0 and their order is undefined.
  // If OSC wins the race it evaluates 500.0/0.0 = infinity, and an infinite
  // delay collapses to a zero-delay loop that hangs the simulator before any
  // initial block can even print.
  real f_free_mhz = 500.0, t_half_ns = 1.0;
  initial begin osc = 1'b0; sd = SEED; end

  // Frequency is recomputed inside the oscillator loop rather than in an
  // `always @*`. Two reasons, both learned the hard way: an @* block does not
  // run until something in its sensitivity list CHANGES, so with a static code
  // it never evaluates at all; and racing it against the oscillator loop at
  // time 0 is what produced the infinite-delay hang guarded against above.
  function real f_free_of; input integer dummy; begin
    c = code[`DCO_COARSE_MSB : `DCO_COARSE_LSB];
    m = code[`DCO_MID_MSB    : `DCO_MID_LSB];
    f = code[`DCO_FINE_MSB   : `DCO_FINE_LSB];
    u = `DCO_W_COARSE * c + `DCO_W_MID * m;         // total drive weight
    f_free_of = `DCO_FBASE_MHZ * (1.0 + `DCO_GAMMA*u)
                               / (1.0 + `DCO_CF*(`DCO_N_FINE - f));
    f_free_of = f_free_of * (1.0 + `DCO_ALPHA_T*(temp_c-25.0))
                          * (1.0 + `DCO_KV*(vdd-1.8)/1.8) * (1.0 + MISM);
  end endfunction

  // sum of 3 uniforms − 1.5 ≈ N(0,0.5) ⇒ ×2 for unit sigma (cheap Gaussian)
  function real gnoise; input integer dummy; integer k; real s; begin
    s = 0.0;
    for (k = 0; k < 3; k = k+1) s = s + (($random(sd) & 32'h7fffffff) % 10000)/10000.0;
    gnoise = (s - 1.5) * 2.0;
  end endfunction

  always begin : OSC
    f_free_mhz = f_free_of(0);
    t_half_ns = 500.0/f_free_mhz;
    if (jit_scale != 0.0)
      t_half_ns = t_half_ns + gnoise(0)*(`DCO_JIT_PS)*jit_scale*0.001;
    // Written as a NEGATED comparison on purpose: it rejects NaN and infinity
    // as well as small/negative values. `t_half_ns < 0.05` is false for NaN,
    // which would let a non-finite delay through and stall the simulation.
    if (!(t_half_ns > 0.05)) t_half_ns = 0.05;
    #(t_half_ns) osc = osc_en ? ~osc : 1'b0;   // osc_en low ⇒ ring parked, as in dco_matrix
  end
endmodule
