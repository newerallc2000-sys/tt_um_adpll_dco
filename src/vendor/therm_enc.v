// therm_enc — binary → thermometer (glitch containment: outputs are registered
// on win boundary upstream; combinational here). out[i] = (bin > i).
module therm_enc #(parameter BW = 3, TW = 7) (
  input  wire [BW-1:0] bin,
  output wire [TW-1:0] therm
);
  genvar i;
  generate for (i = 0; i < TW; i = i+1) begin : g
    assign therm[i] = (bin > i[BW-1:0]);
  end endgenerate
endmodule
