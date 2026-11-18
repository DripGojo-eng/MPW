// Module: can_crc15
// Description: Bosch CAN CRC-15 Engine
// - Computes the 15-bit LFSR checksum with polynomial 0x4599
//   (x^15 + x^14 + x^10 + x^8 + x^7 + x^4 + x^3 + 1)
// - Computes across SOF, identifier, control, and data fields

`timescale 1ns / 1ps
module can_crc15 (
    input wire clk,
    input wire rst_n,
    input wire crc_init,       // pulse to reset CRC register to 0
    input wire crc_en,         // pulse to calculate next bit
    input wire bit_in,         // current unstuffed bit to accumulate
    output wire [14:0] crc_out  // Current CRC-15 register contents
);

    reg [14:0] crc_reg;

    wire feedback;
    assign feedback = bit_in ^ crc_reg[14];

    wire [14:0] crc_next;
    assign crc_next[0] = feedback;
    assign crc_next[1] = crc_reg[0];
    assign crc_next[2] = crc_reg[1];
    assign crc_next[3] = crc_reg[2] ^ feedback;
    assign crc_next[4] = crc_reg[3] ^ feedback;
    assign crc_next[5] = crc_reg[4];
    assign crc_next[6] = crc_reg[5];
    assign crc_next[7] = crc_reg[6] ^ feedback;
    assign crc_next[8] = crc_reg[7] ^ feedback;
    assign crc_next[9] = crc_reg[8];
    assign crc_next[10] = crc_reg[9] ^ feedback;
    assign crc_next[11] = crc_reg[10];
    assign crc_next[12] = crc_reg[11];
    assign crc_next[13] = crc_reg[12];
    assign crc_next[14] = crc_reg[13] ^ feedback;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc_reg <= 15'd0;
        end else begin
            if (crc_init) begin
                crc_reg <= 15'd0;
            end else if (crc_en) begin
                crc_reg <= crc_next;
            end
        end
    end

    assign crc_out = crc_reg;
endmodule