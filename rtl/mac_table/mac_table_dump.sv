// Low-priority live MAC-table scan. 16 records / 256 bytes per AXI burst.
// Table reads may be preempted per entry. DDR admission yields to all packet
// DMA requests/transactions; once AWVALID is offered it cannot be withdrawn.
// One burst outstanding, no timeout/cancel of an accepted AXI transaction.
module mac_table_dump (
  input wire clk, rst_n,
  input wire packet_busy_i,
  output wire table_req_o, output wire [1:0] table_bank_o,
  output wire [8:0] table_addr_o, input wire table_gnt_i,
  input wire table_valid_i, input wire [64:0] table_data_i,
  input wire [7:0] s_axi_awaddr,
  input wire s_axi_awvalid, output wire s_axi_awready,
  input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
  input wire s_axi_wvalid, output wire s_axi_wready,
  output reg [1:0] s_axi_bresp, output reg s_axi_bvalid, input wire s_axi_bready,
  input wire [7:0] s_axi_araddr, input wire s_axi_arvalid, output wire s_axi_arready,
  output reg [31:0] s_axi_rdata, output wire [1:0] s_axi_rresp,
  output reg s_axi_rvalid, input wire s_axi_rready,
  output wire [0:0] m_axi_awid, output wire [31:0] m_axi_awaddr,
  output wire [7:0] m_axi_awlen, output wire [2:0] m_axi_awsize,
  output wire [1:0] m_axi_awburst, output wire m_axi_awvalid, input wire m_axi_awready,
  output wire [127:0] m_axi_wdata, output wire [15:0] m_axi_wstrb,
  output wire m_axi_wlast, output wire m_axi_wvalid, input wire m_axi_wready,
  input wire [0:0] m_axi_bid, input wire [1:0] m_axi_bresp,
  input wire m_axi_bvalid, output wire m_axi_bready
);
  typedef enum logic [2:0] {IDLE, READ, DRAIN, WAIT_HP, AW, DATA, RESP} state_t;
  state_t state;
  reg [31:0] destination, address, completed;
  reg [10:0] chunk_base;
  reg [4:0] issued, received;
  reg [3:0] beat;
  reg [127:0] buffer [0:15];
  reg done, error;
  reg [1:0] error_code;
  wire busy = state != IDLE;
  reg aw_hold_valid, w_hold_valid;
  reg [7:0] aw_hold;
  reg [31:0] w_hold;
  reg [3:0] strb_hold;
  wire write_fire = aw_hold_valid && w_hold_valid && !s_axi_bvalid;
  wire start = write_fire && aw_hold == 8'h08 && strb_hold[0] && w_hold[0] && !busy;
  // Full 32 KiB must fit in the PS low-DDR aperture and start on 256 bytes.
  wire address_ok = destination[7:0] == 0 && destination <= 32'h7fff8000;
  assign s_axi_awready = rst_n && !aw_hold_valid && !s_axi_bvalid;
  assign s_axi_wready = rst_n && !w_hold_valid && !s_axi_bvalid;
  assign s_axi_arready = rst_n && !s_axi_rvalid;
  assign s_axi_rresp = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      destination<=0; aw_hold_valid<=0; w_hold_valid<=0;
      s_axi_bvalid<=0; s_axi_bresp<=0; s_axi_rvalid<=0; s_axi_rdata<=0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin aw_hold<=s_axi_awaddr; aw_hold_valid<=1; end
      if (s_axi_wvalid && s_axi_wready) begin w_hold<=s_axi_wdata;strb_hold<=s_axi_wstrb;w_hold_valid<=1;end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
      if (write_fire) begin
        aw_hold_valid<=0;w_hold_valid<=0;s_axi_bvalid<=1;s_axi_bresp<=0;
        if (aw_hold==8'h04) begin
          if (busy || strb_hold!=4'hf) s_axi_bresp<=2;
          else destination<=w_hold;
        end else if (aw_hold==8'h08 && strb_hold[0] && w_hold[0]) begin
          if (busy || !address_ok) s_axi_bresp<=2;
        end
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
      if (s_axi_arvalid && s_axi_arready) begin
        s_axi_rvalid<=1;
        case (s_axi_araddr)
          8'h00: s_axi_rdata<=32'h4d445001; // MDP ABI 1
          8'h04: s_axi_rdata<=destination;
          8'h0c: s_axi_rdata<={29'd0,error,done,busy};
          8'h10: s_axi_rdata<=completed;
          8'h14: s_axi_rdata<={30'd0,error_code};
          8'h18: s_axi_rdata<=2048;
          8'h1c: s_axi_rdata<=16; // bytes/record and beats/burst
          default: s_axi_rdata<=0;
        endcase
      end
    end
  end
  wire [10:0] read_index=chunk_base+11'(issued);
  wire [10:0] response_index=chunk_base+11'(received);
  assign table_req_o = rst_n && state==READ;
  assign table_bank_o = read_index[10:9];
  assign table_addr_o = read_index[8:0];
  assign m_axi_awid=0;
  assign m_axi_awaddr=address;
  assign m_axi_awlen=15;
  assign m_axi_awsize=4;
  assign m_axi_awburst=1;
  assign m_axi_awvalid=rst_n && (state==AW || (state==WAIT_HP && !packet_busy_i));
  assign m_axi_wdata=buffer[beat];
  assign m_axi_wstrb=16'hffff;
  assign m_axi_wlast=beat==15;
  assign m_axi_wvalid=rst_n && state==DATA;
  assign m_axi_bready=rst_n && state==RESP;
  always @(posedge clk) begin
    if (!rst_n) begin
      state<=IDLE;done<=0;error<=0;error_code<=0;completed<=0;
      address<=0;chunk_base<=0;issued<=0;received<=0;beat<=0;
    end else begin
      if (start) begin
        done<=0;error<=0;error_code<=0;completed<=0;chunk_base<=0;
        address<=destination;issued<=0;received<=0;beat<=0;
        if (!address_ok) begin done<=1;error<=1;error_code<=2;end
        else state<=READ;
      end
      if (state==READ && table_gnt_i) begin
        issued<=issued+1'b1;
        if (issued==15) state<=DRAIN;
      end
      if ((state==READ || state==DRAIN) && table_valid_i) begin
        // Little endian words: MAC low32; MAC high16/mask8/reserved8;
        // age16/index16; flags32 (bit0 valid). Retain empty slots too.
        buffer[received[3:0]] <= {31'd0,(table_data_i[8:0]!=0),
                                 5'd0,response_index,7'd0,table_data_i[8:0],
                                 8'd0,table_data_i[16:9],table_data_i[64:17]};
        received<=received+1'b1;
        if (received==15) state<=WAIT_HP;
      end
      if (state==WAIT_HP && !packet_busy_i) begin
        if (m_axi_awready) state<=DATA;
        else state<=AW;
      end
      if (state==AW && m_axi_awready) state<=DATA;
      if (state==DATA && m_axi_wready) begin
        if (beat==15) state<=RESP;
        else beat<=beat+1'b1;
      end
      if (state==RESP && m_axi_bvalid) begin
        if (m_axi_bresp!=0 || m_axi_bid!=0) begin
          error<=1;error_code<=1;done<=1;state<=IDLE;
        end else begin
          completed<=completed+256;
          if (chunk_base==2032) begin done<=1;state<=IDLE;end
          else begin
            chunk_base<=chunk_base+16;address<=address+256;
            issued<=0;received<=0;beat<=0;state<=READ;
          end
        end
      end
    end
  end
endmodule
