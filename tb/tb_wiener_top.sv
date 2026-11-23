// File      : tb_wiener_top.sv
// Module    : tb_wiener_top
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   Full image testbench. Loads a clean and a noisy 512 x 512 image (HEX),
//   loads the noise variance through the serial config port, streams the
//   noisy image through wiener_top twice (5x5 mode, then 3x3 mode), writes
//   the output pixels to text files and prints the SNR of each run.
//
// Plusargs
//   +NOISE_VAR=<real>   Noise variance (required), converted to Q16.8
//   +CLEAN_HEX=<path>   Default clean_image.hex
//   +NOISY_HEX=<path>   Default noisy_image.hex
//   +OUT_5X5=<path>     Default output_pixels_5x5.txt
//   +OUT_3X3=<path>     Default output_pixels_3x3.txt
//
// Note
//   The capture stops after IMG_W * IMG_H pixels per run because out_valid
//   stays high after the end of a frame (see Known issues in README.md).

module tb_wiener_top;
    localparam integer IMG_W = 512;
    localparam integer IMG_H = 512;
    localparam integer N_PIX = IMG_W * IMG_H;   // total number of pixels

    logic clk, rst_n;
    logic in_valid;
    logic [7:0] in_pixel;

    // Config interface signals
    logic cfg_en;
    logic cfg_data;
    logic [23:0] noise_var_q16_8;
    real noise_var_real;

    // Debug outputs (FSM states and pipeline valids)
    wire [2:0] col_state_e, row_state_e;
    wire line_buffer_valid_out, window_valid_out, stats_valid_out;

    // DUT output signals
    logic out_valid;
    logic [7:0] out_pixel;
    logic test_inv_out, test_ff_q;

    // Statistics mode: 0 = 5x5 window statistics, 1 = centre 3x3 statistics
    // (the window and border handling stay 5x5 in both modes)
    logic mode_3x3;

    // Image buffers (to hold test images)
    logic [7:0] clean_buffer [0:N_PIX-1];
    logic [7:0] noisy_buffer [0:N_PIX-1];

    // Arrays to hold image data as integers (for computing error/SNR)
    integer orig_im   [0:N_PIX-1];
    integer noisy_im  [0:N_PIX-1];
    integer restor_im [0:N_PIX-1];

    // Two output files so we save 5x5 and 3x3 results separately
    integer out_file_5x5;
    integer out_file_3x3;

    // Defaults are relative to the project root. Plusargs allow other run folders.
    string clean_hex_path, noisy_hex_path;
    string output_5x5_path, output_3x3_path;

    integer i, in_index, out_index, k;

    // We compute SNR using:
    // num_power = sum(original^2)
    // den_noisy = sum((original - noisy)^2)
    // den_restored = sum((original - restored)^2)
    real num_power = 0;
    real den_noisy = 0;
    real den_restored = 0;

    // Separate SNR results for each run
    real snr_noisy_db;
    real snr_rest_5x5_db;
    real snr_rest_3x3_db;

    // run control so the output capture block knows when a run is active
    logic run_active;

    // Clock generation: 100 MHz clock (10ns period)
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Instantiate the Device Under Test (DUT)
    wiener_top #(
        .IMG_WIDTH(IMG_W),
        .IMG_HEIGHT(IMG_H),
        .PIXEL_W(8)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_pixel(in_pixel),
        .cfg_en(cfg_en), .cfg_data(cfg_data),

        .mode_3x3(mode_3x3),

        .col_state_e(col_state_e), .row_state_e(row_state_e),
        .line_buffer_valid_out(line_buffer_valid_out),
        .window_valid_out(window_valid_out),
        .stats_valid_out(stats_valid_out),
        .scan_en(1'b0), .scan_in1(1'b0), .scan_in2(1'b0),
        .scan_out1(), .scan_out2(),
        .out_valid(out_valid), .out_pixel(out_pixel),
        .test_inv_out(test_inv_out), .test_ff_q(test_ff_q)
    );

    initial begin
        // Initial conditions
        rst_n = 0;
        in_valid = 0;
        in_pixel = 0;
        cfg_en = 0;
        cfg_data = 0;

        // Run control
        run_active = 0;

        // Start in 5x5 mode for the first run
        mode_3x3 = 0;

        // 1) Load image files into buffers
        if (!$value$plusargs("CLEAN_HEX=%s", clean_hex_path))
            clean_hex_path = "clean_image.hex";
        if (!$value$plusargs("NOISY_HEX=%s", noisy_hex_path))
            noisy_hex_path = "noisy_image.hex";
        if (!$value$plusargs("OUT_5X5=%s", output_5x5_path))
            output_5x5_path = "output_pixels_5x5.txt";
        if (!$value$plusargs("OUT_3X3=%s", output_3x3_path))
            output_3x3_path = "output_pixels_3x3.txt";

        $readmemh(clean_hex_path, clean_buffer);
        $readmemh(noisy_hex_path, noisy_buffer);
        if (clean_buffer[0] === 8'bx || noisy_buffer[0] === 8'bx) begin
            $display("ERROR: Hex files not found!");
            $finish;
        end else begin
            $display("SUCCESS: Loaded %s and %s", clean_hex_path, noisy_hex_path);
        end

        // Open output files
        // We keep two files open, and write based on mode_3x3 at the time of output
        out_file_5x5 = $fopen(output_5x5_path, "w");
        if (out_file_5x5 == 0) begin
            $display("Error opening %s", output_5x5_path);
            $finish;
        end

        out_file_3x3 = $fopen(output_3x3_path, "w");
        if (out_file_3x3 == 0) begin
            $display("Error opening %s", output_3x3_path);
            $finish;
        end

        // 3) Prepare buffers and compute input SNR (for reference)
        // We compute these once because the same clean/noisy images are used for both runs
        for (i = 0; i < N_PIX; i++) begin
            orig_im[i]  = clean_buffer[i];
            noisy_im[i] = noisy_buffer[i];

            // Compute total signal power and noise power
            num_power += real'(orig_im[i] * orig_im[i]);
            den_noisy += (real'(orig_im[i]) - real'(noisy_im[i])) ** 2;
        end

        // Compute and print SNR of noisy input once
        if (den_noisy > 0)
            snr_noisy_db = 10.0 * $ln(num_power / den_noisy) / $ln(10.0);

        $display("SNR (Noisy Input):  %f dB", snr_noisy_db);
        // Read noise variance from command line
        if (!$value$plusargs("NOISE_VAR=%f", noise_var_real)) begin
            $display("ERROR: NOISE_VAR not provided!");
            $finish;
        end

        // Convert real variance to Q16.8 fixed-point
        noise_var_q16_8 = $rtoi(noise_var_real * 256.0);

        $display("TB: Using Noise Variance (real) = %f", noise_var_real);
        $display("TB: Using Noise Variance (Q16.8) = %0d", noise_var_q16_8);

        // Run 1: 5x5 mode
        $display("TB: Starting 5x5 run (mode_3x3 = 0)");

        mode_3x3 = 0;

        // Apply reset for a clean start of the run
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // 2) Configuration: Load noise variance into DUT via serial interface
        //noise_var_q16_8 = 24'd320000;  // example noise variance (Q16.8)
        //$display("TB: Using Configured Noise Variance = %0d", noise_var_q16_8);

        @(negedge clk);
        cfg_en = 1;

        // Shift out 24 bits of noise_var_q16_8 (MSB first)
        for (k = 23; k >= 0; k--) begin
            cfg_data = noise_var_q16_8[k];
            @(negedge clk);
        end

        cfg_en = 0;
        cfg_data = 0;
        @(negedge clk);

        // reset output counters and error accumulator for this run
        out_index = 0;
        den_restored = 0;
        run_active = 1;

        // 4) Stream Data: feed the noisy image pixels into the DUT
        $display("TB: Starting Stream...");
        in_index = 0;
        while (in_index < N_PIX) begin
            @(negedge clk);
            in_valid <= 1'b1;
            in_pixel <= noisy_im[in_index][7:0];  // apply next pixel (8-bit)
            in_index++;
        end

        // After all pixels are sent, drop in_valid
        @(negedge clk);
        in_valid <= 0;
        in_pixel <= 0;

        // Wait for all outputs to be received for this run
        wait (out_index == N_PIX);

        // Stop capture for this run
        run_active = 0;

        // Give some extra cycles for any final computations
        repeat (10) @(posedge clk);

        // 6) Final Metrics for 5x5 run
        if (den_restored > 0)
            snr_rest_5x5_db = 10.0 * $ln(num_power / den_restored) / $ln(10.0);

        $display("SNR (HW Restored, 5x5):  %f dB", snr_rest_5x5_db);

        // Run 2: 3x3 stats mode
        // Important: This assumes your pipeline still runs 5x5 window/reflect,
        // and only stats_calc changes behavior using mode_3x3.
        $display("TB: Starting 3x3 run (mode_3x3 = 1)");

        mode_3x3 = 1;

        // Apply reset for a clean start of the run
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Re-load the same config after reset (because noise_var_reg resets)
        $display("TB: Loading Config again for 3x3 run...");
        @(negedge clk);
        cfg_en = 1;

        // Shift out 24 bits of noise_var_q16_8 (MSB first)
        for (k = 23; k >= 0; k--) begin
            cfg_data = noise_var_q16_8[k];
            @(negedge clk);
        end

        cfg_en = 0;
        cfg_data = 0;
        @(negedge clk);

        // reset output counters and error accumulator for this run
        out_index = 0;
        den_restored = 0;
        run_active = 1;

        // Stream the same noisy image again
        $display("TB: Starting Stream...");
        in_index = 0;
        while (in_index < N_PIX) begin
            @(negedge clk);
            in_valid <= 1'b1;
            in_pixel <= noisy_im[in_index][7:0];
            in_index++;
        end

        // After all pixels are sent, drop in_valid
        @(negedge clk);
        in_valid <= 0;
        in_pixel <= 0;

        // Wait for all outputs to be received for this run
        wait (out_index == N_PIX);

        // Stop capture for this run
        run_active = 0;

        // Give some extra cycles for any final computations
        repeat (10) @(posedge clk);

        // Final Metrics for 3x3 run
        if (den_restored > 0)
            snr_rest_3x3_db = 10.0 * $ln(num_power / den_restored) / $ln(10.0);

        $display("SNR (HW Restored, 3x3):  %f dB", snr_rest_3x3_db);

        $finish;
    end

    // Monitor Output: capture output pixels and accumulate error for SNR
    // We reuse restor_im[] as a scratch buffer per run.
    // We also choose the correct output file based on mode_3x3.
    always @(posedge clk) begin
        if (rst_n && run_active && out_valid && out_index < N_PIX) begin
            if (out_pixel === 8'bx) begin
                $display("ERROR: Received 'X' at pixel %0d", out_index);
            end

            restor_im[out_index] = out_pixel;

            // Accumulate squared error for the current run
            den_restored += (real'(orig_im[out_index]) - real'(out_pixel)) ** 2;

            // Write restored pixel to the correct output file for the current mode
            if (mode_3x3)
                $fwrite(out_file_3x3, "%d\n", out_pixel);
            else
                $fwrite(out_file_5x5, "%d\n", out_pixel);

            out_index++;
        end
    end

    // Close output files at end of simulation
    final begin
        $fclose(out_file_5x5);
        $fclose(out_file_3x3);
    end

    
    //  waveforms (for viewing in a waveform viewer, optional)
    
    //initial begin
    //  $dumpfile("wave.fst");
    //  $dumpvars(0, tb_wiener_top);
    //end
    
endmodule
