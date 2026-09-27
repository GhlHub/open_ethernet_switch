`timescale 1ns/1ps
module tb_rgmii_rate_transition;
  logic clk=0,rxclk=0,rst=0,rxrun=1;
  realtime rxhalf=4.0008;
  always #4 clk=~clk;
  always begin #(rxhalf); if(rxrun) rxclk=~rxclk; else rxclk=0; end
  logic [2:0] mode=2;
  logic [3:0] rise=0,fall=0;
  logic dv=0,ctl_f=0;
  wire [7:0] data;
  wire valid,en,err,ovf,txce;
  wire [3:0] td1,td2;
  wire tc1,tc2,c1,c2;
  rgmii_rate_adapter dut(.clk(clk),.rst_n(rst),.mode_i(mode),
    .tx_data_i(8'h96),.tx_en_i(1'b0),.tx_er_i(1'b0),.tx_byte_ce_o(txce),
    .tx_rise_o(td1),.tx_fall_o(td2),.tx_ctl_rise_o(tc1),.tx_ctl_fall_o(tc2),
    .tx_clk_rise_o(c1),.tx_clk_fall_o(c2),
    .rx_clk(rxclk),.rx_rst_n(rst),.rx_rise_i(rise),.rx_fall_i(fall),
    .rx_ctl_rise_i(dv),.rx_ctl_fall_i(ctl_f),
    .rx_data_o(data),.rx_dv_o(en),.rx_er_o(err),.rx_byte_ce_o(valid),.overflow_o(ovf));
  logic pinclock=0,fall_clock=0;
  realtime high_start=0;
  always @(posedge clk)begin fall_clock<=c2;pinclock<=#1 c1;end
  always @(negedge clk)pinclock<=#1 fall_clock;
  always @(posedge pinclock)if(rst && mode[2])high_start=$realtime;
  always @(negedge pinclock)if(high_start)begin
    if($realtime-high_start!=(mode[1:0]==2?4:mode[1:0]==1?20:200))
      $fatal(1,"short or malformed TX clock pulse %f",$realtime-high_start);
    high_start=0;
  end
  byte expected[$];
  int errors[$];
  integer count=0,ends=0,bad_ends=0;
  logic check_bytes=1;
  always @(posedge clk) if(rst && valid && mode[2] && check_bytes) begin
    if(en) begin
      if(!expected.size())$fatal(1,"unexpected RX byte %h",data);
      if(data!==expected.pop_front())$fatal(1,"RX byte mismatch");
      if(err!==1'(errors.pop_front()))$fatal(1,"RX error mismatch");
      count++;
    end else begin ends++;if(err)bad_ends++;end
  end
  always @(posedge rxclk) if(ovf)$fatal(1,"RX overflow");
  task automatic word(input byte b,input bit bad=0);
    expected.push_back(b);errors.push_back(int'(bad));
    @(negedge rxclk);rise=b[3:0];fall=b[7:4];dv=1;ctl_f=!bad;
    if(mode[1:0]!=2)begin
      fall=rise;
      @(negedge rxclk);rise=b[7:4];fall=rise;ctl_f=1;
    end
  endtask
  task automatic idle();
    @(negedge rxclk);dv=0;ctl_f=0;
    repeat(20)@(negedge rxclk);
  endtask
  task automatic select_speed(input integer code);
    mode[2]=0;repeat(100)@(negedge clk);
    mode=3'(code);rxhalf=code==2?4.0008:code==1?20.004:200.04;
    repeat(100)@(negedge clk);
    mode[2]=1;rxrun=1;repeat(20)@(negedge rxclk);
  endtask
  initial begin
    repeat(8)@(negedge clk);rst=1;
    for(int pass=0;pass<6;pass++)begin
      select_speed(pass%3);
      for(int i=0;i<1536;i++)word(byte'(i*13+pass),i==47);
      idle();
      if(expected.size())$fatal(1,"RX queue incomplete");
      if(pass%3!=2)begin
        integer before_errors;
        before_errors=bad_ends;
        word(8'h12);word(8'h34);
        @(negedge rxclk);rise=4'h5;fall=4'h5;dv=1;ctl_f=1;
        idle();
        if(expected.size() || bad_ends!=before_errors+1)
          $fatal(1,"trailing odd nibble must produce an error end token");
      end
      // Stop the PHY clock in the middle of a low-speed byte, then change
      // speed while it is stopped. Stale nibble state must not join a new frame.
      check_bytes=0;
      @(negedge rxclk);rise=4'ha;fall=4'ha;dv=1;ctl_f=1;
      @(negedge rxclk);rxrun=0;dv=0;ctl_f=0;
      mode[2]=0;repeat(100)@(negedge clk);
      select_speed((pass+1)%3);check_bytes=1;
      word(8'h21);word(8'h43);idle();
      if(expected.size())$fatal(1,"restart queue incomplete");
    end
    $display("PASS: independent RX clocks, all rates, error propagation, stopped-clock speed changes: %0d bytes",count);
    $finish;
  end
  initial begin #20_000_000;$fatal(1,"timeout");end
endmodule
