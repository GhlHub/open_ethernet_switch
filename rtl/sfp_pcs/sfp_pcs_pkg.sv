// sfp_pcs_pkg.sv
//
// Code-group constants for a hand-built IEEE 802.3 Clause 36 1000BASE-X
// PCS, sitting between GMII (to the MAC) and a GTH transceiver's 8b/10b-
// assisted parallel interface (to the SFP cage). These are the canonical
// byte values used with TXCHARISK/RXCHARISK to select each Kx.y/Dx.y
// symbol -- GTH's own hardware 8b/10b encoder/decoder (TX8B10BEN/
// RX8B10BEN) does the actual bit-level 10b encoding; fabric logic only
// ever deals with these 8-bit values plus a K/D flag.
//
// Values follow byte = (y << 5) | x for Kx.y / Dx.y notation, cross-
// checked against the well-known canonical K28.5 = 0xBC.

package sfp_pcs_pkg;

  // ---- special (K) code groups ----
  parameter logic [7:0] K28_5 = 8'hBC; // comma -- used in every ordered set
  parameter logic [7:0] K27_7 = 8'hFB; // /S/  Start_of_Packet
  parameter logic [7:0] K29_7 = 8'hFD; // /T/  End_of_Packet
  parameter logic [7:0] K23_7 = 8'hF7; // /R/  Carrier_Extend (always follows /T/)
  parameter logic [7:0] K30_7 = 8'hFE; // /V/  Error_Propagation

  // ---- data (D) code groups used in ordered sets ----
  parameter logic [7:0] D5_6  = 8'hC5; // /I1/ second code group (RD+ -> RD-)
  parameter logic [7:0] D16_2 = 8'h50; // /I2/ second code group (RD- preserved)
  parameter logic [7:0] D21_5 = 8'hB5; // /C1/ second code group
  parameter logic [7:0] D2_2  = 8'h42; // /C2/ second code group

endpackage
