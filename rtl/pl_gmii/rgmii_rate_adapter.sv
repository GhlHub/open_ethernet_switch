// Full-duplex RGMII rate conversion. Local byte-side clock stays at 125 MHz.
// mode_i is held stable while disabled: [2] enable, [1:0] 10/100/1000 = 0/1/2.
// Firmware disables, waits for port flush/drain, changes speed, then enables.
module rgmii_rate_adapter (
  input wire clk, rst_n,
  input wire [2:0] mode_i,
  input wire [7:0] tx_data_i,
  input wire tx_en_i, tx_er_i,
  output wire tx_byte_ce_o,
  output wire [3:0] tx_rise_o, tx_fall_o,
  output wire tx_ctl_rise_o, tx_ctl_fall_o,
  output wire tx_clk_rise_o, tx_clk_fall_o,
  input wire rx_clk, rx_rst_n,
  input wire [3:0] rx_rise_i, rx_fall_i,
  input wire rx_ctl_rise_i, rx_ctl_fall_i,
  output logic [7:0] rx_data_o,
  output logic rx_dv_o, rx_er_o, rx_byte_ce_o,
  output wire overflow_o
);
  (* ASYNC_REG="TRUE" *) logic [1:0] speed_s1, speed_s2;
  (* ASYNC_REG="TRUE" *) logic [3:0] enable_sync;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin speed_s1<=2; speed_s2<=2; enable_sync<=0; end
    else begin speed_s1<=mode_i[1:0]; speed_s2<=speed_s1;
      enable_sync<={enable_sync[2:0],mode_i[2]}; end
  end
  logic enabled;
  // A byte spans two 25/2.5 MHz nibble periods at the lower speeds.
  wire gigabit=speed_s2==2;
  wire [6:0] nibble_period=speed_s2==1 ? 7'd5 : 7'd50;
  logic [6:0] phase;
  logic upper;
  // Stop only at a complete nibble-clock boundary; never shorten a low-speed
  // clock pulse when firmware quiesces a port or changes speed.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) enabled<=0;
    else if (!enabled) enabled<=enable_sync[3];
    else if (!enable_sync[3] && (gigabit || phase==nibble_period-1)) enabled<=0;
  end
  logic [7:0] tx_byte;
  logic tx_en, tx_er;
  // Advance the MAC one 125-MHz edge before latching its new byte.
  // While disabled, drain queued MAC frames at full rate without sending them.
  assign tx_byte_ce_o=!enabled || gigabit || (upper && phase==nibble_period-2);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin phase<=0; upper<=0; tx_byte<=0; tx_en<=0; tx_er<=0; end
    else if (!enabled) begin phase<=0; upper<=0; tx_byte<=0; tx_en<=0; tx_er<=0; end
    else if (gigabit) begin
      phase<=0; upper<=0; tx_byte<=tx_data_i; tx_en<=tx_en_i; tx_er<=tx_er_i;
    end else begin
      if (phase==nibble_period-1) begin
        phase<=0; upper<=!upper;
        if (upper) begin tx_byte<=tx_data_i; tx_en<=tx_en_i; tx_er<=tx_er_i; end
      end else phase<=phase+1'b1;
    end
  end
  wire [3:0] nibble=upper ? tx_byte[7:4] : tx_byte[3:0];
  assign tx_rise_o=gigabit ? tx_byte[3:0] : nibble;
  assign tx_fall_o=gigabit ? tx_byte[7:4] : nibble;
  // At 10/100, hold the control value appropriate to each physical half-cycle.
  wire clock_high=speed_s2==1 ? phase<3 : phase<25;
  assign tx_ctl_rise_o=enabled && ((gigabit || clock_high) ? tx_en : (tx_en ^ tx_er));
  assign tx_ctl_fall_o=gigabit ? enabled && (tx_en ^ tx_er) :
      enabled && ((speed_s2==1 ? phase<2 : phase<25) ? tx_en : (tx_en ^ tx_er));
  assign tx_clk_rise_o=enabled && (gigabit || clock_high);
  assign tx_clk_fall_o=enabled && !gigabit && (speed_s2==1 ? phase<2 : phase<25);

  (* ASYNC_REG="TRUE" *) logic [1:0] rx_speed_s1, rx_speed_s2;
  (* ASYNC_REG="TRUE" *) logic [3:0] rx_enable_sync;
  wire rx_run_reset_n=rx_rst_n && mode_i[2];
  always_ff @(posedge rx_clk or negedge rx_run_reset_n) begin
    if (!rx_run_reset_n) begin rx_speed_s1<=2; rx_speed_s2<=2; rx_enable_sync<=0; end
    else begin rx_speed_s1<=mode_i[1:0]; rx_speed_s2<=rx_speed_s1;
      rx_enable_sync<={rx_enable_sync[2:0],mode_i[2]}; end
  end
  logic half, prev_dv, low_er;
  logic [3:0] low_nibble;
  wire dv=rx_ctl_rise_i;
  wire er=rx_ctl_rise_i ^ rx_ctl_fall_i;
  wire full,empty;
  logic fifo_armed;
  // Assert with the synchronized enable chain, release only on RX edges.
  // This also works when the PHY stops RXC while renegotiating.
  always_ff @(posedge rx_clk or negedge rx_enable_sync[3]) begin
    if (!rx_enable_sync[3]) fifo_armed<=0;
    else if (!full && !dv) fifo_armed<=1;
  end
  wire rx_enabled=rx_enable_sync[3] && fifo_armed;
  wire sample=rx_enabled && (rx_speed_s2==2 || !dv || half);
  wire [7:0] byte_data=rx_speed_s2==2 ? {rx_fall_i,rx_rise_i} : {rx_rise_i,low_nibble};
  wire byte_er=er || (rx_speed_s2!=2 && (low_er || (!dv && half)));
  always_ff @(posedge rx_clk or negedge rx_rst_n) begin
    if (!rx_rst_n) begin half<=0; prev_dv<=0; low_nibble<=0; low_er<=0; end
    else begin
      if (!rx_enabled || !dv) half<=0;
      else if (rx_speed_s2!=2) begin
        half<=!half;
        if (!half) begin low_nibble<=rx_rise_i; low_er<=er; end
      end
      if (!rx_enabled) prev_dv<=0;
      else if (sample) prev_dv<=dv;
    end
  end
  // Byte-valid FIFO: empty between slow bytes is normal, not frame termination.
  // Store explicit frame-end tokens so the byte MAC sees every end-of-frame.
  wire push=sample && (dv || prev_dv);
  wire [17:0] head;
  fifo36_async_2kx18 fifo (
    .wr_clk(rx_clk), .wr_rst_n(rx_rst_n), .wr_en_i(push),
    .wr_data_i({8'b0,byte_er,dv,byte_data}), .wr_full_o(full), .wr_count_o(),
    .rd_clk(clk), .rd_en_i(!empty), .rd_data_o(head), .rd_empty_o(empty), .rd_count_o()
  );
  assign overflow_o=push && full;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rx_data_o<=0; rx_dv_o<=0; rx_er_o<=0; rx_byte_ce_o<=0; end
    else begin
      rx_byte_ce_o<=!enabled || !empty;
      if (!enabled) begin rx_data_o<=0; rx_dv_o<=0; rx_er_o<=0; end
      else if (!empty) begin rx_data_o<=head[7:0]; rx_dv_o<=head[8]; rx_er_o<=head[9]; end
    end
  end
endmodule
