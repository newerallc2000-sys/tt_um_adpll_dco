// dco_fcounter — the on-chip frequency meter.
//
//     f_osc = 2^TAP * N * f_clk / 2^WIN_LOG2
//
// Counts edges of a divided tap of the ring for a window of 2^WIN_LOG2 cycles
// of the Tiny Tapeout clock, then shifts the count out serially. The demo
// board's RP2040 supplies the clock and reads the frame; no external counter,
// no oscilloscope, and no analogue instrument is needed to characterise the
// oscillator.
//
// WHY THIS IS WORTH THE CELLS. At f_clk = 25 MHz the window is 2.62 ms and one
// count is 6.10 kHz -- 39x finer than the parent's 0.239 MHz fine LSB. That
// turns the complete 8 x 32 x 96 = 24576-code surface into a five-minute sweep
// per die, which is what makes the die-to-die mismatch experiment (the parent's
// open item 4) possible at all.
//
// ABSOLUTE vs RELATIVE ACCURACY. Absolute accuracy is entirely the demo board
// crystal's, ~30 ppm. It cancels exactly in every RATIO -- bank step sizes,
// WEIGHT[mid], seam overlap -- which is where all of the physics under test
// lives. Do not quote an absolute frequency to more digits than the crystal
// supports.
//
// THE CDC, AND WHY IT IS SAFE. Three crossings, each argued separately:
//
//  1. clk -> div: `win_tog`, one bit, through a 2-flop synchroniser. A one-bit
//     level crossing is the case a 2-flop synchroniser is for.
//  2. div -> clk: `cap`, CNT_W bits. This is a multi-bit bus and a synchroniser
//     would NOT make it safe. It is safe for a different reason: `cap` is
//     written once per window and then held for ~65 000 clk cycles, and the clk
//     domain samples it 64 cycles before the NEXT window boundary -- roughly a
//     full window away from the only instant it can change. The safety argument
//     is temporal, not structural, and the SDC must carry it as a false path
//     with a max-delay rather than leaving it to be discovered.
//  3. div -> clk: `cap_tog`, one bit, 2-flop synchronised. Only used to detect
//     that the ring is alive.
//
// The window is defined in the clk domain and transferred through (1), so each
// end of it carries up to one divided-tap period of uncertainty: +/-1 count,
// which is the 6.10 kHz already in the error budget above.
//
// THE PRIMING LESSON, INHERITED -- AND IT BIT AGAIN HERE. The parent's
// delta_capture reported 52 counts of error on its first window where the truth
// was 4, because it differenced against a reset value that had never been a
// snapshot; one flop fixed it, at the cost of one window. This block counts from
// zero inside each window rather than differencing, so it looked immune. It was
// not. The interval the div domain counts is bounded by two boundary DETECTIONS,
// which lag the real window boundaries by the synchroniser's 2-3 divided
// periods. Between windows that lag cancels; on the FIRST window it is measured
// against a reset instant that had no lag, so the first capture is long by
// exactly the synchroniser depth. tb_fcounter measured it: 44 counts where 41.7
// were due, +5.6 %, and at a low tap rate it does not look like an error at all.
//
// `primed` is that one flop. The first boundary after reset starts a clean
// window and writes nothing; every capture that reaches `cap` is bounded by two
// detections and is therefore exact. The host still discards two frames after
// reset -- the clk domain emits frames before any capture exists, because a
// frame that never arrives is indistinguishable from a dead ring -- and the
// bring-up procedure does that unconditionally after every code change too.
`default_nettype none

module dco_fcounter #(
  parameter integer WIN_LOG2 = 16,   // window = 2^WIN_LOG2 clk cycles
  parameter integer CNT_W    = 20    // counter and frame width
) (
  input  wire clk,                   // TT clock: the time base AND the readout clock
  input  wire rst_n,
  input  wire div_in,                // a divided tap of the ring
  output reg  data,                  // serial frame, MSB first
  output reg  valid,                 // one clk pulse, one cycle before the MSB
  output reg  strobe,                // toggles once per shifted bit
  output reg  alive,                 // the div domain has produced a capture
  output reg  ovf                    // sticky: a window overflowed CNT_W bits
);

  // Latch the frame this many clk cycles before the window boundary. Far enough
  // from the div domain's own update (which happens 2-3 divided periods AFTER
  // the boundary) that the two can never be adjacent, and wide enough to shift
  // CNT_W bits out before the next boundary arrives.
  localparam integer TAIL = 64;
  localparam [WIN_LOG2-1:0] LATCH_AT = {WIN_LOG2{1'b1}} - TAIL[WIN_LOG2-1:0];

  // ------------------------------------------------------------------ clk domain
  reg [WIN_LOG2-1:0] win_cnt;
  reg                win_tog;

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      win_cnt <= {WIN_LOG2{1'b0}};
      win_tog <= 1'b0;
    end else begin
      win_cnt <= win_cnt + 1'b1;
      if (&win_cnt) win_tog <= ~win_tog;      // toggles as win_cnt wraps
    end

  // ------------------------------------------------------------------ div domain
  // Everything here is clocked by div_in, which is asynchronous to clk and stops
  // entirely when the ring is parked. Nothing downstream may depend on it running.
  reg        wt_s1, wt_s2, wt_s3;             // 2-flop sync + edge detect
  reg [CNT_W-1:0] cnt;
  reg [CNT_W-1:0] cap;
  reg        cap_tog;
  reg        ovf_div;
  reg        primed;      // see the priming note in the header

  wire boundary = wt_s2 ^ wt_s3;

  always @(posedge div_in or negedge rst_n)
    if (!rst_n) begin
      wt_s1 <= 1'b0; wt_s2 <= 1'b0; wt_s3 <= 1'b0;
      cnt <= {CNT_W{1'b0}};
      cap <= {CNT_W{1'b0}};
      cap_tog <= 1'b0;
      ovf_div <= 1'b0;
      primed  <= 1'b0;
    end else begin
      wt_s1 <= win_tog;
      wt_s2 <= wt_s1;
      wt_s3 <= wt_s2;
      if (boundary) begin
        if (primed) begin                      // the first boundary only primes
          cap     <= cnt;
          cap_tog <= ~cap_tog;
        end
        primed  <= 1'b1;
        cnt     <= {{(CNT_W-1){1'b0}}, 1'b1};  // this edge belongs to the new window
      end else begin
        if (&cnt) ovf_div <= 1'b1;             // sticky, never wraps silently
        cnt <= cnt + 1'b1;
      end
    end

  // ------------------------------------------------------------------ readout
  reg [CNT_W-1:0] frame;
  reg [$clog2(CNT_W+1)-1:0] shift_cnt;
  reg ct_s1, ct_s2, ct_s3, ovf_s1, ovf_s2;

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      frame <= {CNT_W{1'b0}};
      shift_cnt <= 0;
      data <= 1'b0; valid <= 1'b0; strobe <= 1'b0;
      ct_s1 <= 1'b0; ct_s2 <= 1'b0; ct_s3 <= 1'b0;
      ovf_s1 <= 1'b0; ovf_s2 <= 1'b0;
      alive <= 1'b0; ovf <= 1'b0;
    end else begin
      // Three stages, not two: the edge detect must compare two SETTLED copies.
      // Comparing against ct_s1 would be comparing against the flop that is
      // allowed to be metastable, which is the mistake a synchroniser exists to
      // prevent.
      ct_s1 <= cap_tog;  ct_s2 <= ct_s1;  ct_s3 <= ct_s2;
      ovf_s1 <= ovf_div; ovf_s2 <= ovf_s1;
      if (ct_s3 != ct_s2) alive <= 1'b1;        // the div domain is producing captures
      ovf   <= ovf_s2;
      valid <= 1'b0;
      if (win_cnt == LATCH_AT) begin
        frame     <= cap;                       // stable for ~a full window: see header
        shift_cnt <= CNT_W[$clog2(CNT_W+1)-1:0];
        valid     <= 1'b1;
      end else if (shift_cnt != 0) begin
        data      <= frame[shift_cnt-1];
        strobe    <= ~strobe;
        shift_cnt <= shift_cnt - 1'b1;
      end
    end

endmodule

`default_nettype wire
