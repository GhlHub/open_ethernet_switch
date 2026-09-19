// SPDX-License-Identifier: GPL-3.0-or-later
//
// Forked from GhlHub/open-ethernet-cores' open_eth_mac_1g (module
// renamed open_eth_mac_1g -> open_eth_mac_1g_switch), per GPL-3.0's
// requirement to note changes made: the ONLY functional change is that
// rx_destination_match (below) is forced permanently true instead of
// gating receive acceptance on a programmed station address/broadcast/
// multicast/promiscuous-bit match. That module was designed as a
// station endpoint NIC, which drops any frame not addressed to it; a
// switch port must instead accept every frame that arrives so the
// switch fabric's own MAC address table can make the forwarding
// decision. Everything else -- the AXI4-Lite register map (including
// the now-inert reg_uaw0/reg_uaw1/reg_fmi address-filter registers,
// left in place rather than torn out to keep this diff minimal/low-risk
// against a large, previously-unfamiliar core), broadcast/multicast
// statistics counters, framing/CRC/descriptor logic, is untouched.
//
// Second change (clock-domain-crossing cleanup, no functional change to
// the frame path): the reset inputs are no longer used directly. Each is
// treated as asynchronous and reclocked into every clock domain that uses
// it (s_axi_lite_clk, axis_clk, gtx_clk) -- see the "reset reclocking"
// block below. The original resynchronized two resets into gtx_clk from
// the same source flop, one of them through a combinational AND, which
// Vivado's CDC report flagged (CDC-11), and used the raw resets directly
// in the 150 MHz domains on the assumption that they were already
// synchronous to those clocks.
//
// Third change (also CDC): the transmit and receive data read pointers,
// which jump by a whole frame's words at once, are now published to the other
// clock domain one word per clock so the synchronized Gray code changes one
// bit at a time -- see the "data read pointers published one word per clock"
// block at the end of the module.
`timescale 1ns/1ps
// 1 Gb/s full-duplex, GMII-only replacement for the packet-MAC portion of
// Xilinx AXI Ethernet.  The AXI stream/control contract and the software-visible
// register subset are intentionally compatible with the no-checksum-offload
// configuration of AMD AXI Ethernet.
module open_eth_mac_1g_switch (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axis_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axis_clk, ASSOCIATED_BUSIF s_axis_txd:s_axis_txc:m_axis_rxd:m_axis_rxs, ASSOCIATED_RESET axi_txd_arstn:axi_txc_arstn:axi_rxd_arstn:axi_rxs_arstn, FREQ_HZ 150000000" *)
    input  wire axis_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_lite_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_lite_clk, ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_lite_resetn, FREQ_HZ 150000000" *)
    input  wire s_axi_lite_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 gtx_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME gtx_clk, ASSOCIATED_BUSIF gmii, FREQ_HZ 125000000" *)
    input  wire gtx_clk,
    input  wire clk_en,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_txd_arstn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axi_txd_arstn, POLARITY ACTIVE_LOW" *) input wire axi_txd_arstn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_txc_arstn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axi_txc_arstn, POLARITY ACTIVE_LOW" *) input wire axi_txc_arstn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_rxd_arstn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axi_rxd_arstn, POLARITY ACTIVE_LOW" *) input wire axi_rxd_arstn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_rxs_arstn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME axi_rxs_arstn, POLARITY ACTIVE_LOW" *) input wire axi_rxs_arstn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_lite_resetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_lite_resetn, POLARITY ACTIVE_LOW" *) input wire s_axi_lite_resetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txd TDATA" *) input wire [31:0] s_axis_txd_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txd TKEEP" *) input wire [3:0] s_axis_txd_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txd TLAST" *) input wire s_axis_txd_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txd TVALID" *) input wire s_axis_txd_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txd TREADY" *) output wire s_axis_txd_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txc TDATA" *) input wire [31:0] s_axis_txc_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txc TKEEP" *) input wire [3:0] s_axis_txc_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txc TLAST" *) input wire s_axis_txc_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txc TVALID" *) input wire s_axis_txc_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_txc TREADY" *) output wire s_axis_txc_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxd TDATA" *) output reg [31:0] m_axis_rxd_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxd TKEEP" *) output reg [3:0] m_axis_rxd_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxd TLAST" *) output reg m_axis_rxd_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxd TVALID" *) output reg m_axis_rxd_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxd TREADY" *) input wire m_axis_rxd_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxs TDATA" *) output reg [31:0] m_axis_rxs_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxs TKEEP" *) output wire [3:0] m_axis_rxs_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxs TLAST" *) output reg m_axis_rxs_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxs TVALID" *) output reg m_axis_rxs_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rxs TREADY" *) input wire m_axis_rxs_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *) input wire [17:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *) input wire s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *) output wire s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *) input wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *) input wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *) input wire s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *) output wire s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *) output wire [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *) output reg s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *) input wire s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *) input wire [17:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *) input wire s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *) output wire s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *) output reg [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *) output wire [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *) output reg s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *) input wire s_axi_rready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:gmii:1.0 gmii RXD" *) input wire [7:0] gmii_rxd,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gmii:1.0 gmii RX_DV" *) input wire gmii_rx_dv,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gmii:1.0 gmii RX_ER" *) input wire gmii_rx_er,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gmii:1.0 gmii TXD" *) output reg [7:0] gmii_txd,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gmii:1.0 gmii TX_EN" *) output reg gmii_tx_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gmii:1.0 gmii TX_ER" *) output reg gmii_tx_er,
    // Preserve both historical interrupt pins in the hardware handoff.  Only
    // mac_irq is used by this design; the legacy interrupt pin remains idle.
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 interrupt INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME interrupt, SENSITIVITY LEVEL_HIGH" *)
    output wire interrupt,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 mac_irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME mac_irq, SENSITIVITY EDGE_RISING" *)
    output wire mac_irq
);

localparam integer TX_BYTES = 4096;
localparam integer RX_BYTES = 16384;
localparam integer TX_WORDS = TX_BYTES / 4;
localparam integer RX_WORDS = RX_BYTES / 4;
localparam integer TX_ADDR_BITS = 10;
localparam integer RX_ADDR_BITS = 12;
localparam integer TX_DESC_DEPTH = 8;
localparam integer RX_DESC_DEPTH = 16;
localparam integer TX_DESC_BITS = 3;
localparam integer RX_DESC_BITS = 4;
localparam [31:0] CRC_RESIDUE = 32'hdebb20e3;
localparam [31:0] CORE_ID = 32'h4f4d4143; // "OMAC"

function automatic [31:0] crc32_byte(input [31:0] crc, input [7:0] data);
    integer i; reg [31:0] c;
    begin
        c = crc;
        for (i = 0; i < 8; i = i + 1) begin
            if (c[0] ^ data[i]) c = (c >> 1) ^ 32'hedb88320;
            else c = c >> 1;
        end
        crc32_byte = c;
    end
endfunction

function automatic [TX_ADDR_BITS:0] tx_gray_to_binary(
    input [TX_ADDR_BITS:0] gray);
    integer i;
    begin
        tx_gray_to_binary[TX_ADDR_BITS] = gray[TX_ADDR_BITS];
        for (i = TX_ADDR_BITS - 1; i >= 0; i = i - 1)
            tx_gray_to_binary[i] = tx_gray_to_binary[i + 1] ^ gray[i];
    end
endfunction

function automatic [RX_ADDR_BITS:0] rx_gray_to_binary(
    input [RX_ADDR_BITS:0] gray);
    integer i;
    begin
        rx_gray_to_binary[RX_ADDR_BITS] = gray[RX_ADDR_BITS];
        for (i = RX_ADDR_BITS - 1; i >= 0; i = i - 1)
            rx_gray_to_binary[i] = rx_gray_to_binary[i + 1] ^ gray[i];
    end
endfunction

function automatic [TX_DESC_BITS:0] tx_desc_gray_to_binary(
    input [TX_DESC_BITS:0] gray);
    integer i;
    begin
        tx_desc_gray_to_binary[TX_DESC_BITS] = gray[TX_DESC_BITS];
        for (i = TX_DESC_BITS - 1; i >= 0; i = i - 1)
            tx_desc_gray_to_binary[i] =
                tx_desc_gray_to_binary[i + 1] ^ gray[i];
    end
endfunction

function automatic [RX_DESC_BITS:0] rx_desc_gray_to_binary(
    input [RX_DESC_BITS:0] gray);
    integer i;
    begin
        rx_desc_gray_to_binary[RX_DESC_BITS] = gray[RX_DESC_BITS];
        for (i = RX_DESC_BITS - 1; i >= 0; i = i - 1)
            rx_desc_gray_to_binary[i] =
                rx_desc_gray_to_binary[i + 1] ^ gray[i];
    end
endfunction

`ifndef SYNTHESIS
reg [31:0] tx_mem [0:(TX_BYTES/4)-1];
`endif
(* ram_style = "block" *) reg [31:0] rx_mem [0:(RX_BYTES/4)-1];

// AXI-Lite register subset used by the no-checksum-offload AXI Ethernet path.
reg [31:0] reg_raf, reg_ie, reg_rcw0, reg_rcw1, reg_tc, reg_fcc, reg_emmc;
reg [31:0] reg_rxfc, reg_txfc, reg_uaw0, reg_uaw1, reg_fmi;
reg [31:0] irq_status;
reg aw_hold_valid, w_hold_valid;
reg [17:0] aw_hold;
reg [31:0] w_hold;
reg [3:0] wstrb_hold;
reg snapshot_request, snapshot_ack;
(* ASYNC_REG = "TRUE" *) reg [1:0] snapshot_request_sync, snapshot_ack_sync;
reg snapshot_read_pending;
reg [3:0] snapshot_select;
// ---- reset reclocking (see the header note) ----
// Every reset input is treated as asynchronous and passed through its own
// asynchronous-assert / synchronous-release two-flop synchronizer in each
// clock domain that uses it, with no logic between a source and a
// synchronizer's first flop. The signals below (lite_resetn, axis_*_resetn,
// gtx_*_resetn) are the ones used by the logic. Reset assertion is
// immediate in the 150 MHz domains and released two clocks after the input
// releases; the GMII domain is reached through registered "launch" flops in
// axis_clk (one per synchronizer), so each source flop feeds exactly one
// synchronizer flop across the crossing.
(* ASYNC_REG = "TRUE" *) reg [1:0] lite_rs   = 2'b00;
(* ASYNC_REG = "TRUE" *) reg [1:0] axis_txd_rs = 2'b00;
(* ASYNC_REG = "TRUE" *) reg [1:0] axis_txc_rs = 2'b00;
(* ASYNC_REG = "TRUE" *) reg [1:0] axis_rxd_rs = 2'b00;
(* ASYNC_REG = "TRUE" *) reg [1:0] axis_rxs_rs = 2'b00;
always @(posedge s_axi_lite_clk or negedge s_axi_lite_resetn)
    if (!s_axi_lite_resetn) lite_rs <= 2'b00; else lite_rs <= {lite_rs[0], 1'b1};
always @(posedge axis_clk or negedge axi_txd_arstn)
    if (!axi_txd_arstn) axis_txd_rs <= 2'b00; else axis_txd_rs <= {axis_txd_rs[0], 1'b1};
always @(posedge axis_clk or negedge axi_txc_arstn)
    if (!axi_txc_arstn) axis_txc_rs <= 2'b00; else axis_txc_rs <= {axis_txc_rs[0], 1'b1};
always @(posedge axis_clk or negedge axi_rxd_arstn)
    if (!axi_rxd_arstn) axis_rxd_rs <= 2'b00; else axis_rxd_rs <= {axis_rxd_rs[0], 1'b1};
always @(posedge axis_clk or negedge axi_rxs_arstn)
    if (!axi_rxs_arstn) axis_rxs_rs <= 2'b00; else axis_rxs_rs <= {axis_rxs_rs[0], 1'b1};
wire lite_resetn     = lite_rs[1];
wire axis_txd_resetn = axis_txd_rs[1];
wire axis_txc_resetn = axis_txc_rs[1];
wire axis_rxd_resetn = axis_rxd_rs[1];
wire axis_rxs_resetn = axis_rxs_rs[1];

// launch flops for the GMII-domain synchronizers (axis_clk -> gtx_clk)
reg gtx_tx_launch = 1'b0;
reg gtx_rx_launch = 1'b0;
always @(posedge axis_clk) begin
    gtx_tx_launch <= axis_txd_resetn;
    gtx_rx_launch <= axis_rxd_resetn && axis_rxs_resetn;
end

wire write_fire = aw_hold_valid && w_hold_valid && !s_axi_bvalid;
wire [31:0] write_mask = {{8{wstrb_hold[3]}}, {8{wstrb_hold[2]}},
                          {8{wstrb_hold[1]}}, {8{wstrb_hold[0]}}};
wire [31:0] write_merged_raf = (reg_raf & ~write_mask) | (w_hold & write_mask);
assign s_axi_awready = lite_resetn && !aw_hold_valid && !s_axi_bvalid;
assign s_axi_wready = lite_resetn && !w_hold_valid && !s_axi_bvalid;
assign s_axi_bresp = 2'b00;
assign s_axi_arready = lite_resetn && !s_axi_rvalid &&
                       !snapshot_read_pending && !snapshot_ack_sync[1];
assign s_axi_rresp = 2'b00;
assign interrupt = 1'b0;
assign mac_irq = |(irq_status & reg_ie);

// Event counters live in the GMII domain. AXI-Lite requests an atomic bundled
// snapshot when software reads a GMII-domain statistic. The source holds the
// snapshot stable until the request is released after the read response.
reg [31:0] rx_byte_count, tx_byte_count, rx_frame_count, rx_fcs_error_count;
reg [31:0] rx_broadcast_count, rx_multicast_count, tx_frame_count;
reg [31:0] rx_filter_drop_count, rx_overflow_count;
reg [31:0] tx_oversize_count_axis;
reg [31:0] snapshot_value;

function automatic is_snapshot_counter_address(input [17:0] addr);
    begin
        case (addr)
          18'h00200, 18'h00208, 18'h00250, 18'h00290, 18'h00298,
          18'h002a0, 18'h002a8, 18'h002d8, 18'h3ff00, 18'h3ff04:
            is_snapshot_counter_address = 1'b1;
          default: is_snapshot_counter_address = 1'b0;
        endcase
    end
endfunction

function automatic [3:0] snapshot_counter_select(input [17:0] addr);
    begin
        case (addr)
          18'h00200: snapshot_counter_select = 0;
          18'h00208: snapshot_counter_select = 1;
          18'h00250, 18'h3ff04: snapshot_counter_select = 2;
          18'h00290: snapshot_counter_select = 3;
          18'h00298: snapshot_counter_select = 4;
          18'h002a0: snapshot_counter_select = 5;
          18'h002a8: snapshot_counter_select = 6;
          18'h002d8: snapshot_counter_select = 7;
          18'h3ff00: snapshot_counter_select = 8;
          default: snapshot_counter_select = 0;
        endcase
    end
endfunction

task automatic write_reg(input [17:0] addr, input [31:0] value, input [31:0] mask);
    begin
        case (addr)
          18'h00000: reg_raf  <= (reg_raf  & ~mask) | (value & mask);
          18'h0000c: irq_status <= irq_status & ~(value & mask);
          18'h00014: reg_ie   <= (reg_ie   & ~mask) | (value & mask);
          18'h00400: reg_rcw0 <= (reg_rcw0 & ~mask) | (value & mask);
          18'h00404: reg_rcw1 <= (reg_rcw1 & ~mask) | (value & mask);
          18'h00408: reg_tc   <= (reg_tc   & ~mask) | (value & mask);
          18'h0040c: reg_fcc  <= (reg_fcc  & ~mask) | (value & mask);
          18'h00410: reg_emmc <= (reg_emmc & ~mask) | (value & mask);
          18'h00414: reg_rxfc <= (reg_rxfc & ~mask) | (value & mask);
          18'h00418: reg_txfc <= (reg_txfc & ~mask) | (value & mask);
          18'h00700: reg_uaw0 <= (reg_uaw0 & ~mask) | (value & mask);
          18'h00704: reg_uaw1 <= (reg_uaw1 & ~mask) | (value & mask);
          18'h00708: reg_fmi  <= (reg_fmi  & ~mask) | (value & mask);
          default: ;
        endcase
    end
endtask

always @(posedge s_axi_lite_clk) begin
    if (!lite_resetn) begin
        reg_raf <= 0; reg_ie <= 0; reg_rcw0 <= 0; reg_rcw1 <= 32'h02000000;
        reg_tc <= 0; reg_fcc <= 0; reg_emmc <= 32'h80000000;
        reg_rxfc <= 32'd16384; reg_txfc <= 32'd4096;
        reg_uaw0 <= 0; reg_uaw1 <= 0; reg_fmi <= 0; irq_status <= 32'hc0;
        aw_hold_valid <= 0; w_hold_valid <= 0; s_axi_bvalid <= 0;
        s_axi_rvalid <= 0; s_axi_rdata <= 0;
        snapshot_request <= 0; snapshot_ack_sync <= 0;
        snapshot_read_pending <= 0; snapshot_select <= 0;
    end else begin
        snapshot_ack_sync <= {snapshot_ack_sync[0], snapshot_ack};
        if (s_axi_awready && s_axi_awvalid) begin aw_hold <= s_axi_awaddr; aw_hold_valid <= 1; end
        if (s_axi_wready && s_axi_wvalid) begin w_hold <= s_axi_wdata; wstrb_hold <= s_axi_wstrb; w_hold_valid <= 1; end
        if (write_fire) begin
            write_reg(aw_hold, w_hold, write_mask);
            aw_hold_valid <= 0; w_hold_valid <= 0; s_axi_bvalid <= 1;
            if (aw_hold == 18'h00000 && write_merged_raf[13]) begin
                // Counter reset is self-clearing, matching AXI Ethernet.
                reg_raf[13] <= 0;
            end
        end
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
        if (s_axi_arready && s_axi_arvalid) begin
            if (is_snapshot_counter_address(s_axi_araddr)) begin
                snapshot_request <= 1;
                snapshot_read_pending <= 1;
                snapshot_select <= snapshot_counter_select(s_axi_araddr);
            end else begin
              s_axi_rvalid <= 1;
              case (s_axi_araddr)
              18'h00000: s_axi_rdata <= reg_raf;
              18'h0000c: s_axi_rdata <= irq_status | 32'hc0;
              18'h00010: s_axi_rdata <= irq_status & reg_ie;
              18'h00014: s_axi_rdata <= reg_ie;
              18'h00288: s_axi_rdata <= tx_oversize_count_axis;
              18'h00400: s_axi_rdata <= reg_rcw0;
              18'h00404: s_axi_rdata <= reg_rcw1;
              18'h00408: s_axi_rdata <= reg_tc;
              18'h0040c: s_axi_rdata <= reg_fcc;
              18'h00410: s_axi_rdata <= reg_emmc;
              18'h00414: s_axi_rdata <= reg_rxfc;
              18'h00418: s_axi_rdata <= reg_txfc;
              18'h004f8: s_axi_rdata <= CORE_ID;
              18'h004fc: s_axi_rdata <= 32'h00000001;
              18'h00500: s_axi_rdata <= 32'h00000040; // MDIO ready, divisor 0
              18'h00700: s_axi_rdata <= reg_uaw0;
              18'h00704: s_axi_rdata <= reg_uaw1;
              18'h00708: s_axi_rdata <= reg_fmi;
              18'h3ff08: s_axi_rdata <= tx_oversize_count_axis;
              default: s_axi_rdata <= 0;
              endcase
            end
        end
        if (snapshot_read_pending && snapshot_ack_sync[1]) begin
            s_axi_rdata <= snapshot_value;
            s_axi_rvalid <= 1;
            snapshot_read_pending <= 0;
            snapshot_request <= 0;
        end
        if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
    end
end

// TX AXI stream: packet data and descriptors are independent circular queues.
// A descriptor becomes visible to GMII only after TLAST commits the complete
// frame. The uncommitted write pointer can stall behind older queued frames;
// GMII continues reclaiming those frames while AXI is backpressured.
reg tx_control_ready, tx_drop;
reg [2:0] txc_words;
reg [12:0] tx_wr_count;
reg [TX_ADDR_BITS:0] tx_data_wr_bin, tx_data_work_bin;
reg [TX_ADDR_BITS:0] tx_data_rd_bin;
reg [TX_ADDR_BITS:0] tx_data_rd_gray;
(* ASYNC_REG = "TRUE" *) reg [TX_ADDR_BITS:0] tx_data_rd_gray_sync1;
(* ASYNC_REG = "TRUE" *) reg [TX_ADDR_BITS:0] tx_data_rd_gray_sync2;
reg [TX_DESC_BITS:0] tx_desc_wr_bin, tx_desc_wr_gray;
reg [TX_DESC_BITS:0] tx_desc_rd_bin, tx_desc_rd_gray;
(* ASYNC_REG = "TRUE" *) reg [TX_DESC_BITS:0] tx_desc_rd_gray_sync1;
(* ASYNC_REG = "TRUE" *) reg [TX_DESC_BITS:0] tx_desc_rd_gray_sync2;
(* ASYNC_REG = "TRUE" *) reg [TX_DESC_BITS:0] tx_desc_wr_gray_sync1;
(* ASYNC_REG = "TRUE" *) reg [TX_DESC_BITS:0] tx_desc_wr_gray_sync2;
reg [TX_ADDR_BITS-1:0] tx_desc_start [0:TX_DESC_DEPTH-1];
reg [12:0] tx_desc_length [0:TX_DESC_DEPTH-1];
reg [TX_ADDR_BITS:0] tx_desc_words [0:TX_DESC_DEPTH-1];
reg [TX_ADDR_BITS:0] tx_frame_words;
wire [2:0] tx_valid_bytes = s_axis_txd_tkeep[0] + s_axis_txd_tkeep[1] +
                             s_axis_txd_tkeep[2] + s_axis_txd_tkeep[3];
wire [TX_ADDR_BITS:0] tx_data_rd_bin_axis =
    tx_gray_to_binary(tx_data_rd_gray_sync2);
wire [TX_ADDR_BITS:0] tx_data_used_words =
    tx_data_work_bin - tx_data_rd_bin_axis;
wire tx_data_has_space = tx_data_used_words < TX_WORDS;
wire [TX_DESC_BITS:0] tx_desc_rd_bin_axis =
    tx_desc_gray_to_binary(tx_desc_rd_gray_sync2);
wire tx_desc_full = (tx_desc_wr_bin - tx_desc_rd_bin_axis) == TX_DESC_DEPTH;
assign s_axis_txc_tready = axis_txc_resetn && !tx_control_ready && !tx_desc_full;
assign s_axis_txd_tready = axis_txd_resetn && tx_control_ready &&
    (tx_drop || tx_data_has_space || tx_frame_words >= TX_WORDS);
wire tx_data_handshake = s_axis_txd_tvalid && s_axis_txd_tready;
wire tx_store_beat = tx_data_handshake && !tx_drop && tx_data_has_space &&
                     tx_valid_bytes != 0;
wire tx_mem_write = tx_store_beat;

always @(posedge axis_clk) begin
    tx_data_rd_gray_sync1 <= tx_data_rd_gray;
    tx_data_rd_gray_sync2 <= tx_data_rd_gray_sync1;
    tx_desc_rd_gray_sync1 <= tx_desc_rd_gray;
    tx_desc_rd_gray_sync2 <= tx_desc_rd_gray_sync1;
    if (!axis_txd_resetn || !axis_txc_resetn) begin
        tx_control_ready <= 0; tx_drop <= 0;
        txc_words <= 0; tx_wr_count <= 0; tx_frame_words <= 0;
        tx_data_wr_bin <= 0; tx_data_work_bin <= 0;
        tx_data_rd_gray_sync1 <= 0; tx_data_rd_gray_sync2 <= 0;
        tx_desc_wr_bin <= 0; tx_desc_wr_gray <= 0;
        tx_desc_rd_gray_sync1 <= 0; tx_desc_rd_gray_sync2 <= 0;
        tx_oversize_count_axis <= 0;
    end else begin
        if (s_axis_txc_tvalid && s_axis_txc_tready) begin
            if (s_axis_txc_tlast || txc_words == 5) begin
                tx_control_ready <= 1; txc_words <= 0; tx_wr_count <= 0;
                tx_frame_words <= 0; tx_data_work_bin <= tx_data_wr_bin;
                tx_drop <= 0;
            end else txc_words <= txc_words + 1'b1;
        end
        if (tx_data_handshake) begin
            if (tx_store_beat) begin
`ifndef SYNTHESIS
                tx_mem[tx_data_work_bin[TX_ADDR_BITS-1:0]] <=
                    s_axis_txd_tdata;
