// Always-on 50 MHz domain. Read/modify/write/readback preserves reserved bits.
// A failed operation holds the datapath in reset; a new request retries it.
module sfp_dual_reconfigure #(
 parameter integer DRP_TIMEOUT=1024, LOCK_TIMEOUT=5000000, RESET_CYCLES=128
)(input wire clk,rst_n,request_10g,retry_toggle,
 input wire power_good,pll_locked,tx_done,rx_done,
 output reg mode_10g,ready,error,
 output wire gt_reset,
 output wire [9:0] drp_addr, output reg [15:0] drp_di,
 output reg drp_en,drp_we,input wire [15:0] drp_do,input wire drp_rdy);
 localparam HOLD=0,READ=1,READ_WAIT=2,WRITE=3,WRITE_WAIT=4,
            VERIFY=5,VERIFY_WAIT=6,NEXT=7,RELEASE=8,LOCK=9,RUN=10,FAILED=11;
 reg [3:0] state;
 reg [23:0] timer;
 reg [5:0] index;
 reg seen_retry,tx_reset_seen,rx_reset_seen;
 wire [15:0] mask,value; wire last;
 sfp_dual_drp_rom rom(index,mode_10g,drp_addr,mask,value,last);
 assign gt_reset=state!=LOCK && state!=RUN;
 always @(posedge clk) begin
   if (!rst_n) begin
     state<=HOLD;timer<=0;index<=0;mode_10g<=1;ready<=0;error<=0;
     drp_en<=0;drp_we<=0;drp_di<=0;seen_retry<=0;tx_reset_seen<=0;rx_reset_seen<=0;
   end else begin
     drp_en<=0;drp_we<=0;
     case(state)
       HOLD: begin
         mode_10g<=request_10g;seen_retry<=retry_toggle;
         if(!power_good) timer<=0;
         else if(timer==RESET_CYCLES-1) begin state<=READ;timer<=0;end else timer<=timer+1'b1;
       end
       READ: begin drp_en<=1;state<=READ_WAIT;timer<=0;end
       READ_WAIT: if(drp_rdy) begin drp_di<=(drp_do & ~mask)|value;state<=WRITE;end
                  else if(timer==DRP_TIMEOUT-1) begin state<=FAILED;error<=1;end else timer<=timer+1'b1;
       WRITE: begin drp_en<=1;drp_we<=1;state<=WRITE_WAIT;timer<=0;end
       WRITE_WAIT: if(drp_rdy) state<=VERIFY;
                   else if(timer==DRP_TIMEOUT-1) begin state<=FAILED;error<=1;end else timer<=timer+1'b1;
       VERIFY: begin drp_en<=1;state<=VERIFY_WAIT;timer<=0;end
       VERIFY_WAIT: if(drp_rdy) begin
                       if((drp_do & mask)!=value) begin state<=FAILED;error<=1;end else state<=NEXT;
                    end else if(timer==DRP_TIMEOUT-1) begin state<=FAILED;error<=1;end else timer<=timer+1'b1;
       NEXT: if(last) begin state<=RELEASE;timer<=0;end else begin index<=index+1'b1;state<=READ;end
       RELEASE: if(timer==RESET_CYCLES-1) begin state<=LOCK;timer<=0;tx_reset_seen<=0;rx_reset_seen<=0;end else timer<=timer+1'b1;
       LOCK: begin
         // Wizard reset-all starts its TX-then-RX sequence on deassertion.
         // Old done flags can remain high until each sub-sequence starts.
         if(!tx_done) tx_reset_seen<=1;
         if(!rx_done) rx_reset_seen<=1;
         if(tx_reset_seen && rx_reset_seen && pll_locked && tx_done && rx_done) begin ready<=1;state<=RUN;end
         else if(timer==LOCK_TIMEOUT-1) begin state<=FAILED;error<=1;end else timer<=timer+1'b1;
       end
       RUN: if(!pll_locked || !tx_done || !rx_done) begin ready<=0;state<=LOCK;timer<=0;tx_reset_seen<=1;rx_reset_seen<=1;end
       FAILED: ready<=0;
       default: begin state<=FAILED;ready<=0;error<=1;end
     endcase
     // Requests are held stable by the digital port until ready. Only change
     // PLL/clock mux controls while the GT is held in reset in HOLD.
     if((state==RUN || state==FAILED || state==LOCK) &&
        (request_10g!=mode_10g || retry_toggle!=seen_retry)) begin
       state<=HOLD;ready<=0;error<=0;timer<=0;index<=0;
     end
   end
 end
endmodule
