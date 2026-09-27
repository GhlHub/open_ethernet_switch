// Independent management-domain ownership of destructive source reads.
// A CPU timeout never cancels a source request. A result is retained until
// take, even if the source clock stops after asserting ACK. Each source slot
// remains stable through ACK release before that bank can accept another read.
module stats_mailboxes #(
  parameter integer CLOCK_TIMEOUT = 2047
)(
  input wire clk, rst_n, request, take,
  input wire [7:0] index,
  output wire ack,
  output wire [31:0] value, status,
  output reg [12:0] source_request,
  output reg [12:0][3:0] source_select,
  input wire [12:0] source_ack,
  input wire [12:0][31:0] source_value,
  input wire [12:0][3:0] source_activity
);
  (* ASYNC_REG = "TRUE" *) reg [12:0] ack_meta, ack_sync;
  (* ASYNC_REG = "TRUE" *) reg [12:0][3:0] activity_meta, activity_sync;
  reg [12:0][3:0] activity_last;
  reg [12:0] pending, ready, clock_alive, clock_gap;
  reg [12:0][31:0] saved;
  reg [$clog2(CLOCK_TIMEOUT+2)-1:0] quiet [13];
  wire valid_bank = index[7:4] < 13;
  wire [3:0] bank = index[7:4];
  assign ack = request && (!valid_bank || (ready[bank] && source_select[bank] == index[3:0]));
  assign value = valid_bank ? saved[bank] : 0;
  // bit0 pending result; bit1 ready; bit2 source release busy; bit3 clock
  // progressing; bits7:4 retained slot. These are all management-clock signals.
  assign status = valid_bank ? {23'd0,clock_gap[bank],source_select[bank],clock_alive[bank],
                               ack_sync[bank],ready[bank],pending[bank]} : 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      ack_meta <= 0; ack_sync <= 0;
      activity_meta <= 0; activity_sync <= 0; activity_last <= 0;
      pending <= 0; ready <= 0; clock_alive <= 0; clock_gap <= 0;
      source_request <= 0; source_select <= 0; saved <= 0;
      for (integer b=0;b<13;b=b+1) quiet[b] <= 0;
    end else begin
      ack_meta <= source_ack; ack_sync <= ack_meta;
      activity_meta <= source_activity; activity_sync <= activity_meta;
      activity_last <= activity_sync;
      for (integer b=0;b<13;b=b+1) begin
        if (activity_sync[b] != activity_last[b]) begin
          quiet[b] <= 0; clock_alive[b] <= 1;
        end else if (quiet[b] >= CLOCK_TIMEOUT) clock_alive[b] <= 0;
        else quiet[b] <= quiet[b] + 1'b1;
        if (pending[b] && !clock_alive[b]) clock_gap[b] <= 1;
        if (source_request[b] && ack_sync[b]) begin
          saved[b] <= source_value[b];
          ready[b] <= 1;
          source_request[b] <= 0;
        end
        if (request && bank == b && !pending[b] && !ack_sync[b]) begin
          source_select[b] <= index[3:0];
          source_request[b] <= 1;
          pending[b] <= 1; clock_gap[b] <= !clock_alive[b];
        end
        if (take && bank == b && ready[b] && source_select[b] == index[3:0]) begin
          ready[b] <= 0; pending[b] <= 0;
        end
      end
    end
  end
endmodule
