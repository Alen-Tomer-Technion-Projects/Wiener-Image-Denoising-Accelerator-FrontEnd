// File      : tb_golden.sv
// Module    : tb_golden
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   Self checking testbench. Streams FRAMES frames from in.hex through
//   wiener_top and compares every output pixel with expected.hex, which
//   golden_model.py writes with the bit exact fixed point model.
//
//   Every out_valid cycle is captured (no cap), so the test also catches
//   missing pixels at the end of a frame and extra pixels after it.
//
// Parameters (set with -P from run_golden.py)
//   W, H       Image size
//   FRAMES     Number of frames
//   GAP        Idle clocks between frames (0 = back to back)
//   MODE_3X3   Statistics mode
//   NOISE      Noise variance, Q16.8 integer
//   DIR        Folder holding in.hex and expected.hex
//
// Output
//   One line starting with RESULT, read by run_golden.py

`timescale 1ns/1ps

module tb_golden;
    parameter int    W        = 8;
    parameter int    H        = 8;
    parameter int    FRAMES   = 2;
    parameter int    GAP      = 0;
    parameter int    MODE_3X3 = 0;
    parameter int    NOISE    = 51200;
    parameter string DIR      = ".";

    localparam int N_PIX   = W * H;
    localparam int N_TOTAL = N_PIX * FRAMES;

    // Clock and DUT signals
    logic       clk = 1'b0;
    logic       rst_n = 1'b0;
    logic       in_valid = 1'b0;
    logic [7:0] in_pixel = '0;
    logic       cfg_en = 1'b0;
    logic       cfg_data = 1'b0;
    wire        out_valid;
    wire  [7:0] out_pixel;

    always #5 clk = ~clk;

    wiener_top #(.IMG_WIDTH(W), .IMG_HEIGHT(H)) dut (
        .clk(clk), .rst_n(rst_n), .mode_3x3(MODE_3X3[0]),
        .in_valid(in_valid), .in_pixel(in_pixel),
        .cfg_en(cfg_en), .cfg_data(cfg_data),
        .out_valid(out_valid), .out_pixel(out_pixel),
        .col_state_e(), .row_state_e(),
        .line_buffer_valid_out(), .window_valid_out(), .stats_valid_out(),
        .test_inv_out(), .test_ff_q(),
        .scan_en(1'b0), .scan_in1(1'b0), .scan_in2(1'b0), .scan_out1(), .scan_out2()
    );

    // Stimulus and reference data
    logic [7:0] in_mem  [0:N_TOTAL-1];
    logic [7:0] exp_mem [0:N_TOTAL-1];

    // Scoreboard counters
    integer out_count  = 0;   // every out_valid cycle seen
    integer mismatches = 0;   // wrong value among the first N_TOTAL outputs
    integer x_count    = 0;   // outputs that contain X or Z

    // Capture every output and compare it with the next expected pixel
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (out_count < N_TOTAL) begin
                if ($isunknown(out_pixel)) begin
                    x_count = x_count + 1;
                end else if (out_pixel !== exp_mem[out_count]) begin
                    mismatches = mismatches + 1;
                    if (mismatches <= 10)
                        $display("MISMATCH frame %0d y %0d x %0d: got %0d expected %0d",
                                 out_count / N_PIX, (out_count % N_PIX) / W, out_count % W,
                                 out_pixel, exp_mem[out_count]);
                end
            end
            out_count = out_count + 1;
        end
    end

    initial begin
        $readmemh({DIR, "/in.hex"}, in_mem);
        $readmemh({DIR, "/expected.hex"}, exp_mem);

        // Reset
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // Load the noise variance, 24 bits MSB first
        @(negedge clk);
        cfg_en = 1'b1;
        for (int b = 23; b >= 0; b--) begin
            cfg_data = NOISE[b];
            @(negedge clk);
        end
        cfg_en   = 1'b0;
        cfg_data = 1'b0;
        repeat (3) @(negedge clk);

        // Stream the frames, GAP idle clocks between frames
        for (int f = 0; f < FRAMES; f++) begin
            for (int i = 0; i < N_PIX; i++) begin
                in_valid = 1'b1;
                in_pixel = in_mem[f * N_PIX + i];
                @(negedge clk);
            end
            in_valid = 1'b0;
            in_pixel = '0;
            repeat (GAP) @(negedge clk);
        end

        // Drain: wait well past the pipeline latency, then count everything
        repeat (3 * W + 64) @(negedge clk);

        $display("RESULT W=%0d H=%0d FRAMES=%0d GAP=%0d MODE_3X3=%0d expected=%0d got=%0d mismatches=%0d x=%0d %s",
                 W, H, FRAMES, GAP, MODE_3X3, N_TOTAL, out_count, mismatches, x_count,
                 (out_count == N_TOTAL && mismatches == 0 && x_count == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
