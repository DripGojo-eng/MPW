// Module: can_btl
// Description: Bit Timing Logic (BTL)
// - Divides master clock into discrete Time Quanta (TQ): TQ = (BRP + 1) * t_clk
// - Synthesizes standard CAN bit segments: Sync_Seg, Prop_Seg, Phase_Seg1, Phase_Seg2, SJW
// - Generates sample_point and bit_end timing strobes for the protocol FSM

`timescale 1ns / 1ps
module can_btl (
    input wire clk,
    input wire rst_n,         
    input wire can_rx,         // Physical CAN RX line
    input wire [7:0] brp,            // Baud rate prescaler (system clocks per Tq - 1)
    input wire [3:0] prop_seg,       // Propagation segment (in Tq - 1)
    input wire [3:0] phase_seg1,     // Phase segment 1 (in Tq - 1)
    input wire [3:0] phase_seg2,     // Phase segment 2 (in Tq - 1)
    input wire [1:0] sjw,            // Resync Jump Width (0..3 represents 1..4 Tq)
    input wire        sync_req,       // Force hard resync request (from FSM at SOF TX)
    input wire bus_idle,       // Bus idle indicator from FSM
    input wire tx_bit_out,     // Currently transmitted bit (for Rule 4 exception)
    
    output reg tq_pulse,       // Strobe on each Time Quantum boundary
    output reg sample_point,   // Strobe at the sample point (end of phase_seg1)
    output reg bit_end,        // Strobe at the end of current bit (end of phase_seg2)
    output reg rx_sample,      // Sampled CAN RX level at sample point
    output reg hard_sync_done  // Pulse when hard sync is completed
);
    // Double-flop synchronizer for asynchronous can_rx input
    reg rx_sync1;
    reg rx_sync2;
    reg rx_prev;
    wire rx_falling_edge;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
            rx_prev  <= 1'b1;
        end else begin
            rx_sync1 <= can_rx;
            rx_sync2 <= rx_sync1;
            rx_prev  <= rx_sync2;
        end
    end

    assign rx_falling_edge = (rx_prev == 1'b1) && (rx_sync2 == 1'b0);

    // Hard Sync trigger:
    // Bosch Rule 3: Hard synchronization on falling edge during bus idle, or forced by FSM
    wire hard_sync_trig = (bus_idle && rx_falling_edge) || sync_req;

    // Bit segments
    localparam SEG_SYNC   = 2'd0;
    localparam SEG_PROP   = 2'd1;
    localparam SEG_PHASE1 = 2'd2;
    localparam SEG_PHASE2 = 2'd3;

    reg [1:0] seg_state;
    reg [4:0] tq_in_seg;        // 5 bits to prevent overflow
    reg [3:0] phase1_ext;       // Extension for PHASE_SEG1 (1..4 Tq)
    reg [3:0] phase2_short;     // Shortening for PHASE_SEG2 (1..4 Tq)
    reg       sync_done_in_bit; // Rule 1: Max 1 resynchronization per bit time

    wire [3:0] max_sjw = {2'b00, sjw} + 4'd1; // SJW in Tq: 1..4

    // Bosch Resynchronization Rules:
    // Rule 1: Only 1 sync per bit time (!sync_done_in_bit)
    // Rule 2: Previous sampled value was recessive (rx_sample == 1'b1)
    // Rule 4: If transmitter driving dominant (tx_bit_out == 1'b0), no resync on e > 0
    wire valid_resync_edge = rx_falling_edge && (!hard_sync_trig) && (!sync_done_in_bit) && (rx_sample == 1'b1);

    // Fix 1: Exact |e| <= SJW check in PHASE2 without off-by-one:
    // |e| = (phase_seg2 + 1) - tq_in_seg <= (sjw + 1)  <=>  (phase_seg2 - tq_in_seg) <= sjw
    wire phase2_e_lte_sjw = (seg_state == SEG_PHASE2) && 
                            (({1'b0, phase_seg2} >= {1'b0, tq_in_seg}) ? 
                             (({1'b0, phase_seg2} - {1'b0, tq_in_seg}) <= {3'b000, sjw}) : 1'b1);

    wire resync_shorten_now = valid_resync_edge && (seg_state == SEG_PHASE2) && phase2_e_lte_sjw;

    // Fix 3: Active positive phase error e calculation in PROP and PHASE1
    // In PROP:   e = tq_in_seg + 1
    // In PHASE1: e = (prop_seg + 1) + tq_in_seg + 1 = prop_seg + tq_in_seg + 2
    // 6-bit width prevents wrap-around when prop_seg=15 and tq_in_seg=15 (15+15+2=32)
    wire [5:0] active_pos_err = (seg_state == SEG_PROP) ? 
                                ({1'b0, tq_in_seg} + 6'd1) : 
                                ({2'b00, prop_seg} + {1'b0, tq_in_seg} + 6'd2);
    wire [3:0] pos_ext_val    = (active_pos_err < {2'b00, max_sjw}) ? active_pos_err[3:0] : max_sjw;

    // Fix 2: Combinational lookahead for same-cycle edge and tq_pulse resolution
    reg [3:0] phase1_ext_comb;
    reg [3:0] phase2_short_comb;
    reg       sync_done_comb;

    always @(*) begin
        phase1_ext_comb   = phase1_ext;
        phase2_short_comb = phase2_short;
        sync_done_comb    = sync_done_in_bit;

        if (valid_resync_edge) begin
            case (seg_state)
                SEG_SYNC: begin
                    sync_done_comb = 1'b1;
                end

                SEG_PROP, SEG_PHASE1: begin
                    // Rule 4: Transmitter driving dominant bit must not resync on e > 0
                    if (tx_bit_out == 1'b1) begin
                        sync_done_comb  = 1'b1;
                        phase1_ext_comb = pos_ext_val;
                    end
                end

                SEG_PHASE2: begin
                    sync_done_comb    = 1'b1;
                    phase2_short_comb = max_sjw;
                end

                default: ;
            endcase
        end
    end

    // Prescaler: generates Time Quantum (Tq) pulse
    reg [7:0] prescaler_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prescaler_cnt <= 8'h00;
            tq_pulse      <= 1'b0;
        end else begin
            if (hard_sync_trig || resync_shorten_now) begin
                prescaler_cnt <= 8'h00;
                tq_pulse      <= 1'b0;
            end else if (prescaler_cnt >= brp) begin
                prescaler_cnt <= 8'h00;
                tq_pulse      <= 1'b1;
            end else begin
                prescaler_cnt <= prescaler_cnt + 8'd1;
                tq_pulse      <= 1'b0;
            end
        end
    end

    // Segment FSM and Timing Control
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_state        <= SEG_SYNC;
            tq_in_seg        <= 5'd0;
            sample_point     <= 1'b0;
            bit_end          <= 1'b0;
            rx_sample        <= 1'b1;
            hard_sync_done   <= 1'b0;
            phase1_ext       <= 4'd0;
            phase2_short     <= 4'd0;
            sync_done_in_bit <= 1'b0;
        end else begin
            sample_point   <= 1'b0;
            bit_end        <= 1'b0;
            hard_sync_done <= 1'b0;

            if (hard_sync_trig) begin
                seg_state        <= SEG_SYNC;
                tq_in_seg        <= 5'd0;
                hard_sync_done   <= 1'b1;
                phase1_ext       <= 4'd0;
                phase2_short     <= 4'd0;
                sync_done_in_bit <= 1'b1; // Hard sync counts as sync for this bit
            end else if (resync_shorten_now) begin
                seg_state        <= SEG_SYNC;
                tq_in_seg        <= 5'd0;
                bit_end          <= 1'b1;
                phase1_ext       <= 4'd0;
                phase2_short     <= 4'd0;
                sync_done_in_bit <= 1'b1;
            end else begin
                // Latch next-state values
                phase1_ext       <= phase1_ext_comb;
                phase2_short     <= phase2_short_comb;
                sync_done_in_bit <= sync_done_comb;

                if (tq_pulse) begin
                    case (seg_state)
                        SEG_SYNC: begin
                            // SYNC_SEG is always 1 Tq long
                            seg_state <= SEG_PROP;
                            tq_in_seg <= 5'd0;
                        end

                        SEG_PROP: begin
                            if (tq_in_seg >= {1'b0, prop_seg}) begin
                                seg_state <= SEG_PHASE1;
                                tq_in_seg <= 5'd0;
                            end else begin
                                tq_in_seg <= tq_in_seg + 5'd1;
                            end
                        end

                        SEG_PHASE1: begin
                            // Uses phase1_ext_comb for same-cycle edge resolution
                            if (tq_in_seg >= ({1'b0, phase_seg1} + {1'b0, phase1_ext_comb})) begin
                                seg_state    <= SEG_PHASE2;
                                tq_in_seg    <= 5'd0;
                                sample_point <= 1'b1;
                                rx_sample    <= rx_sync2;
                            end else begin
                                tq_in_seg <= tq_in_seg + 5'd1;
                            end
                        end

                        SEG_PHASE2: begin
                            // Uses phase2_short_comb for same-cycle edge resolution
                            if ((tq_in_seg + {1'b0, phase2_short_comb}) >= {1'b0, phase_seg2}) begin
                                seg_state        <= SEG_SYNC;
                                tq_in_seg        <= 5'd0;
                                bit_end          <= 1'b1;
                                phase1_ext       <= 4'd0;
                                phase2_short     <= 4'd0;
                                sync_done_in_bit <= 1'b0; // Reset for next bit
                            end else begin
                                tq_in_seg <= tq_in_seg + 5'd1;
                            end
                        end

                        default: begin
                            seg_state        <= SEG_SYNC;
                            tq_in_seg        <= 5'd0;
                            phase1_ext       <= 4'd0;
                            phase2_short     <= 4'd0;
                            sync_done_in_bit <= 1'b0;
                        end
                    endcase
                end
            end
        end
    end
endmodule