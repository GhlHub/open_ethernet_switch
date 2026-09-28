`timescale 1ns/1ps
module tb_sfp_wide_buffer;
 import buf_mgr_pkg::*;
 import axi_dma_pkg::*;
 reg clk=0,rst_n=0;
 always #4 clk=~clk;
 reg [127:0] data=0;
 reg [15:0] keep=0;
 reg valid=0,last=0,bad=0;
 wire ready,alloc,ing_req,enq;
 reg alloc_gnt=0,ing_gnt=0,rd_en=0,ing_done=0,enq_gnt=0;
 reg [BEAT_IDX_W-1:0] addr=0;
 wire [127:0] ram_data;
 wire [LENGTH_W-1:0] length;
 ingress_port_wr #(.PORT_ID(4),.DATA_WIDTH(128)) ingress (
 .clk(clk),.rst_n(rst_n),.s_axis_tdata(data),.s_axis_tkeep(keep),.s_axis_tvalid(valid),.s_axis_tlast(last),.s_axis_tuser(bad),.s_axis_tready(ready),
 .dest_mask_i(6'b000001),.dest_mask_valid_i(1'b1),.alloc_req_o(alloc),.alloc_gnt_i(alloc_gnt),.alloc_bufid_i(BUF_ID_W'(7)),
 .enqueue_req_o(enq),.enqueue_gnt_i(enq_gnt),.frame_ready_o(ing_req),.frame_length_o(length),.frame_gnt_i(ing_gnt),
 .frame_rd_en_i(rd_en),.frame_rd_addr_i(addr),.frame_rd_data_o(ram_data),.frame_dma_done_i(ing_done));
 reg dq_valid=0,egr_gnt=0,wr_en=0,egr_done=0,release_gnt=0,rxready=0;
 reg [127:0] wr_data=0;
 reg [BEAT_IDX_W-1:0] wr_addr=0;
 reg [LENGTH_W-1:0] dq_length=0;
 wire dq_req,egr_req,release_req,rxvalid,rxlast;
 wire [127:0] rxdata;
 wire [15:0] rxkeep;
 egress_port_rd_wide #(.PORT_ID(4)) egress (
 .clk(clk),.rst_n(rst_n),.m_axis_tdata(rxdata),.m_axis_tkeep(rxkeep),.m_axis_tvalid(rxvalid),.m_axis_tlast(rxlast),.m_axis_tready(rxready),
 .dequeue_req_o(dq_req),.dequeue_valid_i(dq_valid),.dequeue_bufid_i(BUF_ID_W'(7)),.dequeue_length_i(dq_length),
 .release_req_o(release_req),.release_gnt_i(release_gnt),.frame_req_o(egr_req),.frame_gnt_i(egr_gnt),
 .frame_wr_en_i(wr_en),.frame_wr_addr_i(wr_addr),.frame_wr_data_i(wr_data),.frame_dma_done_i(egr_done));
 function [7:0] octet(input integer n);octet=(n*13)^8'hca;endfunction
 task send(input integer len,malformed);
 begin
 for(integer base=0;base<len;base=base+16) begin
   @(negedge clk);data=0;keep=0;
   for(integer b=0;b<16;b=b+1) if(base+b<len) begin data[b*8+:8]=octet(base+b);keep[b]=1;end
   valid=1;last=base+16>=len;bad=malformed==1 && base==16;
   if(malformed==2 && base==0) keep=16'hfffd;
   do @(posedge clk);while(!ready);
 end
 @(negedge clk);valid=0;last=0;bad=0;
 end
 endtask
 task transfer(input integer len);
 integer offset,beats,b;
 reg [145:0] held;
 begin
 send(len,0);wait(alloc);
 @(negedge clk);alloc_gnt=1;@(negedge clk);alloc_gnt=0;
 wait(ing_req);if(length!=len) $fatal(1,"ingress length %0d != %0d",length,len);
 @(negedge clk);ing_gnt=1;dq_valid=1;dq_length=len;
 @(negedge clk);ing_gnt=0;dq_valid=0;
 wait(egr_req);@(negedge clk);egr_gnt=1;@(negedge clk);egr_gnt=0;
 beats=(len+15)/16;
 for(b=0;b<beats;b=b+1) begin
   @(negedge clk);rd_en=1;addr=b;
   @(negedge clk);rd_en=0;wr_en=1;wr_addr=b;wr_data=ram_data;
   for(integer lane=0;lane<16;lane=lane+1) if(b*16+lane<len && ram_data[lane*8+:8]!==octet(b*16+lane)) $fatal(1,"ingress RAM byte mismatch");
   @(negedge clk);wr_en=0;
   if(release_req || rxvalid) $fatal(1,"early release/transmit");
 end
 @(negedge clk);ing_done=1;egr_done=1;
 @(negedge clk);ing_done=0;egr_done=0;
 wait(enq && release_req);
 repeat(3) begin @(negedge clk);if(rxvalid) $fatal(1,"transmit before release");end
 enq_gnt=1;release_gnt=1;
 @(negedge clk);enq_gnt=0;release_gnt=0;
 offset=0;
 while(offset<len) begin
   wait(rxvalid);@(negedge clk);rxready=0;held={rxvalid,rxlast,rxkeep,rxdata};
   repeat(3) begin @(negedge clk);if({rxvalid,rxlast,rxkeep,rxdata}!==held) $fatal(1,"egress changed during stall");end
   for(integer lane=0;lane<16;lane=lane+1) begin
     if(rxkeep[lane] !== (offset+lane<len)) $fatal(1,"egress keep");
     if(rxkeep[lane] && rxdata[lane*8+:8]!==octet(offset+lane)) $fatal(1,"egress byte");
   end
   if(rxlast !== (offset+16>=len)) $fatal(1,"egress last");
   rxready=1;@(negedge clk);rxready=0;offset=offset+16;
 end
 wait(dq_req && ready);
 end
 endtask
 initial begin
 #100;@(negedge clk);rst_n=1;
 transfer(60);transfer(64);transfer(65);transfer(1514);transfer(2048);
 send(80,1);repeat(5) @(negedge clk);if(alloc || !ready) $fatal(1,"nonfinal tuser not dropped");
 send(80,2);repeat(5) @(negedge clk);if(alloc || !ready) $fatal(1,"sparse keep not dropped");
 send(2064,0);repeat(5) @(negedge clk);if(alloc || !ready) $fatal(1,"oversize not dropped");
 transfer(61);
 $display("PASS: 128-bit ingress/egress RAM, byte order, tail keeps, release ordering, stalls and malformed/oversize drops");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