`endif
                tx_data_work_bin <= tx_data_work_bin + 1'b1;
                tx_frame_words <= tx_frame_words + 1'b1;
            end else if (!tx_drop) begin
                tx_drop <= 1;
            end
            if (tx_wr_count <= TX_BYTES)
                tx_wr_count <= tx_wr_count + tx_valid_bytes;
            if (s_axis_txd_tlast) begin
                tx_control_ready <= 0;
                if (!tx_drop && tx_store_beat &&
                    tx_wr_count + tx_valid_bytes <= TX_BYTES) begin
                    tx_desc_start[tx_desc_wr_bin[TX_DESC_BITS-1:0]] <=
                        tx_data_wr_bin[TX_ADDR_BITS-1:0];
                    tx_desc_length[tx_desc_wr_bin[TX_DESC_BITS-1:0]] <=
                        tx_wr_count + tx_valid_bytes;
                    // AXI DMA can place a partial TKEEP beat at an interior
                    // scatter-gather descriptor boundary. The number of
                    // occupied packet-buffer words can therefore exceed
                    // ceil(frame byte length / 4). Preserve the exact count
                    // so the GMII side releases every accepted storage word.
                    tx_desc_words[tx_desc_wr_bin[TX_DESC_BITS-1:0]] <=
                        tx_frame_words + 1'b1;
                    tx_data_wr_bin <= tx_data_work_bin + 1'b1;
                    tx_desc_wr_bin <= tx_desc_wr_bin + 1'b1;
                    tx_desc_wr_gray <= ((tx_desc_wr_bin + 1'b1) >> 1) ^
                                       (tx_desc_wr_bin + 1'b1);
                end else begin
                    tx_data_work_bin <= tx_data_wr_bin;
                    tx_oversize_count_axis <= tx_oversize_count_axis + 1'b1;
                end
            end
        end
    end
end

// TX GMII state machine, including preamble/SFD, minimum-frame padding, FCS,
// and the mandatory 12-byte interpacket gap.
localparam [3:0] TX_IDLE=0, TX_PREAMBLE=1, TX_DATA=2, TX_PAD=3,
                 TX_FCS0=4, TX_FCS1=5, TX_FCS2=6, TX_FCS3=7, TX_IFG=8,
                 TX_DISCARD=9, TX_LAUNCH=10;
reg [3:0] tx_state;
reg [3:0] tx_phase;
reg [9:0] tx_rd_addr;
reg [TX_ADDR_BITS-1:0] tx_start_gmii;
reg [1:0] tx_rd_lane;
reg [12:0] tx_length_gmii, tx_data_sent;
reg [TX_ADDR_BITS:0] tx_words_gmii;
wire [31:0] tx_mem_q;
wire [7:0] tx_mem_byte = tx_mem_q[tx_rd_lane*8 +: 8];
reg [31:0] tx_crc, tx_fcs;
(* ASYNC_REG = "TRUE" *) reg [1:0] tx_enable_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] gtx_tx_reset_sync = 2'b00;
(* ASYNC_REG = "TRUE" *) reg [1:0] gtx_rx_reset_sync = 2'b00;
wire gtx_tx_resetn = gtx_tx_reset_sync[1];
wire gtx_rx_resetn = gtx_rx_reset_sync[1];

// The AXI resets are reclocked above (reset reclocking block); this last
// stage brings each one into the independent 125 MHz GMII domain from its
// own launch flop. Without it every GMII register becomes an invalid timed
// CDC path.
always @(posedge gtx_clk) begin
    gtx_tx_reset_sync <= {gtx_tx_reset_sync[0], gtx_tx_launch};
    gtx_rx_reset_sync <= {gtx_rx_reset_sync[0], gtx_rx_launch};
end

always @(posedge gtx_clk) begin
    snapshot_request_sync <= {snapshot_request_sync[0], snapshot_request};
    if (!gtx_tx_resetn || !gtx_rx_resetn) begin
        snapshot_request_sync <= 0; snapshot_ack <= 0;
        snapshot_value <= 0;
    end else if (snapshot_request_sync[1] && !snapshot_ack) begin
        case (snapshot_select)
          0: snapshot_value <= rx_byte_count;
          1: snapshot_value <= tx_byte_count;
          2: snapshot_value <= rx_overflow_count;
          3: snapshot_value <= rx_frame_count;
          4: snapshot_value <= rx_fcs_error_count;
          5: snapshot_value <= rx_broadcast_count;
          6: snapshot_value <= rx_multicast_count;
          7: snapshot_value <= tx_frame_count;
          8: snapshot_value <= rx_filter_drop_count;
          default: snapshot_value <= 0;
        endcase
        snapshot_ack <= 1;
    end else if (!snapshot_request_sync[1]) begin
        snapshot_ack <= 0;
    end
end

always @(posedge gtx_clk) begin
    tx_desc_wr_gray_sync1 <= tx_desc_wr_gray;
    tx_desc_wr_gray_sync2 <= tx_desc_wr_gray_sync1;
    tx_enable_sync <= {tx_enable_sync[0], reg_tc[28]};
    if (!gtx_tx_resetn) begin
        tx_state <= TX_IDLE; gmii_txd <= 0; gmii_tx_en <= 0; gmii_tx_er <= 0;
        tx_phase <= 0; tx_rd_addr <= 0; tx_start_gmii <= 0;
        tx_rd_lane <= 0; tx_data_sent <= 0; tx_words_gmii <= 0;
        tx_crc <= 32'hffffffff;
        tx_desc_wr_gray_sync1 <= 0; tx_desc_wr_gray_sync2 <= 0;
        tx_desc_rd_bin <= 0; tx_desc_rd_gray <= 0;
        tx_data_rd_bin <= 0; tx_enable_sync <= 0;
        tx_byte_count <= 0; tx_frame_count <= 0;
    end else if (clk_en) begin
        gmii_tx_er <= 0;
        case (tx_state)
          TX_IDLE: begin
              gmii_tx_en <= 0; gmii_txd <= 0; tx_rd_addr <= 0; tx_rd_lane <= 0;
              if (tx_desc_rd_gray != tx_desc_wr_gray_sync2) begin
                  tx_start_gmii <= tx_desc_start[
                      tx_desc_rd_bin[TX_DESC_BITS-1:0]];
                  tx_length_gmii <= tx_desc_length[
                      tx_desc_rd_bin[TX_DESC_BITS-1:0]];
                  tx_words_gmii <= tx_desc_words[
                      tx_desc_rd_bin[TX_DESC_BITS-1:0]];
                  tx_state <= TX_LAUNCH;
              end
          end
          TX_LAUNCH: begin
              tx_rd_addr <= tx_start_gmii;
              if (tx_enable_sync[1]) begin
                  tx_phase <= 0; tx_data_sent <= 0;
                  tx_crc <= 32'hffffffff; tx_state <= TX_PREAMBLE;
              end else tx_state <= TX_DISCARD;
          end
          TX_DISCARD: begin
              tx_data_rd_bin <= tx_data_rd_bin + tx_words_gmii;
              tx_desc_rd_bin <= tx_desc_rd_bin + 1'b1;
              tx_desc_rd_gray <= ((tx_desc_rd_bin + 1'b1) >> 1) ^
                                 (tx_desc_rd_bin + 1'b1);
              tx_state <= TX_IDLE;
          end
          TX_PREAMBLE: begin
              gmii_tx_en <= 1; gmii_txd <= (tx_phase == 7) ? 8'hd5 : 8'h55;
              if (tx_phase == 7) begin tx_phase <= 0; tx_state <= TX_DATA; end
              else tx_phase <= tx_phase + 1'b1;
          end
          TX_DATA: begin
              gmii_tx_en <= 1; gmii_txd <= tx_mem_byte;
              tx_crc <= crc32_byte(tx_crc, tx_mem_byte); tx_byte_count <= tx_byte_count + 1'b1;
              tx_data_sent <= tx_data_sent + 1'b1;
              if (tx_data_sent + 1 >= tx_length_gmii) begin
                  if (tx_length_gmii < 60) tx_state <= TX_PAD;
                  else begin tx_fcs <= ~crc32_byte(tx_crc, tx_mem_byte); tx_state <= TX_FCS0; end
              end else if (tx_rd_lane == 3) begin
                  tx_rd_lane <= 0;
              end else begin
                  // Advance the synchronous RAM address one byte early. At
                  // lane 3 the old word is still in tx_mem_q while the next
                  // word is captured for lane 0 of the following cycle.
                  if (tx_rd_lane == 2) tx_rd_addr <= tx_rd_addr + 1'b1;
                  tx_rd_lane <= tx_rd_lane + 1'b1;
              end
          end
          TX_PAD: begin
              gmii_tx_en <= 1; gmii_txd <= 0; tx_crc <= crc32_byte(tx_crc, 8'h00);
              tx_byte_count <= tx_byte_count + 1'b1; tx_data_sent <= tx_data_sent + 1'b1;
              if (tx_data_sent + 1 >= 60) begin
                  tx_fcs <= ~crc32_byte(tx_crc, 8'h00); tx_state <= TX_FCS0;
              end
          end
          TX_FCS0: begin gmii_tx_en <= 1; gmii_txd <= tx_fcs[7:0]; tx_state <= TX_FCS1; end
          TX_FCS1: begin gmii_txd <= tx_fcs[15:8]; tx_state <= TX_FCS2; end
          TX_FCS2: begin gmii_txd <= tx_fcs[23:16]; tx_state <= TX_FCS3; end
          TX_FCS3: begin
              gmii_txd <= tx_fcs[31:24]; tx_state <= TX_IFG; tx_phase <= 0;
              tx_frame_count <= tx_frame_count + 1'b1;
              tx_data_rd_bin <= tx_data_rd_bin + tx_words_gmii;
              tx_desc_rd_bin <= tx_desc_rd_bin + 1'b1;
              tx_desc_rd_gray <= ((tx_desc_rd_bin + 1'b1) >> 1) ^
                                 (tx_desc_rd_bin + 1'b1);
          end
          TX_IFG: begin
              gmii_tx_en <= 0; gmii_txd <= 0;
              if (tx_phase == 11) tx_state <= TX_IDLE;
              else tx_phase <= tx_phase + 1'b1;
          end
          default: tx_state <= TX_IDLE;
        endcase
    end
end

`ifdef SYNTHESIS
// An explicit XPM prevents late synthesis translation from expanding this
// independent-clock packet buffer into registers and a large read mux.
xpm_memory_sdpram #(
    .ADDR_WIDTH_A(10), .ADDR_WIDTH_B(10), .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("independent_clock"),
    .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(32768),
    .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"), .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(32), .WRITE_MODE_B("no_change")) tx_packet_buffer (
    .clka(axis_clk), .ena(1'b1), .wea(tx_mem_write),
    .addra(tx_data_work_bin[TX_ADDR_BITS-1:0]), .dina(s_axis_txd_tdata),
    .injectdbiterra(1'b0), .injectsbiterra(1'b0),
    .clkb(gtx_clk), .enb(1'b1), .addrb(tx_rd_addr), .doutb(tx_mem_q),
    .regceb(1'b1), .rstb(!gtx_tx_resetn), .sleep(1'b0),
    .dbiterrb(), .sbiterrb());
`else
reg [31:0] tx_mem_q_sim;
assign tx_mem_q = tx_mem_q_sim;
always @(posedge gtx_clk) tx_mem_q_sim <= tx_mem[tx_rd_addr];
`endif

// RX GMII: locate SFD and store complete frames in a circular 16 KiB data
// queue. A descriptor is committed only after destination, length, GMII error,
// and FCS checks pass. The AXI side can drain an older descriptor while GMII
// receives following frames. The 1518-byte DMA limit includes room for a
// VLAN-tagged frame after the four-byte FCS has been stripped.
localparam [1:0] RX_SEARCH=0, RX_FRAME=1, RX_WAIT=2;
localparam integer RX_MIN_WIRE_BYTES = 64;
localparam integer RX_MAX_DMA_BYTES = 1518;
localparam integer RX_MAX_WIRE_WORDS = (RX_MAX_DMA_BYTES + 7) / 4;
reg [1:0] rx_state;
reg [2:0] rx_preamble_count;
reg [14:0] rx_wire_count;
reg [1:0] rx_byte_lane;
reg [31:0] rx_word_accum;
reg [47:0] rx_destination;
reg rx_accepted, rx_error_seen, rx_is_broadcast, rx_is_multicast;
reg [31:0] rx_crc;
reg rx_store_frame;
reg [RX_ADDR_BITS-1:0] rx_frame_start_word;
reg [RX_ADDR_BITS:0] rx_data_wr_bin, rx_data_rd_bin;
reg [RX_ADDR_BITS:0] rx_data_rd_gray;
(* ASYNC_REG = "TRUE" *) reg [RX_ADDR_BITS:0] rx_data_rd_gray_sync1;
(* ASYNC_REG = "TRUE" *) reg [RX_ADDR_BITS:0] rx_data_rd_gray_sync2;
reg [RX_DESC_BITS:0] rx_desc_wr_bin, rx_desc_wr_gray;
reg [RX_DESC_BITS:0] rx_desc_rd_bin, rx_desc_rd_gray;
(* ASYNC_REG = "TRUE" *) reg [RX_DESC_BITS:0] rx_desc_rd_gray_sync1;
(* ASYNC_REG = "TRUE" *) reg [RX_DESC_BITS:0] rx_desc_rd_gray_sync2;
(* ASYNC_REG = "TRUE" *) reg [RX_DESC_BITS:0] rx_desc_wr_gray_sync1;
(* ASYNC_REG = "TRUE" *) reg [RX_DESC_BITS:0] rx_desc_wr_gray_sync2;
reg [RX_ADDR_BITS-1:0] rx_desc_start [0:RX_DESC_DEPTH-1];
reg [14:0] rx_desc_length [0:RX_DESC_DEPTH-1];
reg [RX_ADDR_BITS:0] rx_desc_words [0:RX_DESC_DEPTH-1];
reg [31:0] rx_desc_status3 [0:RX_DESC_DEPTH-1];
reg [47:0] rx_desc_destination [0:RX_DESC_DEPTH-1];
reg rx_desc_multicast [0:RX_DESC_DEPTH-1];
(* ASYNC_REG = "TRUE" *) reg [1:0] rx_enable_sync;
(* ASYNC_REG = "TRUE" *) reg [47:0] station_mac_meta, station_mac_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] rx_promiscuous_sync;
// Switch fork: always accept. The original station/broadcast/multicast/
// promiscuous-bit match (still computed below into rx_is_broadcast/
// rx_is_multicast for statistics, and station_mac_sync/rx_promiscuous_sync
// remain live off the now-inert reg_uaw0/reg_uaw1/reg_fmi registers) is
// no longer used to gate acceptance -- a switch port must receive every
// frame regardless of destination address so the switch's own MAC table
// can decide where it forwards, not the port's NIC-style address filter.
wire rx_destination_match = 1'b1;
wire [13:0] rx_frame_length14 = (rx_wire_count >= 4) ?
    rx_wire_count[13:0] - 14'd4 : 14'd0;
