// Module: can_reg_bank
// Description: Memory-Mapped Host Interface (32 Registers, Addr[4:0])
// - Provides full configuration (BTL prescaler, segments, SJW, ACR/AMR acceptance filters)
// - Provides transmit and receive buffers (29-bit ID, DLC, IDE, RTR, 8-byte data buffer)
// - Exposes status flags and error counter monitoring (TEC, REC)

`timescale 1ns / 1ps
module can_reg_bank (
    input wire clk,
    input wire rst_n,

    // Host Bus
    input wire cs_n,
    input wire we_n,
    input wire oe_n,
    input wire [2:0] addr,
    input wire [7:0] din,
    output reg [7:0] dout,
    output wire irq,

    // Configuration outputs
    output reg [7:0] cfg_brp,
    output reg [3:0] cfg_prop_seg,
    output reg [3:0] cfg_phase_seg1,
    output reg [3:0] cfg_phase_seg2,
    output reg [1:0] cfg_sjw,
    output reg loopback_en,
    output reg bus_off_recover,

    // Acceptance filter outputs
    output reg [10:0] cfg_acr,     // Acceptance Code Register
    output reg [10:0] cfg_amr,     // Acceptance Mask Register (1=don't care)

    // TX controls
    output reg tx_start,
    output reg tx_ide,      // 0=Standard, 1=Extended
    output reg tx_rtr,      // 0=Data Frame, 1=Remote Frame (Bug 3)
    output reg [10:0] tx_id,
    output reg [17:0] tx_ext_id,
    output reg [3:0]  tx_dlc,
    output reg [63:0] tx_data,

    // Status & RX inputs
    input wire can_busy,
    input wire rx_valid,       // filtered rx_valid from top
    input wire rx_ide,
    input wire rx_rtr,         // received frame RTR (Bug 3)
    input wire [10:0] rx_id,
    input wire [17:0] rx_ext_id,
    input wire [3:0]  rx_dlc,
    input wire [63:0] rx_data,
    input wire [7:0]  can_tec,
    input wire [7:0]  can_rec,
    input wire is_error_passive,
    input wire is_bus_off,
    input wire tx_success_pulse
);

    reg       rx_ready;
    reg [2:0] byte_idx;
    reg       tx_done;        // Bug 4: latched tx_done status flag
    reg       rx_rtr_latched; // Bug 3: latched RX RTR flag

    assign irq = rx_ready | is_bus_off;

    // Bug 1: 2-FF synchronizers and edge detection for host interface
    reg cs_n_sync1, cs_n_sync2;
    reg we_n_sync1, we_n_sync2, we_n_prev;
    reg oe_n_sync1, oe_n_sync2, oe_n_prev;
    reg [2:0] addr_sync1, addr_sync2;
    reg [7:0] din_sync1,  din_sync2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs_n_sync1 <= 1'b1;
            cs_n_sync2 <= 1'b1;
            we_n_sync1 <= 1'b1;
            we_n_sync2 <= 1'b1;
            we_n_prev  <= 1'b1;
            oe_n_sync1 <= 1'b1;
            oe_n_sync2 <= 1'b1;
            oe_n_prev  <= 1'b1;
            addr_sync1 <= 3'd0;
            addr_sync2 <= 3'd0;
            din_sync1  <= 8'd0;
            din_sync2  <= 8'd0;
        end else begin
            cs_n_sync1 <= cs_n;
            cs_n_sync2 <= cs_n_sync1;
            we_n_sync1 <= we_n;
            we_n_sync2 <= we_n_sync1;
            we_n_prev  <= we_n_sync2;
            oe_n_sync1 <= oe_n;
            oe_n_sync2 <= oe_n_sync1;
            oe_n_prev  <= oe_n_sync2;
            addr_sync1 <= addr;
            addr_sync2 <= addr_sync1;
            din_sync1  <= din;
            din_sync2  <= din_sync1;
        end
    end

    // 1-cycle falling edge strobe for write and read
    wire wr_pulse = (!cs_n_sync2) && (!we_n_sync2) && we_n_prev;
    wire rd_pulse = (!cs_n_sync2) && (!oe_n_sync2) && oe_n_prev;
    // Increment byte_idx when the host finishes the read (rising edge of oe_n)
    wire rd_end_pulse = oe_n_sync2 && (!oe_n_prev);

    // Write logic triggered strictly on 1-cycle wr_pulse
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_brp          <= 8'd9;
            cfg_prop_seg     <= 4'd1;
            cfg_phase_seg1   <= 4'd3;
            cfg_phase_seg2   <= 4'd3;
            cfg_sjw          <= 2'd1;
            loopback_en      <= 1'b0;
            bus_off_recover  <= 1'b0;
            tx_start         <= 1'b0;
            tx_ide           <= 1'b0;
            tx_rtr           <= 1'b0;
            tx_id            <= 11'd0;
            tx_ext_id        <= 18'd0;
            tx_dlc           <= 4'd0;
            tx_data          <= 64'd0;
            rx_ready         <= 1'b0;
            rx_rtr_latched   <= 1'b0;
            tx_done          <= 1'b0;
            cfg_acr          <= 11'h7FF;
            cfg_amr          <= 11'h7FF;
            byte_idx         <= 3'd0;
        end else begin
            tx_start        <= 1'b0;
            bus_off_recover <= 1'b0;

            // Bug 4: tx_done flag sets on tx_success_pulse
            if (tx_success_pulse) begin
                tx_done <= 1'b1;
            end

            if (rx_valid) begin
                rx_ready       <= 1'b1;
                rx_rtr_latched <= rx_rtr;
            end

            // Read side-effect on rising edge of oe_n (host read finished)
            if (rd_end_pulse && (addr_sync2 == 3'd6)) begin
                byte_idx <= byte_idx + 3'd1;
            end

            // Bug 1: Write execution on 1-cycle wr_pulse
            if (wr_pulse) begin
                case (addr_sync2)
                    3'd0: begin // CTRL
                        if (din_sync2[0]) begin
                            tx_start <= 1'b1;
                            tx_done  <= 1'b0; // Bug 4: clear tx_done on new TX
                        end
                        if (din_sync2[1]) begin
                            rx_ready <= 1'b0;
                        end
                        loopback_en     <= din_sync2[2];
                        bus_off_recover <= din_sync2[3];
                        tx_ide          <= din_sync2[4];

                        // Bug 2: cfg_sjw write-enable mask on din[7]
                        if (din_sync2[7]) begin
                            cfg_sjw <= din_sync2[6:5];
                        end

                        // Bug 5: Auto-reset byte_idx on tx_start or rx_release
                        if (din_sync2[0] || din_sync2[1]) begin
                            byte_idx <= 3'd0;
                        end
                    end

                    3'd1: begin // byte_idx + phase_seg2
                        byte_idx       <= din_sync2[2:0];
                        cfg_phase_seg2 <= din_sync2[7:4];
                    end

                    3'd2: cfg_brp <= din_sync2;

                    3'd3: begin
                        cfg_prop_seg   <= din_sync2[7:4];
                        cfg_phase_seg1 <= din_sync2[3:0];
                    end

                    3'd4: begin // ID High byte: base ID[10:3]
                        tx_id[10:3] <= din_sync2;
                    end

                    3'd5: begin // ID Low: base ID[2:0] + RTR + DLC
                        tx_id[2:0] <= din_sync2[7:5];
                        tx_rtr     <= din_sync2[4]; // Bug 3: tx_rtr in din[4]
                        tx_dlc     <= din_sync2[3:0];
                    end

                    3'd6: begin // Data byte at byte_idx
                        case (byte_idx)
                            3'd0: tx_data[63:56] <= din_sync2;
                            3'd1: tx_data[55:48] <= din_sync2;
                            3'd2: tx_data[47:40] <= din_sync2;
                            3'd3: tx_data[39:32] <= din_sync2;
                            3'd4: tx_data[31:24] <= din_sync2;
                            3'd5: tx_data[23:16] <= din_sync2;
                            3'd6: tx_data[15:8]  <= din_sync2;
                            3'd7: tx_data[7:0]   <= din_sync2;
                        endcase
                        byte_idx <= byte_idx + 3'd1;
                    end

                    3'd7: begin // Extended ID / Filter config (at byte_idx)
                        case (byte_idx)
                            3'd0: tx_ext_id[17:11] <= din_sync2[6:0];
                            3'd1: tx_ext_id[10:3]  <= din_sync2;
                            3'd2: tx_ext_id[2:0]   <= din_sync2[7:5];
                            3'd3: cfg_acr[10:3]    <= din_sync2;
                            3'd4: begin
                                cfg_acr[2:0]  <= din_sync2[7:5];
                                cfg_amr[10:8] <= din_sync2[2:0];
                            end
                            3'd5: cfg_amr[7:0]     <= din_sync2;
                            default: ;
                        endcase
                    end
                endcase
            end
        end
    end

    // Combinational Host Read Multiplexer
    always @(*) begin
        if (!cs_n && !oe_n) begin
            case (addr)
                // Bug 4: tx_done readable in bit [0]
                3'd0: dout = {can_tec[3:0], tx_ide, loopback_en, rx_ready, tx_done};
                3'd1: dout = {can_busy, rx_ready, is_error_passive, is_bus_off, can_rec[3:0]};
                3'd2: dout = cfg_brp;
                3'd3: dout = {cfg_prop_seg, cfg_phase_seg1};
                3'd4: dout = rx_ready ? rx_id[10:3] : tx_id[10:3];
                3'd5: dout = rx_ready ?
                              {rx_id[2:0], rx_ide, rx_dlc} :
                              {tx_id[2:0], tx_ide, tx_dlc};
                3'd6: begin
                    case (byte_idx)
                        3'd0: dout = rx_ready ? rx_data[63:56] : tx_data[63:56];
                        3'd1: dout = rx_ready ? rx_data[55:48] : tx_data[55:48];
                        3'd2: dout = rx_ready ? rx_data[47:40] : tx_data[47:40];
                        3'd3: dout = rx_ready ? rx_data[39:32] : tx_data[39:32];
                        3'd4: dout = rx_ready ? rx_data[31:24] : tx_data[31:24];
                        3'd5: dout = rx_ready ? rx_data[23:16] : tx_data[23:16];
                        3'd6: dout = rx_ready ? rx_data[15:8]  : tx_data[15:8];
                        3'd7: dout = rx_ready ? rx_data[7:0]   : tx_data[7:0];
                    endcase
                end
                // Bug 3: rx_rtr / tx_rtr exposed in bit [7] of byte_idx == 0
                3'd7: begin
                    case (byte_idx)
                        3'd0: dout = {rx_ready ? rx_rtr_latched : tx_rtr,
                                      rx_ready ? rx_ext_id[17:11] : tx_ext_id[17:11]};
                        3'd1: dout = rx_ready ? rx_ext_id[10:3] : tx_ext_id[10:3];
                        3'd2: dout = {rx_ready ? rx_ext_id[2:0] : tx_ext_id[2:0], 5'd0};
                        3'd3: dout = cfg_acr[10:3];
                        3'd4: dout = {cfg_acr[2:0], 2'b0, cfg_amr[10:8]};
                        3'd5: dout = cfg_amr[7:0];
                        default: dout = can_tec;
                    endcase
                end
                default: dout = 8'h00;
            endcase
        end else begin
            dout = 8'h00;
        end
    end
endmodule