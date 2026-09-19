// SPDX-License-Identifier: GPL-3.0-or-later
//
// Imported unmodified from GhlHub/open-ethernet-cores' `open_eth_sgmii_pcs_pma`
// IP (ip/open_eth_sgmii_pcs_pma/hdl/open_eth_mdio_master.sv), the same
// upstream project rtl/pl_gmii/open_eth_mac_1g_switch.sv was forked from --
// see docs/source-notices.md. No changes from the upstream file; the
// original import does not record an upstream commit ID. Used here as a
// standalone Clause 22 MDIO master (upstream only instantiates it inside
// the larger SGMII PCS/PMA core, not independently) -- see
// mdio_controller.sv for the AXI4-Lite shim wrapping it for that use.
`timescale 1ns/1ps
// IEEE 802.3 Clause 22 MDIO station-management master.
module open_eth_mdio_master (
    input  wire        clk,
    input  wire        resetn,
    input  wire [15:0] clk_divider,
    input  wire        start,
    input  wire        write_not_read,
    input  wire [4:0]  phy_addr,
    input  wire [4:0]  reg_addr,
    input  wire [15:0] write_data,
    output reg  [15:0] read_data,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg         mdc,
    input  wire        mdio_i,
    output wire        mdio_o,
    output wire        mdio_t
);

reg [15:0] divider_count;
reg [63:0] frame;
reg [5:0] bit_index;
reg transaction_write;

// A read releases MDIO for both turnaround bits and the sixteen data bits.
// Writes drive the complete frame. MDIO is released whenever the master is
// idle so another station-management entity cannot be disturbed.
assign mdio_t = !busy || (!transaction_write && bit_index <= 6'd17);
assign mdio_o = frame[bit_index];

always @(posedge clk) begin
    done <= 1'b0;
    error <= 1'b0;

    if (!resetn) begin
        divider_count <= 16'd0;
        frame <= 64'hffff_ffff_6000_0000;
        bit_index <= 6'd63;
        transaction_write <= 1'b0;
        read_data <= 16'd0;
        busy <= 1'b0;
        mdc <= 1'b0;
    end else if (!busy) begin
        divider_count <= 16'd0;
        mdc <= 1'b0;
        if (start) begin
            transaction_write <= write_not_read;
            bit_index <= 6'd63;
            read_data <= 16'd0;
            busy <= 1'b1;
            // Preamble, ST=01, OP=(01 write/10 read), PHYAD, REGAD,
            // TA=(10 write/Z0 read), and sixteen data bits.
            frame <= {32'hffff_ffff, 2'b01,
                write_not_read ? 2'b01 : 2'b10,
                phy_addr, reg_addr,
                write_not_read ? 2'b10 : 2'b00,
                write_not_read ? write_data : 16'h0000};
        end
    end else if (divider_count >= clk_divider) begin
        divider_count <= 16'd0;
        if (!mdc) begin
            // Rising MDC is the sampling edge.
            mdc <= 1'b1;
            if (!transaction_write && bit_index == 6'd16 && mdio_i != 1'b0)
                error <= 1'b1;
            if (!transaction_write && bit_index <= 6'd15)
                read_data <= {read_data[14:0], mdio_i};
        end else begin
            // Advance only after the falling edge so every driven bit has a
            // complete setup/high/hold interval.
            mdc <= 1'b0;
            if (bit_index == 0) begin
                busy <= 1'b0;
                done <= 1'b1;
            end else begin
                bit_index <= bit_index - 1'b1;
            end
        end
    end else begin
        divider_count <= divider_count + 1'b1;
    end
end

endmodule
