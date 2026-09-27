// Management statistics routing: independent 13-bank mailbox ownership.
module switch_stats_router (
  input wire clk, rst_n, stats_take,
  input wire stats_request,
  input wire [7:0] stats_index,
  output wire stats_ack,
  output wire [31:0] stats_value,
  output wire [31:0] stats_state,
  output wire [7:0] gem0_select,
  input wire [7:0] gem0_activity,
  output wire [1:0] gem0_req,
  input wire [1:0] gem0_acks,
  input wire [63:0] gem0_values,
  output wire [7:0] gem1_select,
  input wire [7:0] gem1_activity,
  output wire [1:0] gem1_req,
  input wire [1:0] gem1_acks,
  input wire [63:0] gem1_values,
  output wire [3:0] pl0_select,
  input wire [3:0] pl0_activity,
  output wire [0:0] pl0_req,
  input wire [0:0] pl0_acks,
  input wire [31:0] pl0_values,
  output wire [3:0] pl1_select,
  input wire [3:0] pl1_activity,
  output wire [0:0] pl1_req,
  input wire [0:0] pl1_acks,
  input wire [31:0] pl1_values,
  output wire [3:0] sfp_select,
  input wire [3:0] sfp_activity,
  output wire [0:0] sfp_req,
  input wire [0:0] sfp_acks,
  input wire [31:0] sfp_values,
  output wire [23:0] fabric_select,
  input wire [23:0] fabric_activity,
  output wire [5:0] fabric_req,
  input wire [5:0] fabric_acks,
  input wire [191:0] fabric_values
);
wire [12:0] stats_req, stats_acks;
wire [12:0][31:0] stats_values;
wire [12:0][3:0] stats_select, stats_activity;
assign gem0_select = stats_select[1:0];
assign stats_activity[1:0] = gem0_activity;
assign gem0_req = stats_req[1:0];
assign stats_acks[1:0] = gem0_acks;
assign stats_values[1:0] = gem0_values;
assign gem1_select = stats_select[3:2];
assign stats_activity[3:2] = gem1_activity;
assign gem1_req = stats_req[3:2];
assign stats_acks[3:2] = gem1_acks;
assign stats_values[3:2] = gem1_values;
assign pl0_select = stats_select[4:4];
assign stats_activity[4:4] = pl0_activity;
assign pl0_req = stats_req[4:4];
assign stats_acks[4:4] = pl0_acks;
assign stats_values[4:4] = pl0_values;
assign pl1_select = stats_select[5:5];
assign stats_activity[5:5] = pl1_activity;
assign pl1_req = stats_req[5:5];
assign stats_acks[5:5] = pl1_acks;
assign stats_values[5:5] = pl1_values;
assign sfp_select = stats_select[6:6];
assign stats_activity[6:6] = sfp_activity;
assign sfp_req = stats_req[6:6];
assign stats_acks[6:6] = sfp_acks;
assign stats_values[6:6] = sfp_values;
assign fabric_select = stats_select[12:7];
assign stats_activity[12:7] = fabric_activity;
assign fabric_req = stats_req[12:7];
assign stats_acks[12:7] = fabric_acks;
assign stats_values[12:7] = fabric_values;
stats_mailboxes mailboxes (.clk(clk),.rst_n(rst_n),.request(stats_request),.take(stats_take),
  .index(stats_index),.ack(stats_ack),.value(stats_value),.status(stats_state),
  .source_request(stats_req),.source_select(stats_select),.source_ack(stats_acks),
  .source_value(stats_values),.source_activity(stats_activity));
endmodule
