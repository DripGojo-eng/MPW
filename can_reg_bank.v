// Module: can_reg_bank
// Description: Memory-Mapped Host Interface (32 Registers, Addr[4:0])
// - Provides full configuration (BTL prescaler, segments, SJW, ACR/AMR acceptance filters)
// - Provides transmit and receive buffers (29-bit ID, DLC, IDE, RTR, 8-byte data buffer)
// - Exposes status flags and error counter monitoring (TEC, REC)

`timescale 1ns / 1ps

module can_reg_bank (
    input  wire        clk,
    input  wire        rst_n,

    // Host bus
    input  wire        cs_n,
    input  wire        we_n,
    input  wire        oe_n,
    input  wire [4:0]  addr,
    input  wire [7:0]  din,
    output wire [7:0]  dout,
    output wire        irq,

    // Configuration outputs
    output wire [5:0]  cfg_brp,
    output wire [1:0]  cfg_sjw,
    output wire [3:0]  cfg_prop_phase1,
    output wire [2:0]  cfg_phase2,
    output wire        loopback_en,
    output wire        bus_off_recover,

    // Acceptance filter
    output wire [7:0]  cfg_acr_base,
    output wire [7:0]  cfg_amr_base,

    // TX control & buffer
    output wire        tx_start,
    output wire        tx_ide,
    output wire        tx_rtr,
    output wire [10:0] tx_id,
    output wire [17:0] tx_ext_id,
    output wire [3:0]  tx_dlc,
    output wire [63:0] tx_data,

    // RX status & buffer
    input  wire        busy,
    input  wire        rx_valid,
    input  wire        rx_ide,
    input  wire        rx_rtr,
    input  wire [10:0] rx_id,
    input  wire [17:0] rx_ext_id,
    input  wire [3:0]  rx_dlc,
    input  wire [63:0] rx_data,
    input  wire [7:0]  tec,
    input  wire [7:0]  rec,
    input  wire        is_error_passive,
    input  wire        is_bus_off
);

    // Module implementation here

endmodule
