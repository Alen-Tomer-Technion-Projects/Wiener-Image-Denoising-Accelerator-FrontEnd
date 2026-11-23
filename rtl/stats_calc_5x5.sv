// File      : stats_calc_5x5.sv
// Module    : stats_calc_5x5
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   Local statistics of the window: mean and variance, over either the full
//   5x5 window or only its centre 3x3 (selected by mode_3x3).
//
//   Stage 1 (combinational, then registered)
//     Square all 25 pixels. Sum pixels and squares with balanced adder
//     trees, separately for the centre 3x3 and the outer 16 pixel ring.
//     5x5 sums = 3x3 sums + ring sums. mode_3x3 picks which sums to keep.
//
//   Stage 2 (combinational, then registered on valid)
//     Divide by N (9 or 25) with a constant reciprocal multiply and shift:
//       mu    = sum_x  * round(2^24 / N) >> 16   gives Q8.8
//       E[x2] = sum_x2 * round(2^31 / N) >> 23   gives Q16.8
//     var = E[x2] - mu^2 (floored at 0), then truncated from Q16.8 to Q16.4
//     and saturated to 18 bits (Q14.4).
//
// Timing
//   Latency is 2 clocks from stats_in_valid to out_valid.
//   mu_q8_8 and var_q14_4 only update when a valid result is produced.
//   mode_3x3 is used in both stages, so it must be static during a frame.
//
// Ports
//   clk             in   1      Clock, rising edge
//   rst_n           in   1      Asynchronous active low reset
//   stats_in_valid  in   1      The 25 pixel inputs are valid this cycle
//   mode_3x3        in   1      1 = statistics over centre 3x3, 0 = full 5x5
//   p_<r>_<c>       in   DW     25 window pixels, r and c in {m2,m1,0,p1,p2}
//   out_valid       out  1      mu_q8_8 and var_q14_4 are valid
//   mu_q8_8         out  16     Local mean, unsigned Q8.8
//   var_q14_4       out  18     Local variance, unsigned Q14.4, saturated

