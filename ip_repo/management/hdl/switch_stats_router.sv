// Management statistics routing: preserves switch_top's 13-bank mailbox decode.
module switch_stats_router (
  input wire stats_request,
  input wire [7:0] stats_index,
  output wire stats_ack,
  output wire [31:0] stats_value,
  output wire [3:0] stats_select,
  output wire [1:0] gem0_req,
  input wire [1:0] gem0_acks,
  input wire [63:0] gem0_values,
  output wire [1:0] gem1_req,
  input wire [1:0] gem1_acks,
  input wire [63:0] gem1_values,
  output wire [0:0] pl0_req,
  input wire [0:0] pl0_acks,
  input wire [31:0] pl0_values,
  output wire [0:0] pl1_req,
  input wire [0:0] pl1_acks,
  input wire [31:0] pl1_values,
  output wire [0:0] sfp_req,
  input wire [0:0] sfp_acks,
  input wire [31:0] sfp_values,
  output wire [5:0] fabric_req,
  input wire [5:0] fabric_acks,
  input wire [191:0] fabric_values
);
wire [12:0] stats_req, stats_acks;
wire [12:0][31:0] stats_values;
assign stats_select = stats_index[3:0];
assign gem0_req = stats_req[1:0];
assign stats_acks[1:0] = gem0_acks;
assign stats_values[1:0] = gem0_values;
assign gem1_req = stats_req[3:2];
assign stats_acks[3:2] = gem1_acks;
assign stats_values[3:2] = gem1_values;
assign pl0_req = stats_req[4:4];
assign stats_acks[4:4] = pl0_acks;
assign stats_values[4:4] = pl0_values;
assign pl1_req = stats_req[5:5];
assign stats_acks[5:5] = pl1_acks;
assign stats_values[5:5] = pl1_values;
assign sfp_req = stats_req[6:6];
assign stats_acks[6:6] = sfp_acks;
assign stats_values[6:6] = sfp_values;
assign fabric_req = stats_req[12:7];
assign stats_acks[12:7] = fabric_acks;
assign stats_values[12:7] = fabric_values;
for (genvar k=0; k<13; k=k+1) begin : stats_decode
  assign stats_req[k] = stats_request && stats_index[7:4] == k;
end
assign stats_ack = stats_index[7:4] < 13 ? stats_acks[stats_index[7:4]] : stats_request;
assign stats_value = stats_index[7:4] < 13 ? stats_values[stats_index[7:4]] : 0;
endmodule
