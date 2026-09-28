// 128-bit SFP egress. DDR ownership ends only after the complete local copy.
module egress_port_rd_wide
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
#(
  parameter int PORT_ID = 0
) (
  input  logic clk,
  input  logic rst_n,

  // AXI4-Stream TX out (128-bit)
  output logic [127:0] m_axis_tdata,
  output logic [15:0] m_axis_tkeep,
  output logic         m_axis_tvalid,
  output logic         m_axis_tlast,
  input  logic         m_axis_tready,

  // buf_mgr_core dequeue (this port's slot)
  output logic                dequeue_req_o,
  input  logic                dequeue_valid_i,
  input  logic [BUF_ID_W-1:0] dequeue_bufid_i,
  input  logic [LENGTH_W-1:0] dequeue_length_i,

  // buf_mgr_core release (this port's slot)
  output logic                release_req_o,
  output logic [BUF_ID_W-1:0] release_bufid_o,
  input  logic                release_gnt_i,

  // shared egress_dma_rd engine handshake
  output logic                  frame_req_o,     // level: this port wants a DMA read
  output logic [BUF_ID_W-1:0]   frame_bufid_o,
  output logic [LENGTH_W-1:0]   frame_length_o,
  input  logic                  frame_gnt_i,     // shared engine has selected this port
  input  logic                  frame_wr_en_i,   // shared engine writing a beat this cycle
  input  logic [BEAT_IDX_W-1:0] frame_wr_addr_i,
  input  logic [AXI_DATA_W-1:0] frame_wr_data_i,
  input  logic                  frame_dma_done_i
);


  logic [127:0] ram [0:BEATS_PER_BUFFER-1];
  typedef enum logic [2:0] {DEQUEUE,DMA_REQ,DMA_COPY,RELEASE,STREAM} state_t;
  state_t state;
  logic [BUF_ID_W-1:0] bufid;
  logic [LENGTH_W-1:0] length;
  logic [BEAT_IDX_W:0] read_index, beats;
  logic valid, last;
  logic [127:0] data;
  logic [15:0] keep;
  wire load = state==STREAM && (!valid || m_axis_tready) && read_index<beats;
  always_ff @(posedge clk) begin
    if (state==DMA_COPY && frame_wr_en_i) ram[frame_wr_addr_i] <= frame_wr_data_i;
    if (load) data <= ram[read_index[BEAT_IDX_W-1:0]];
  end
  assign dequeue_req_o = state==DEQUEUE;
  assign frame_req_o = state==DMA_REQ;
  assign frame_bufid_o=bufid;
  assign frame_length_o=length;
  assign release_req_o=state==RELEASE;
  assign release_bufid_o=bufid;
  assign m_axis_tdata=data;
  assign m_axis_tkeep=keep;
  assign m_axis_tvalid=valid;
  assign m_axis_tlast=last;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state<=DEQUEUE; valid<=0; last<=0; keep<=0;
      read_index<=0; beats<=0; length<=0; bufid<=0;
    end else begin
      if (valid && m_axis_tready) valid<=0;
      case(state)
        DEQUEUE: if (dequeue_valid_i) begin
          bufid<=dequeue_bufid_i; length<=dequeue_length_i;
          beats<=(BEAT_IDX_W+1)'((32'(dequeue_length_i)+15)>>4);
          read_index<=0; state<=DMA_REQ;
        end
        DMA_REQ: if (frame_gnt_i) state<=DMA_COPY;
        DMA_COPY: if (frame_dma_done_i) state<=RELEASE;
        RELEASE: if (release_gnt_i) begin
          if (length==0) state<=DEQUEUE; else state<=STREAM;
        end
        STREAM: begin
          if (load) begin
            valid<=1; last<=read_index+1==beats;
            keep<=(read_index+1==beats && length[3:0]!=0) ?
                     (16'hffff >> (16-length[3:0])) : 16'hffff;
            read_index<=read_index+1'b1;
          end
          if (valid && m_axis_tready && last) state<=DEQUEUE;
        end
        default: state<=DEQUEUE;
      endcase
    end
  end
endmodule
