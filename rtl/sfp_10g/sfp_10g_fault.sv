// XGMII link-fault reconciliation. Four matching sequence ordered sets
// qualify a fault; 128 columns without fault sequences clear it.
module sfp_10g_fault (
 input wire rx_clk,rx_rst_n,tx_clk,tx_rst_n,phy_ready,
 input wire [63:0] rxd,mac_txd,
 input wire [7:0] rxc,mac_txc,
 output reg [63:0] txd = 64'h0200009c0200009c,
 output reg [7:0] txc = 8'h11,
 output reg link_up=0,remote_fault=0,
 output wire tx_permit
);
 reg [1:0] candidate,fault;
 reg local_fault=1;
 reg [2:0] count;
 reg [7:0] quiet;
 reg [1:0] candidate_next,fault_next;
 reg [2:0] count_next;
 reg [7:0] quiet_next;
 reg [1:0] sequence_fault;
 always @* begin
   candidate_next=candidate;fault_next=fault;count_next=count;quiet_next=quiet;
   sequence_fault=0;
   for(integer column=0;column<2;column=column+1) begin
     sequence_fault=0;
     if(rxc[column*4+:4]==4'b0001 && rxd[column*32+:24]==24'h00009c) begin
       if(rxd[column*32+24+:8]==1) sequence_fault=1;
       if(rxd[column*32+24+:8]==2) sequence_fault=2;
     end
     if(sequence_fault!=0) begin
       quiet_next=0;
       if(candidate_next!=sequence_fault) begin candidate_next=sequence_fault;count_next=1;end
       else if(count_next<4) count_next=count_next+1'b1;
       if(count_next==4) fault_next=sequence_fault;
     end else if(quiet_next<128) begin
       quiet_next=quiet_next+1'b1;
       if(quiet_next==128) begin fault_next=0;candidate_next=0;count_next=0;end
     end
   end
 end
 // Register decoded status before it crosses into TX and management clocks.
 // Asynchronous assertion also removes link admission if the RX clock stops.
 always @(posedge rx_clk or negedge rx_rst_n) begin
   if(!rx_rst_n) begin
     candidate<=0;fault<=0;count<=0;quiet<=0;
     local_fault<=1;remote_fault<=0;link_up<=0;
   end else if(!phy_ready) begin
     candidate<=0;fault<=0;count<=0;quiet<=0;
     local_fault<=1;remote_fault<=0;link_up<=0;
   end else begin
     candidate<=candidate_next;fault<=fault_next;count<=count_next;quiet<=quiet_next;
     local_fault<=fault_next==1;remote_fault<=fault_next==2;link_up<=fault_next==0;
   end
 end
 (* ASYNC_REG="TRUE" *) reg [1:0] local_sync,remote_sync;
 always @(posedge tx_clk) begin
   if(!tx_rst_n) begin local_sync<=3;remote_sync<=0;end
   else begin local_sync<={local_sync[0],local_fault};remote_sync<={remote_sync[0],remote_fault};end
   if(!tx_rst_n || local_sync[1]) begin txd<=64'h0200009c0200009c;txc<=8'h11;end
   else if(remote_sync[1]) begin txd<=64'h0707070707070707;txc<=8'hff;end
   else begin txd<=mac_txd;txc<=mac_txc;end
 end
 assign tx_permit=!local_sync[1] && !remote_sync[1];
endmodule
