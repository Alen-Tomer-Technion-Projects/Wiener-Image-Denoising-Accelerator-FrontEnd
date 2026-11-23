// File      : wiener_core.sv
// Module    : wiener_core
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   Applies the adaptive Wiener filter to one pixel:
//     R   = noise_var / local_var
//     w   = 1 - R                (w = 0 when R >= 236/256, about 0.92)
//     w   = max(w, W_MIN_Q1_8)   (floor so the filter never fully flattens)
//     out = mu + w * (pixel - mu), clamped to [0, 255]
//
// Number formats
//   mu_q8_8            unsigned Q8.8
//   var_q14_4          unsigned Q14.4 (0 is treated as 1 LSB to avoid / 0)
//   noise_q14_4        unsigned Q14.4
//   R_full             unsigned, 8 fraction bits
//   w_fixed, w_clamped unsigned Q1.8 (256 = 1.0)
//   internal math      signed 18 bit Q8.8
//
// Timing
//   Fully combinational datapath (including a 26 by 18 bit divider) followed
//   by one output register. Latency is 1 clock. The divider is the longest
//   combinational path in the design.
//
// Ports
//   clk                in   1    Clock, rising edge
//   rst_n              in   1    Asynchronous active low reset
//   in_valid           in   1    mu, var and centre pixel are valid
//   mu_q8_8            in   16   Local mean, Q8.8
//   var_q14_4          in   18   Local variance, Q14.4
//   noise_q14_4        in   18   Noise variance, Q14.4
//   center_pixel_q8_0  in   8    Noisy centre pixel, integer
//   out_valid          out  1    in_valid delayed by 1 clock
//   out_pixel_q8_0     out  8    Filtered pixel, integer

module wiener_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [15:0] mu_q8_8,
    input  logic [17:0] var_q14_4,
    input  logic [17:0] noise_q14_4,
    input  logic [7:0]  center_pixel_q8_0,

    output logic        out_valid,
    output logic [7:0]  out_pixel_q8_0
);

    // Weight datapath
    wire [17:0]        sigma2_safe;      // Local variance, never 0
    wire [25:0]        numerator;        // noise_var << 8, aligns R to 8 fraction bits
    wire [25:0]        R_full;           // noise_var / local_var, 8 fraction bits
    wire [8:0]         w_fixed;          // Raw weight 1 - R, Q1.8
    wire [8:0]         w_clamped;        // Weight after the minimum floor, Q1.8

    // Pixel datapath (signed, Q8.8)
    wire signed [17:0] noisy_extended;   // Centre pixel as Q8.8
    wire signed [17:0] mu_extended;      // Mean as signed Q8.8
    wire signed [17:0] diff_extended;    // pixel - mean
    wire signed [26:0] prod_full;        // w * diff, Q9.16
    wire signed [17:0] prod_q8_8;        // w * diff scaled back to Q8.8
    wire signed [17:0] restored_full;    // mean + w * diff, before clamp
    wire signed [17:0] restored_clamped; // Result clamped to [0, 255.0]

    // 255.0 in Q8.8
    localparam signed [17:0] MAX_VAL = 18'sd65280;

    // Smallest allowed weight, 16 / 256 = 0.0625
    parameter logic [8:0] W_MIN_Q1_8 = 9'd16;

    // Step 1: safe variance, replace 0 with 1 LSB so the divider never sees 0
    assign sigma2_safe = (var_q14_4 == 18'd0) ? 18'd1 : var_q14_4;

    // Step 2: ratio R = noise / var. Shifting the numerator left by 8 makes
    // the quotient carry 8 fraction bits, matching the Q1.8 weight.
    assign numerator = {noise_q14_4, 8'd0};
    assign R_full    = numerator / sigma2_safe;

    // Step 3: weight. If R >= 236/256 the pixel is treated as pure noise
    // (w = 0), otherwise w = 1 - R. Below the threshold R fits in 8 bits.
    assign w_fixed = (R_full >= 26'd236)
                     ? 9'd0
                     : (9'd256 - R_full[8:0]);

    // Step 4: apply the minimum weight floor
    assign w_clamped = (w_fixed < W_MIN_Q1_8) ? W_MIN_Q1_8 : w_fixed;

    // Step 5: difference from the local mean, in signed Q8.8
    assign noisy_extended = $signed({1'b0, center_pixel_q8_0, 8'd0});
    assign mu_extended    = $signed({1'b0, mu_q8_8});
    assign diff_extended  = noisy_extended - mu_extended;

    // Step 6: scale the difference by the weight and add the mean back.
    // Q1.8 * Q8.8 = Q9.16, arithmetic shift by 8 returns to Q8.8.
    assign prod_full     = $signed({1'b0, w_clamped}) * diff_extended;
    assign prod_q8_8     = prod_full >>> 8;
    assign restored_full = mu_extended + prod_q8_8;

    // Step 7: clamp to the valid pixel range [0, 255.0]
    assign restored_clamped = (restored_full <= 18'sd0)    ? 18'd0      :
                              (restored_full >= MAX_VAL)   ? 18'sd65280 :
                                                             restored_full;

    // Output register, the integer part [15:8] is the output pixel
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid      <= 1'b0;
            out_pixel_q8_0 <= 8'd0;
        end else begin
            out_valid      <= in_valid;
            out_pixel_q8_0 <= restored_clamped[15:8];
        end
    end

endmodule
