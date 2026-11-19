// Module: can_bit_stuff
// Description: Bit Stuffing & Destuffing module
// - Transmit: Inserts an inverted stuff bit after 5 consecutive identical bits
// - Receive: Removes stuff bits and flags a stuff error if 6 consecutive identical bits occur

`timescale 1ns / 1ps
module can_bit_stuff (
    input wire clk,
    input wire rst_n,
    input wire stuff_reset, // Reset counters at frame boundary
    input wire stuff_en,    // Active during SOF through CRC sequence

    // TX path
    input wire tx_bit_in,   // Raw data bit from FSM
    input wire tx_advance,  // Pulse when a bit is being sent (at bit_end)
    output reg tx_bit_out,  // Bit output to CAN bus (includes stuffed bits)
    output reg stuff_inserted, // High when currently active bit is an inserted stuff bit
    output wire tx_stuff_req,  // Combinational lookahead: stuff bit required next cycle

    // RX path
    input wire rx_sample_pulse,    // Pulse at sample point
    input wire rx_bit_in,          // Sampled bit from BTL
    output reg rx_destuffed_valid, // High if rx_bit_in is a valid unstuffed data bit
    output reg stuff_error,        // High if 6 consecutive identical bits detected
    output wire rx_expect_stuff,   // Combinational lookahead: 5 identical bits sampled
    output reg rx_stuff_bit        // High when sampled bit is a discarded stuff bit
);

    // TX 5-consecutive-bit counter
    reg [2:0] tx_consec_cnt;
    reg       tx_prev_bit;

    // Combinational lookahead: ready before the upcoming bit_end edge
    assign tx_stuff_req    = stuff_en && (tx_consec_cnt == 3'd5);
    assign rx_expect_stuff = stuff_en && (rx_consec_cnt == 3'd5);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_consec_cnt  <= 3'd0;
            tx_prev_bit    <= 1'b1;
            tx_bit_out     <= 1'b1;
            stuff_inserted <= 1'b0;
        end else begin
            if (stuff_reset) begin
                tx_consec_cnt  <= 3'd0;
                tx_prev_bit    <= 1'b1;
                tx_bit_out     <= 1'b1;
                stuff_inserted <= 1'b0;
            end else if (tx_advance) begin
                if (stuff_en && (tx_consec_cnt == 3'd5)) begin
                    // Must insert complementary stuff bit
                    tx_bit_out     <= ~tx_prev_bit;
                    tx_prev_bit    <= ~tx_prev_bit;
                    tx_consec_cnt  <= 3'd1;
                    stuff_inserted <= 1'b1;
                end else begin
                    // Normal bit transmission
                    tx_bit_out     <= tx_bit_in;
                    stuff_inserted <= 1'b0;
                    if (stuff_en) begin
                        if (tx_bit_in == tx_prev_bit) begin
                            tx_consec_cnt <= tx_consec_cnt + 3'd1;
                        end else begin
                            tx_consec_cnt <= 3'd1;
                            tx_prev_bit   <= tx_bit_in;
                        end
                    end else begin
                        tx_consec_cnt <= 3'd0;
                        tx_prev_bit   <= tx_bit_in;
                    end
                end
            end
        end
    end

    // RX 5-consecutive-bit counter
    reg [2:0] rx_consec_cnt;
    reg       rx_prev_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_consec_cnt      <= 3'd0;
            rx_prev_bit        <= 1'b1;
            rx_destuffed_valid <= 1'b0;
            stuff_error        <= 1'b0;
            rx_stuff_bit       <= 1'b0;
        end else begin
            if (stuff_reset) begin
                rx_consec_cnt      <= 3'd0;
                rx_prev_bit        <= 1'b1;
                rx_destuffed_valid <= 1'b0;
                stuff_error        <= 1'b0;
                rx_stuff_bit       <= 1'b0;
            end else begin
                // Clear rx_stuff_bit once the bit has ended (at tx_advance / bit_end)
                if (tx_advance) begin
                    rx_stuff_bit <= 1'b0;
                end

                if (rx_sample_pulse) begin
                    stuff_error        <= 1'b0;
                    rx_destuffed_valid <= 1'b0;

                    if (stuff_en) begin
                        if (rx_consec_cnt == 3'd5) begin
                            if (rx_bit_in == rx_prev_bit) begin
                                // 6 consecutive identical bits in stuffed zone -> Stuff Error!
                                stuff_error        <= 1'b1;
                                rx_destuffed_valid <= 1'b0;
                                rx_consec_cnt      <= 3'd0;
                                rx_stuff_bit       <= 1'b0;
                            end else begin
                                // 6th bit is opposite polarity: Valid stuff bit! Discard from data stream.
                                rx_destuffed_valid <= 1'b0;
                                rx_prev_bit        <= rx_bit_in;
                                rx_consec_cnt      <= 3'd1;
                                rx_stuff_bit       <= 1'b1;
                            end
                        end else begin
                            // Normal bit reception in stuffed zone
                            rx_destuffed_valid <= 1'b1;
                            rx_stuff_bit       <= 1'b0;
                            if (rx_bit_in == rx_prev_bit) begin
                                rx_consec_cnt <= rx_consec_cnt + 3'd1;
                            end else begin
                                rx_consec_cnt <= 3'd1;
                                rx_prev_bit   <= rx_bit_in;
                            end
                        end
                    end else begin
                        // In unstuffed zone (e.g. CRC delim, ACK, EOF), every sampled bit is valid data
                        rx_destuffed_valid <= 1'b1;
                        rx_stuff_bit       <= 1'b0;
                        rx_consec_cnt      <= 3'd0;
                        rx_prev_bit        <= rx_bit_in;
                    end
                end else begin
                    rx_destuffed_valid <= 1'b0;
                    stuff_error        <= 1'b0;
                end
            end
        end
    end
endmodule