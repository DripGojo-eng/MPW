// Module: can_error
// Description: Fault Confinement & Error Management Unit
// - Maintains Transmit Error Counter (TEC) and Receive Error Counter (REC)
// - Handles state transitions: Error Active, Error Passive, and Bus-Off

`timescale 1ns / 1ps
module can_error (
    input wire clk,
    input wire rst_n,
    // BTL inputs for autonomous Rule 12 Bus-Off recovery
    input wire sample_point,        // Strobe at bit sample point
    input wire rx_sample,           // Sampled bus bit (1=recessive, 0=dominant)

    // Error notification pulses
    input wire err_tx_pulse,        // Transmitter error (TEC += 8)
    input wire ack_err_pulse,       // ACK error (Rule 3 Exception 1: TEC += 8 only if !is_error_passive)
    input wire err_rx_pulse,        // Receiver normal error (REC += 1, Rule 1)
    input wire err_rx_severe_pulse, // Receiver severe error (REC += 8, Rules 2, 5, 6)
    input wire tx_success_pulse,    // Transmit success (TEC -= 1)
    input wire rx_success_pulse,    // Receive success (REC -= 1 or Rule 8 clamp to 127)
    input wire bus_off_recover,     // Host manual override recovery pulse

    // Fault confinement status
    output reg [7:0] tec,                 // Transmit Error Counter
    output reg [7:0] rec,                 // Receive Error Counter
    output wire is_error_active,     // TEC <= 127 and REC <= 127
    output wire is_error_passive,    // TEC > 127 or REC > 127
    output reg is_bus_off           // TEC >= 256
);
    assign is_error_active  = (!is_bus_off) && (tec <= 8'd127) && (rec <= 8'd127);
    assign is_error_passive = (!is_bus_off) && ((tec > 8'd127) || (rec > 8'd127));

    // Autonomous Rule 12 128 x 11 recessive-bit recovery counters
    reg [3:0] recessive_cnt; // 0..10 (counts 11 consecutive recessive bits)
    reg [6:0] seq_cnt;       // 0..127 (counts 128 sequences)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tec           <= 8'd0;
            rec           <= 8'd0;
            is_bus_off    <= 1'b0;
            recessive_cnt <= 4'd0;
            seq_cnt       <= 7'd0;
        end else begin
            // Manual host recovery override
            if (bus_off_recover) begin
                tec           <= 8'd0;
                rec           <= 8'd0;
                is_bus_off    <= 1'b0;
                recessive_cnt <= 4'd0;
                seq_cnt       <= 7'd0;
            end else if (is_bus_off) begin
                // Rule 12: Autonomous Bus-Off Recovery
                // Monitor 128 occurrences of 11 consecutive recessive bits
                if (sample_point) begin
                    if (rx_sample == 1'b1) begin
                        if (recessive_cnt == 4'd10) begin
                            recessive_cnt <= 4'd0;
                            if (seq_cnt == 7'd127) begin
                                // 128 occurrences of 11 consecutive recessive bits completed!
                                tec        <= 8'd0;
                                rec        <= 8'd0;
                                is_bus_off <= 1'b0;
                                seq_cnt    <= 7'd0;
                            end else begin
                                seq_cnt <= seq_cnt + 7'd1;
                            end
                        end else begin
                            recessive_cnt <= recessive_cnt + 4'd1;
                        end
                    end else begin
                        // Dominant bit breaks the sequence of 11 consecutive recessive bits
                        recessive_cnt <= 4'd0;
                    end
                end
            end else begin
                recessive_cnt <= 4'd0;
                seq_cnt       <= 7'd0;

                // Transmit Error Counter (TEC) Logic
                // Rule 3 Exception 1: ACK error increments TEC only if !is_error_passive
                if (ack_err_pulse) begin
                    if (!is_error_passive) begin
                        if (tec >= 8'd248) begin
                            tec        <= 8'd255;
                            is_bus_off <= 1'b1;
                        end else begin
                            tec <= tec + 8'd8;
                        end
                    end
                    // If is_error_passive, TEC is NOT incremented (Rule 3 Exception 1)
                end else if (err_tx_pulse) begin
                    if (tec >= 8'd248) begin
                        tec        <= 8'd255;
                        is_bus_off <= 1'b1;
                    end else begin
                        tec <= tec + 8'd8;
                    end
                end else if (tx_success_pulse && (tec > 8'd0)) begin
                    tec <= tec - 8'd1;
                end

                // Receive Error Counter (REC) Logic
                // Rules 2, 5, 6: Severe RX error increments REC by 8
                if (err_rx_severe_pulse) begin
                    if (rec >= 8'd248) begin
                        rec <= 8'd255;
                    end else begin
                        rec <= rec + 8'd8;
                    end
                // Rule 1: Normal RX error increments REC by 1
                end else if (err_rx_pulse) begin
                    if (rec < 8'd255) begin
                        rec <= rec + 8'd1;
                    end
                // Rule 8: If REC > 127, success sets REC to 127; if REC <= 127, decrements by 1
                end else if (rx_success_pulse) begin
                    if (rec > 8'd127) begin
                        rec <= 8'd127;
                    end else if (rec > 8'd0) begin
                        rec <= rec - 8'd1;
                    end
                end
            end
        end
    end
endmodule