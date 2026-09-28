// Frame-boundary gate. Discard decisions persist to TLAST. RX has an output
// register so link loss cannot change a stalled AXI beat; incomplete frames
// terminate with a bad TLAST after that beat has been accepted.
module sfp_dual_stream_gate(
 input wire clk,rst_n,run,allow_new,tx_enable,rx_enable,
 input wire [127:0] s_tx_data,input wire [15:0] s_tx_keep,input wire s_tx_valid,s_tx_last,
 output wire s_tx_ready,output wire [127:0] m_tx_data,output wire [15:0] m_tx_keep,
 output wire m_tx_valid,m_tx_last,input wire m_tx_ready,
 input wire [127:0] s_rx_data,input wire [15:0] s_rx_keep,input wire s_rx_valid,s_rx_last,s_rx_user,
 output wire s_rx_ready,output reg [127:0] m_rx_data,output reg [15:0] m_rx_keep,
 output reg m_rx_valid,m_rx_last,m_rx_user,input wire m_rx_ready,output wire idle);
 reg tx_frame,tx_drop,rx_frame,rx_drop,rx_out_frame,abort_pending,run_d;
 wire tx_admit=run && (tx_frame?!tx_drop:(allow_new && tx_enable));
 assign s_tx_ready=tx_admit?m_tx_ready:1'b1;
 assign m_tx_valid=s_tx_valid && tx_admit;
 assign m_tx_data=s_tx_data;assign m_tx_keep=s_tx_keep;assign m_tx_last=s_tx_last;
 wire rx_admit=run && !abort_pending && (rx_frame?!rx_drop:(allow_new && rx_enable));
 wire slot_free=!m_rx_valid || m_rx_ready;
 assign s_rx_ready=rx_admit?slot_free:1'b1;
 assign idle=!tx_frame && !(rx_frame && !rx_drop) && !m_rx_valid && !rx_out_frame && !abort_pending;
 always @(posedge clk) begin
  if(!rst_n) begin
   tx_frame<=0;tx_drop<=0;rx_frame<=0;rx_drop<=0;rx_out_frame<=0;
   abort_pending<=0;run_d<=0;m_rx_valid<=0;m_rx_data<=0;m_rx_keep<=0;m_rx_last<=0;m_rx_user<=0;
  end else begin
   run_d<=run;
   if(!run && tx_frame) tx_drop<=1;
   if(s_tx_valid && s_tx_ready) begin
    tx_frame<=!s_tx_last;
    if(s_tx_last) tx_drop<=0;
    else if(!tx_frame || !run) tx_drop<=!tx_admit;
   end
   if(m_rx_valid && m_rx_ready) rx_out_frame<=!m_rx_last;
   if(s_rx_valid && s_rx_ready && run) begin
    rx_frame<=!s_rx_last;
    if(s_rx_last) rx_drop<=0;else if(!rx_frame) rx_drop<=!rx_admit;
   end
   if(slot_free) begin
    m_rx_valid<=0;
    if(abort_pending) begin
     m_rx_valid<=1;m_rx_data<=0;m_rx_keep<=1;m_rx_last<=1;m_rx_user<=1;abort_pending<=0;
    end else if(s_rx_valid && rx_admit) begin
     m_rx_valid<=1;m_rx_data<=s_rx_data;m_rx_keep<=s_rx_keep;m_rx_last<=s_rx_last;m_rx_user<=s_rx_user;
    end
   end
   if(!run && run_d) begin
    rx_frame<=0;rx_drop<=0;
    if((rx_out_frame || m_rx_valid) && !(m_rx_valid && m_rx_last)) abort_pending<=1;
   end
  end
 end
endmodule
