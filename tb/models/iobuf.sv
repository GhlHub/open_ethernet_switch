// Simulation-only model of the external FPGA pad primitive.
module IOBUF(input wire I, input wire T, output wire O, inout wire IO);
  assign IO = T ? 1'bz : I;
  assign O = IO;
endmodule