wire [31:0] rx_word_with_byte =
    (rx_word_accum & ~(32'hff << (rx_byte_lane*8))) |
    ({24'd0, gmii_rxd} << (rx_byte_lane*8));
wire [RX_DESC_BITS:0] rx_desc_rd_bin_gmii =
    rx_desc_gray_to_binary(rx_desc_rd_gray_sync2);
wire rx_desc_full =
    (rx_desc_wr_bin - rx_desc_rd_bin_gmii) == RX_DESC_DEPTH;
wire [RX_ADDR_BITS:0] rx_data_rd_bin_gmii =
    rx_gray_to_binary(rx_data_rd_gray_sync2);
wire [RX_ADDR_BITS:0] rx_data_used_words =
    rx_data_wr_bin - rx_data_rd_bin_gmii;
wire [RX_ADDR_BITS:0] rx_data_free_words = RX_WORDS - rx_data_used_words;
wire rx_queue_has_room = !rx_desc_full &&
                         rx_data_free_words >= RX_MAX_WIRE_WORDS;

always @(posedge gtx_clk) begin
    rx_desc_rd_gray_sync1 <= rx_desc_rd_gray;
    rx_desc_rd_gray_sync2 <= rx_desc_rd_gray_sync1;
    rx_data_rd_gray_sync1 <= rx_data_rd_gray;
    rx_data_rd_gray_sync2 <= rx_data_rd_gray_sync1;
    rx_enable_sync <= {rx_enable_sync[0], reg_rcw1[28]};
    station_mac_meta <= {reg_uaw1[15:0], reg_uaw0};
    station_mac_sync <= station_mac_meta;
    rx_promiscuous_sync <= {rx_promiscuous_sync[0], reg_fmi[31]};
    if (!gtx_rx_resetn) begin
        rx_state <= RX_SEARCH; rx_preamble_count <= 0; rx_wire_count <= 0;
        rx_byte_lane <= 0; rx_word_accum <= 0; rx_destination <= 0;
        rx_accepted <= 0; rx_error_seen <= 0; rx_crc <= 32'hffffffff;
        rx_store_frame <= 0; rx_frame_start_word <= 0;
        rx_data_wr_bin <= 0; rx_data_rd_gray_sync1 <= 0;
        rx_data_rd_gray_sync2 <= 0;
        rx_desc_wr_bin <= 0; rx_desc_wr_gray <= 0;
        rx_desc_rd_gray_sync1 <= 0; rx_desc_rd_gray_sync2 <= 0;
        rx_enable_sync <= 0; rx_byte_count <= 0; rx_frame_count <= 0;
        station_mac_meta <= 0; station_mac_sync <= 0;
        rx_promiscuous_sync <= 0;
        rx_fcs_error_count <= 0; rx_broadcast_count <= 0; rx_multicast_count <= 0;
        rx_filter_drop_count <= 0; rx_overflow_count <= 0;
    end else if (clk_en) begin
        case (rx_state)
          RX_SEARCH: begin
              rx_preamble_count <= 0;
              if (gmii_rx_dv && gmii_rxd == 8'h55) begin rx_preamble_count <= 1; rx_state <= RX_WAIT; end
          end
          RX_WAIT: begin
              if (!gmii_rx_dv) rx_state <= RX_SEARCH;
              else if (gmii_rxd == 8'h55 && rx_preamble_count < 7)
                  rx_preamble_count <= rx_preamble_count + 1'b1;
              else if (gmii_rxd == 8'hd5 && rx_preamble_count >= 1 &&
                       rx_enable_sync[1]) begin
                  rx_state <= RX_FRAME; rx_wire_count <= 0; rx_byte_lane <= 0;
                  rx_word_accum <= 0; rx_destination <= 0; rx_accepted <= 0;
                  rx_error_seen <= 0; rx_crc <= 32'hffffffff;
                  rx_store_frame <= rx_queue_has_room;
                  rx_frame_start_word <= rx_data_wr_bin[RX_ADDR_BITS-1:0];
              end else if (gmii_rxd != 8'h55) rx_state <= RX_SEARCH;
          end
          RX_FRAME: begin
              if (gmii_rx_dv) begin
                  rx_error_seen <= rx_error_seen | gmii_rx_er;
                  rx_crc <= crc32_byte(rx_crc, gmii_rxd);
                  if (rx_store_frame &&
                      rx_wire_count < RX_MAX_DMA_BYTES + 4) begin
                      rx_word_accum <= rx_word_with_byte;
                      if (rx_byte_lane == 3) begin
                          rx_mem[rx_frame_start_word +
                                 rx_wire_count[RX_ADDR_BITS+1:2]] <=
                              rx_word_with_byte;
                          rx_byte_lane <= 0; rx_word_accum <= 0;
                      end else rx_byte_lane <= rx_byte_lane + 1'b1;
                  end
                  if (rx_wire_count < 6)
                      rx_destination <= {gmii_rxd, rx_destination[47:8]};
                  if (rx_wire_count == 5) begin
                      rx_is_broadcast <= ({gmii_rxd, rx_destination[47:8]} == 48'hffffffffffff);
                      rx_is_multicast <= rx_destination[8] &&
                          ({gmii_rxd, rx_destination[47:8]} != 48'hffffffffffff);
                      if (rx_destination_match) rx_accepted <= 1;
                  end
                  rx_wire_count <= rx_wire_count + 1'b1;
              end else begin
                  rx_state <= RX_SEARCH;
                  if (rx_accepted && !rx_error_seen &&
                      rx_crc == CRC_RESIDUE &&
                      rx_wire_count >= RX_MIN_WIRE_BYTES &&
                      rx_wire_count <= RX_MAX_DMA_BYTES + 4) begin
                      if (rx_store_frame) begin
                          rx_desc_start[rx_desc_wr_bin[RX_DESC_BITS-1:0]] <=
                              rx_frame_start_word;
                          rx_desc_length[rx_desc_wr_bin[RX_DESC_BITS-1:0]] <=
                              rx_wire_count - 4;
                          rx_desc_words[rx_desc_wr_bin[RX_DESC_BITS-1:0]] <=
                              (rx_wire_count + 3) >> 2;
                          rx_desc_status3[rx_desc_wr_bin[RX_DESC_BITS-1:0]] <= {
                              1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
                              1'b0, 1'b0,
                              rx_frame_length14,
                              rx_is_multicast, rx_is_broadcast,
                              1'b0, 1'b0, 1'b1, 6'b0};
                          rx_desc_destination[rx_desc_wr_bin[RX_DESC_BITS-1:0]] <=
                              rx_destination;
                          rx_desc_multicast[rx_desc_wr_bin[RX_DESC_BITS-1:0]] <=
                              rx_is_multicast;
                          rx_data_wr_bin <= rx_data_wr_bin +
                              ((rx_wire_count + 3) >> 2);
                          rx_desc_wr_bin <= rx_desc_wr_bin + 1'b1;
                          rx_desc_wr_gray <= ((rx_desc_wr_bin + 1'b1) >> 1) ^
                                             (rx_desc_wr_bin + 1'b1);
                          rx_byte_count <= rx_byte_count + rx_wire_count - 4;
                          rx_frame_count <= rx_frame_count + 1'b1;
                          if (rx_is_broadcast)
                              rx_broadcast_count <= rx_broadcast_count + 1'b1;
                          if (rx_is_multicast)
                              rx_multicast_count <= rx_multicast_count + 1'b1;
                      end else begin
                          rx_overflow_count <= rx_overflow_count + 1'b1;
                      end
                  end else if (!rx_accepted) begin
                      rx_filter_drop_count <= rx_filter_drop_count + 1'b1;
                  end else if (rx_error_seen || rx_crc != CRC_RESIDUE ||
                               rx_wire_count < RX_MIN_WIRE_BYTES) begin
                      rx_fcs_error_count <= rx_fcs_error_count + 1'b1;
                  end else begin
                      rx_overflow_count <= rx_overflow_count + 1'b1;
                  end
              end
          end
          default: rx_state <= RX_SEARCH;
        endcase
    end
end

// RX AXI-stream readout starts only after the complete frame passed every
// receive check in the GMII domain. Data and status may drain independently;
// the circular data allocation is reclaimed after both streams finish.
reg rx_axis_active, rx_status_active;
reg rx_data_complete, rx_status_complete;
reg [14:0] rx_length_axis;
reg [31:0] rx_status3_axis;
reg [47:0] rx_destination_axis;
reg rx_multicast_axis;
reg [RX_ADDR_BITS-1:0] rx_start_axis;
reg [RX_ADDR_BITS:0] rx_words_axis;
reg [12:0] rx_word_index;
reg [2:0] rx_status_index;
wire [12:0] rx_available_words = (rx_length_axis + 3) >> 2;
wire [12:0] rx_last_word = (rx_length_axis == 0) ? 0 : ((rx_length_axis - 1) >> 2);
assign m_axis_rxs_tkeep = 4'hf;

always @(posedge axis_clk) begin
    rx_desc_wr_gray_sync1 <= rx_desc_wr_gray;
    rx_desc_wr_gray_sync2 <= rx_desc_wr_gray_sync1;
    if (!axis_rxd_resetn || !axis_rxs_resetn) begin
        rx_desc_wr_gray_sync1 <= 0; rx_desc_wr_gray_sync2 <= 0;
        rx_desc_rd_bin <= 0; rx_desc_rd_gray <= 0;
        rx_data_rd_bin <= 0;
        rx_axis_active <= 0; rx_status_active <= 0;
        rx_data_complete <= 0; rx_status_complete <= 0;
        rx_word_index <= 0; rx_status_index <= 0; m_axis_rxd_tvalid <= 0;
        m_axis_rxd_tlast <= 0; m_axis_rxd_tdata <= 0; m_axis_rxd_tkeep <= 0;
        m_axis_rxs_tvalid <= 0; m_axis_rxs_tlast <= 0; m_axis_rxs_tdata <= 0;
        rx_length_axis <= 0; rx_status3_axis <= 0; rx_destination_axis <= 0;
        rx_multicast_axis <= 0; rx_start_axis <= 0; rx_words_axis <= 0;
    end else begin
        if (!rx_axis_active && !rx_status_active &&
            !rx_data_complete && !rx_status_complete &&
            rx_desc_rd_gray != rx_desc_wr_gray_sync2) begin
            rx_axis_active <= 1;
            rx_status_active <= 1; rx_word_index <= 0; rx_status_index <= 0;
            rx_length_axis <= rx_desc_length[
                rx_desc_rd_bin[RX_DESC_BITS-1:0]];
            rx_status3_axis <= rx_desc_status3[
                rx_desc_rd_bin[RX_DESC_BITS-1:0]];
            rx_destination_axis <= rx_desc_destination[
                rx_desc_rd_bin[RX_DESC_BITS-1:0]];
            rx_multicast_axis <= rx_desc_multicast[
                rx_desc_rd_bin[RX_DESC_BITS-1:0]];
            rx_start_axis <= rx_desc_start[
                rx_desc_rd_bin[RX_DESC_BITS-1:0]];
            rx_words_axis <= rx_desc_words[
                rx_desc_rd_bin[RX_DESC_BITS-1:0]];
        end

        if (m_axis_rxs_tvalid && m_axis_rxs_tready) begin
            m_axis_rxs_tvalid <= 0;
            if (rx_status_index == 5) begin
                m_axis_rxs_tlast <= 0; rx_status_index <= 6;
                rx_status_active <= 0; rx_status_complete <= 1;
            end
            else rx_status_index <= rx_status_index + 1'b1;
        end
        if (!m_axis_rxs_tvalid && rx_status_active && rx_status_index < 6) begin
            m_axis_rxs_tvalid <= 1; m_axis_rxs_tlast <= (rx_status_index == 5);
            case (rx_status_index)
              0: m_axis_rxs_tdata <= 32'h50000000;
              1: m_axis_rxs_tdata <= rx_multicast_axis ? {16'd0, rx_destination_axis[47:32]} : 0;
              2: m_axis_rxs_tdata <= rx_multicast_axis ? rx_destination_axis[31:0] : 0;
              3: m_axis_rxs_tdata <= rx_status3_axis;
              4: m_axis_rxs_tdata <= 0;
              default: m_axis_rxs_tdata <= {16'd0, rx_length_axis};
            endcase
        end

        if (m_axis_rxd_tvalid && m_axis_rxd_tready) begin
            m_axis_rxd_tvalid <= 0;
            if (m_axis_rxd_tlast) begin
                m_axis_rxd_tlast <= 0; rx_axis_active <= 0;
                rx_data_complete <= 1;
            end else rx_word_index <= rx_word_index + 1'b1;
        end
        if (!m_axis_rxd_tvalid && rx_axis_active && rx_word_index < rx_available_words) begin
            m_axis_rxd_tdata <= rx_mem[rx_start_axis +
                rx_word_index[RX_ADDR_BITS-1:0]];
            m_axis_rxd_tvalid <= 1;
            m_axis_rxd_tlast <= (rx_word_index == rx_last_word);
            if (rx_word_index == rx_last_word && rx_length_axis[1:0] != 0)
                m_axis_rxd_tkeep <= (4'b0001 << rx_length_axis[1:0]) - 1'b1;
            else m_axis_rxd_tkeep <= 4'hf;
        end
        if (rx_data_complete && rx_status_complete) begin
            rx_data_rd_bin <= rx_data_rd_bin + rx_words_axis;
            rx_desc_rd_bin <= rx_desc_rd_bin + 1'b1;
            rx_desc_rd_gray <= ((rx_desc_rd_bin + 1'b1) >> 1) ^
                               (rx_desc_rd_bin + 1'b1);
            rx_data_complete <= 0; rx_status_complete <= 0;
        end
    end
end

// ---- data read pointers published one word per clock ----
// tx_data_rd_bin / rx_data_rd_bin jump by a whole frame's worth of words at
// once, and the other clock domain decodes the synchronized Gray value to
// work out how much buffer is free. A Gray code is only safe to synchronize
// when it changes by exactly one bit per update; a multi-word jump can change
// many bits at once, and a sample taken mid-transition decodes to an arbitrary
// pointer, which could report free space that is not free yet (overwriting
// unread transmit or receive data). So the pointer that is actually
// synchronized (*_rd_gray, from *_rd_pub) follows the binary pointer one word
// per clock. The only cost is that freed space is reported up to a frame's
// worth of clocks late -- conservative, never optimistic.
reg [TX_ADDR_BITS:0] tx_data_rd_pub;
always @(posedge gtx_clk) begin
    if (!gtx_tx_resetn) begin
        tx_data_rd_pub <= 0; tx_data_rd_gray <= 0;
    end else if (tx_data_rd_pub != tx_data_rd_bin) begin
        tx_data_rd_pub  <= tx_data_rd_pub + 1'b1;
        tx_data_rd_gray <= ((tx_data_rd_pub + 1'b1) >> 1) ^ (tx_data_rd_pub + 1'b1);
    end
end

reg [RX_ADDR_BITS:0] rx_data_rd_pub;
always @(posedge axis_clk) begin
    if (!axis_rxd_resetn || !axis_rxs_resetn) begin
        rx_data_rd_pub <= 0; rx_data_rd_gray <= 0;
    end else if (rx_data_rd_pub != rx_data_rd_bin) begin
        rx_data_rd_pub  <= rx_data_rd_pub + 1'b1;
        rx_data_rd_gray <= ((rx_data_rd_pub + 1'b1) >> 1) ^ (rx_data_rd_pub + 1'b1);
    end
end

endmodule