module stats_calc_5x5 #(
    parameter int DW = 8   // Pixel data width (bits)
)(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          stats_in_valid,
    input  logic          mode_3x3,

    // 25 pixel inputs named p_<row offset>_<column offset>
    input  logic [DW-1:0] p_m2_m2, p_m2_m1, p_m2_0,  p_m2_p1, p_m2_p2,
    input  logic [DW-1:0] p_m1_m2, p_m1_m1, p_m1_0,  p_m1_p1, p_m1_p2,
    input  logic [DW-1:0] p_0_m2,  p_0_m1,  p_0_0,   p_0_p1,  p_0_p2,
    input  logic [DW-1:0] p_p1_m2, p_p1_m1, p_p1_0,  p_p1_p1, p_p1_p2,
    input  logic [DW-1:0] p_p2_m2, p_p2_m1, p_p2_0,  p_p2_p1, p_p2_p2,

    output logic          out_valid,
    output logic [15:0]   mu_q8_8,
    output logic [17:0]   var_q14_4
);

    // Stage 1 signals

    // Selected sums. Widths cover the worst case of 25 pixels at 255:
    //   sum_x  max 255 * 25   = 6375       needs 13 bits
    //   sum_x2 max 65025 * 25 = 1,625,625  needs 21 bits
    logic [12:0] sum_x;
    logic [20:0] sum_x2;

    // Partial sums for the centre 3x3, the 16 pixel ring and the full 5x5
    logic [12:0] sum_x_3x3,  sum_x_ring,  sum_x_5x5;
    logic [20:0] sum_x2_3x3, sum_x2_ring, sum_x2_5x5;

    // Adder tree levels (l1 = first level of pair sums, and so on)
    logic [12:0] center_x_l1  [0:3], center_x_l2  [0:1];
    logic [20:0] center_x2_l1 [0:3], center_x2_l2 [0:1];
    logic [12:0] ring_x_l1    [0:7], ring_x_l2    [0:3], ring_x_l3  [0:1];
    logic [20:0] ring_x2_l1   [0:7], ring_x2_l2   [0:3], ring_x2_l3 [0:1];

    // The 25 pixels as an array (raster order) and their squares
    logic [7:0]  pix [0:24];
    logic [15:0] sq  [0:24];   // 255^2 = 65025 fits in 16 bits

    // Stage 1 output registers
    logic [12:0] sum_x_d;
    logic [20:0] sum_x2_d;
    logic        stats_in_valid_d;

    // Stage 2 signals
    logic [15:0] mu_c;     // Q8.8 mean, max 255 * 256 = 65280
    logic [23:0] ex2_c;    // Q16.8 E[x^2], max 65025 * 256 = 16,646,400
    logic [23:0] mu_sq_c;  // Q16.8 mean squared, same scale as ex2_c

    // Stage 1: squares and adder trees

    always_comb begin
        // Map the named inputs to a raster ordered array.
        // Index = 5 * row + col, with row and col counted 0..4 from top left.
        pix[0]  = p_m2_m2;  pix[1]  = p_m2_m1;  pix[2]  = p_m2_0;  pix[3]  = p_m2_p1;  pix[4]  = p_m2_p2;
        pix[5]  = p_m1_m2;  pix[6]  = p_m1_m1;  pix[7]  = p_m1_0;  pix[8]  = p_m1_p1;  pix[9]  = p_m1_p2;
        pix[10] = p_0_m2;   pix[11] = p_0_m1;   pix[12] = p_0_0;   pix[13] = p_0_p1;   pix[14] = p_0_p2;
        pix[15] = p_p1_m2;  pix[16] = p_p1_m1;  pix[17] = p_p1_0;  pix[18] = p_p1_p1;  pix[19] = p_p1_p2;
        pix[20] = p_p2_m2;  pix[21] = p_p2_m1;  pix[22] = p_p2_0;  pix[23] = p_p2_p1;  pix[24] = p_p2_p2;

        // Square every pixel (25 parallel 8x8 multipliers)
        for (int i = 0; i < 25; i++) begin
            sq[i] = 16'(pix[i]) * 16'(pix[i]);
        end

        // Centre 3x3 = indices 6, 7, 8, 11, 12, 13, 16, 17, 18.
        // Eight of them go through a 3 level tree, the ninth is added at the root.
        center_x_l1[0]  = 13'(pix[6])  + 13'(pix[7]);
        center_x_l1[1]  = 13'(pix[8])  + 13'(pix[11]);
        center_x_l1[2]  = 13'(pix[12]) + 13'(pix[13]);
        center_x_l1[3]  = 13'(pix[16]) + 13'(pix[17]);
        center_x2_l1[0] = 21'(sq[6])   + 21'(sq[7]);
        center_x2_l1[1] = 21'(sq[8])   + 21'(sq[11]);
        center_x2_l1[2] = 21'(sq[12])  + 21'(sq[13]);
        center_x2_l1[3] = 21'(sq[16])  + 21'(sq[17]);

        for (int i = 0; i < 2; i++) begin
            center_x_l2[i]  = center_x_l1[2*i]  + center_x_l1[2*i+1];
            center_x2_l2[i] = center_x2_l1[2*i] + center_x2_l1[2*i+1];
        end
        sum_x_3x3  = (center_x_l2[0]  + center_x_l2[1])  + 13'(pix[18]);
        sum_x2_3x3 = (center_x2_l2[0] + center_x2_l2[1]) + 21'(sq[18]);

        // Outer ring = the 16 remaining pixels, reduced 16 -> 8 -> 4 -> 2 -> 1
        ring_x_l1[0]  = 13'(pix[0])  + 13'(pix[1]);
        ring_x_l1[1]  = 13'(pix[2])  + 13'(pix[3]);
        ring_x_l1[2]  = 13'(pix[4])  + 13'(pix[5]);
        ring_x_l1[3]  = 13'(pix[9])  + 13'(pix[10]);
        ring_x_l1[4]  = 13'(pix[14]) + 13'(pix[15]);
        ring_x_l1[5]  = 13'(pix[19]) + 13'(pix[20]);
        ring_x_l1[6]  = 13'(pix[21]) + 13'(pix[22]);
        ring_x_l1[7]  = 13'(pix[23]) + 13'(pix[24]);
        ring_x2_l1[0] = 21'(sq[0])   + 21'(sq[1]);
        ring_x2_l1[1] = 21'(sq[2])   + 21'(sq[3]);
        ring_x2_l1[2] = 21'(sq[4])   + 21'(sq[5]);
        ring_x2_l1[3] = 21'(sq[9])   + 21'(sq[10]);
        ring_x2_l1[4] = 21'(sq[14])  + 21'(sq[15]);
        ring_x2_l1[5] = 21'(sq[19])  + 21'(sq[20]);
        ring_x2_l1[6] = 21'(sq[21])  + 21'(sq[22]);
        ring_x2_l1[7] = 21'(sq[23])  + 21'(sq[24]);

        for (int i = 0; i < 4; i++) begin
            ring_x_l2[i]  = ring_x_l1[2*i]  + ring_x_l1[2*i+1];
            ring_x2_l2[i] = ring_x2_l1[2*i] + ring_x2_l1[2*i+1];
        end
        for (int i = 0; i < 2; i++) begin
            ring_x_l3[i]  = ring_x_l2[2*i]  + ring_x_l2[2*i+1];
            ring_x2_l3[i] = ring_x2_l2[2*i] + ring_x2_l2[2*i+1];
        end
        sum_x_ring  = ring_x_l3[0]  + ring_x_l3[1];
        sum_x2_ring = ring_x2_l3[0] + ring_x2_l3[1];

        // Full window = centre + ring, so the centre 9 pixels are summed once
        sum_x_5x5  = sum_x_3x3  + sum_x_ring;
        sum_x2_5x5 = sum_x2_3x3 + sum_x2_ring;

        // Mode select. Both sums are always computed, only the choice changes.
        sum_x  = mode_3x3 ? sum_x_3x3  : sum_x_5x5;
        sum_x2 = mode_3x3 ? sum_x2_3x3 : sum_x2_5x5;
    end

    // Stage 1 register: breaks the adder trees from the multipliers below
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_x_d          <= 13'd0;
            sum_x2_d         <= 21'd0;
            stats_in_valid_d <= 1'b0;
        end else begin
            sum_x_d          <= sum_x;
            sum_x2_d         <= sum_x2;
            stats_in_valid_d <= stats_in_valid;
        end
    end

    // Stage 2: divide by N, mean squared, variance

    // Reciprocal constants (rounded up) and their shifts
    localparam logic [20:0] MU_RECIP_9   = 21'd1864136;    // ceil(2^24 / 9)
    localparam logic [19:0] MU_RECIP_25  = 20'd671089;     // ceil(2^24 / 25)
    localparam int          MU_SHIFT     = 16;
    localparam logic [27:0] EX2_RECIP_9  = 28'd238609295;  // ceil(2^31 / 9)
    localparam logic [26:0] EX2_RECIP_25 = 27'd85899346;   // ceil(2^31 / 25)
    localparam int          EX2_SHIFT    = 23;

    // Both reciprocal products are computed, the mode picks one
    wire [33:0] mu_product_9,  mu_product_25;
    wire [46:0] ex2_product_9, ex2_product_25;

    assign mu_product_9   = 34'(sum_x_d)  * 34'(MU_RECIP_9);
    assign mu_product_25  = 34'(sum_x_d)  * 34'(MU_RECIP_25);
    assign ex2_product_9  = 47'(sum_x2_d) * 47'(EX2_RECIP_9);
    assign ex2_product_25 = 47'(sum_x2_d) * 47'(EX2_RECIP_25);

    // Mean in Q8.8 and E[x^2] in Q16.8
    assign mu_c  = mode_3x3 ? (mu_product_9  >> MU_SHIFT)  : (mu_product_25  >> MU_SHIFT);
    assign ex2_c = mode_3x3 ? (ex2_product_9 >> EX2_SHIFT) : (ex2_product_25 >> EX2_SHIFT);

    // Mean squared: Q8.8 * Q8.8 = Q16.16, shift by 8 to get Q16.8
    wire [31:0] mu_sq_full = 32'(mu_c) * 32'(mu_c);
    assign mu_sq_c = mu_sq_full >> 8;

    // Variance = E[x^2] - mu^2 in Q16.8, floored at 0 (rounding can make it negative)
    wire [23:0] var_q16_8_c = (ex2_c > mu_sq_c) ? (ex2_c - mu_sq_c) : 24'd0;

    // Drop 4 fraction bits (Q16.4), then saturate the 2 top integer bits (Q14.4)
    wire [19:0] var_q16_4_c = var_q16_8_c[23:4];
    wire [17:0] var_q14_4_c = (|var_q16_4_c[19:18]) ? 18'h3FFFF : var_q16_4_c[17:0];

    // Stage 2 register: results only update on a valid sample
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            mu_q8_8   <= '0;
            var_q14_4 <= '0;
        end else begin
            out_valid <= stats_in_valid_d;
            if (stats_in_valid_d) begin
                mu_q8_8   <= mu_c;
                var_q14_4 <= var_q14_4_c;
            end
        end
    end

endmodule
