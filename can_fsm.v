// Module: can_fsm
// Description: Bosch CAN 2.0A/B Protocol State Machine
// - Controls framing for CAN 2.0A (11-bit standard ID) and CAN 2.0B (29-bit extended ID)
// - Manages non-destructive bitwise arbitration, bit sequencing, ACK, EOF, and Intermission
// - Handles protocol edge cases:
//     * Zero DLC or Remote Frame (RTR=1) skips DATA field directly to CRC
//     * Dominant bit on Intermission bits 1-2 triggers Overload Frame (no TEC/REC penalty)
//     * Dominant bit on Intermission bit 3 is interpreted as next frame SOF
//     * Receivers validate frame on 6th bit of EOF (dominant on 7th bit ignored)

`timescale 1ns / 1ps

module can_fsm (
    input  wire        clk,
    input  wire        rst_n,

    // Timing strobes from BTL
    input  wire        sample_point,
    input  wire        bit_end,
    input  wire        rx_sample,
    output wire        sync_req,

    // Bit stuffing interface
    input  wire        stuff_inserted,
    input  wire        rx_destuffed_valid,
    input  wire        stuff_error,
    output wire        stuff_en,
    output wire        stuff_reset,

    // CRC-15 interface
    output wire        crc_init,
    output wire        crc_en,
    output wire        crc_bit_in,
    input  wire [14:0] crc_val,

    // Error handler interface
    input  wire        is_error_active,
    input  wire        is_bus_off,
    output wire        err_tx_pulse,
    output wire        err_rx_pulse,
    output wire        tx_success_pulse,
    output wire        rx_success_pulse,

    // Host TX interface
    input  wire        tx_start,
    input  wire        loopback_en,
    input  wire        tx_ide,
    input  wire [10:0] tx_id,
    input  wire [17:0] tx_ext_id,
    input  wire [3:0]  tx_dlc,
    input  wire [63:0] tx_data,

    // Host RX interface
    output wire        rx_valid,
    output wire        rx_ide,
    output wire [10:0] rx_id,
    output wire [17:0] rx_ext_id,
    output wire [3:0]  rx_dlc,
    output wire [63:0] rx_data,

    // Physical bitstream
    output wire        tx_bit,
    output wire        tx_active,
    output wire        busy
);

    // Module implementation here

endmodule
