// CPU MM2S ABI 1: first 16-bit beat is {8'hA5, reserved=0,
// directed, reserved=0, physical_port_mask[4:0]}. Ordinary frames use A500.
// Strip metadata before Ethernet parsing/storage. Hold it until enqueue, so
// accepting a following DMA transfer cannot change an earlier frame's route.
// Reset must quiesce/reset MM2S too: resuming a partially transmitted packet
// after resetting this parser is not supported.
module cpu_tx_framer (
  input wire clk, rst_n,
  input wire [15:0] s_data,
  input wire [1:0] s_keep,
  input wire s_valid, s_last,
  output wire s_ready,
  output wire [15:0] m_data,
  output wire [1:0] m_keep,
  output wire m_valid, m_last,
  input wire m_ready,
  input wire frame_done,
  output reg directed,
  output reg [5:0] dest_mask
);
  typedef enum logic [1:0] {HEADER, BODY, WAIT_DONE, DROP} state_t;
  state_t state;
  wire header_ok = s_keep == 2'b11 && s_data[15:8] == 8'hA5 &&
                   !s_data[7] && !s_data[5] &&
                   (s_data[6] || s_data[4:0] == 0);
  assign s_ready = rst_n && ((state == HEADER || state == DROP) ||
                            (state == BODY && m_ready));
  assign m_valid = rst_n && state == BODY && s_valid;
  assign m_data = s_data;
  assign m_keep = s_keep;
  assign m_last = s_last;
  always @(posedge clk) begin
    if (!rst_n) begin state <= HEADER; directed <= 0; dest_mask <= 0; end
    else case (state)
      HEADER: if (s_valid && s_ready) begin
        directed <= 0; dest_mask <= 0;
        if (!s_last) begin
          if (header_ok) begin
            directed <= s_data[6]; dest_mask <= {1'b0,s_data[4:0]};
            state <= BODY;
          end else state <= DROP;
        end
      end
      BODY: if (s_valid && s_ready && s_last) state <= WAIT_DONE;
      WAIT_DONE: if (frame_done) begin
        state <= HEADER; directed <= 0; dest_mask <= 0;
      end
      DROP: if (s_valid && s_ready && s_last) state <= HEADER;
      default: begin state <= HEADER; directed <= 0; dest_mask <= 0; end
    endcase
  end
endmodule
