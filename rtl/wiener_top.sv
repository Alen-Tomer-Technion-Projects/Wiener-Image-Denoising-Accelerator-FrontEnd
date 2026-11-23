// File      : wiener_top.sv
// Module    : wiener_top
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   Top level of the streaming adaptive Wiener filter. Accepts one 8 bit
//   grayscale pixel per clock in raster order and produces one filtered
//   pixel per clock after the pipeline fills.
//
// Datapath (see docs/ARCHITECTURE.md for the block diagram)
//   Section 1   Input registers          all primary inputs are registered once
//   Section 2   Config shift register    24 bit noise variance, Q16.8, MSB first
//   Section 3   Test circuits            cfg_data through an inverter / buffer
//   Section 4   Line buffers             4 x delay_line give 5 vertical taps
//   Section 5   Border FSMs              column and row position state machines
//   Section 6   Vertical mux             top / bottom mirroring (vert_mux5)
//   Section 7   5x5 window               sliding window (window5x5)
//   Section 8   Horizontal mux           left / right mirroring (col_reflect_block)
//   Section 9   Statistics               local mean and variance (stats_calc_5x5)
//   Section 10  Centre pixel delay       aligns the noisy pixel with the stats
//   Section 11  Wiener core              gain and output pixel (wiener_core)
//   Section 12  Output registers         out_valid / out_pixel
//   Section 13  Debug observation        FSM states and pipeline valids
//   Section 14  DFT scan tie offs        replaced by insert_dft in synthesis
//
// Interface rules
//   The input stream must have no idle cycles inside a frame, because the
//   line buffers shift every clock. mode_3x3 must be static during a frame.
//   Load the noise variance (24 cfg_en cycles) before streaming a frame.
//
// Ports
//   Name                   Dir  Width    Description
//   clk                    in   1        Clock, rising edge
//   rst_n                  in   1        Asynchronous active low reset
//   mode_3x3               in   1        1 = 3x3 statistics, 0 = 5x5 statistics
//   in_valid               in   1        in_pixel is valid
//   in_pixel               in   PIXEL_W  Noisy input pixel
//   cfg_en                 in   1        Shift cfg_data into the noise register
//   cfg_data               in   1        Serial noise variance bit, MSB first
//                                        (also drives the two test circuits)
//   out_valid              out  1        out_pixel is valid
//   out_pixel              out  PIXEL_W  Filtered output pixel
//   col_state_e            out  3        Column FSM state (0 L0, 1 L1, 2 MID, 3 R1, 4 R0)
//   row_state_e            out  3        Row FSM state (0 T0, 1 T1, 2 MID, 3 B1, 4 B0)
//   line_buffer_valid_out  out  1        Window shift strobe (v2_valid_r)
//   window_valid_out       out  1        Valid into the statistics block
//   stats_valid_out        out  1        Valid into the Wiener core
//   test_inv_out           out  1        ~cfg_data delayed by 3 clocks
//   test_ff_q              out  1        cfg_data delayed by 3 clocks
//   scan_en                in   1        Scan enable (unused in RTL)
//   scan_in1, scan_in2     in   1        Scan chain inputs (unused in RTL)
//   scan_out1, scan_out2   out  1        Scan chain outputs (tied to 0 in RTL)

module wiener_top #(
    parameter IMG_WIDTH  = 512,   // Image width in pixels (columns)
    parameter IMG_HEIGHT = 512,   // Image height in pixels (rows)
    parameter PIXEL_W    = 8      // Pixel width (8 bit grayscale)
)(
    // Clock and reset
    input  logic                    clk,
    input  logic                    rst_n,

    // Mode select
    input  logic                    mode_3x3,

    // Pixel input stream
    input  logic                    in_valid,
    input  logic [PIXEL_W-1:0]      in_pixel,

    // Serial configuration interface
    input  logic                    cfg_en,
    input  logic                    cfg_data,

    // Pixel output stream
    output logic                    out_valid,
    output logic [PIXEL_W-1:0]      out_pixel,

    // Debug: FSM state observation (direct from the state registers)
    output wire  [2:0]              col_state_e,
    output wire  [2:0]              row_state_e,

    // Debug: pipeline valid observation (direct from existing registers)
    output wire                     line_buffer_valid_out,
    output wire                     window_valid_out,
    output wire                     stats_valid_out,

    // Test circuit outputs
    output logic                    test_inv_out,
    output logic                    test_ff_q,

    // DFT scan interface (connected by insert_dft during synthesis)
    input  logic                    scan_en,
    input  logic                    scan_in1,
    input  logic                    scan_in2,
    output logic                    scan_out1,
    output logic                    scan_out2
);

    // Section 1: Input registers
    // Every primary input is registered once before it is used.
    // The two test registers sample the raw cfg_data pin (shared test input,
    // there are no dedicated test input pins in this version).

    logic                    in_valid_r;
    logic [PIXEL_W-1:0]      in_pixel_r;
    logic                    cfg_en_r;
    logic                    cfg_data_r;
    logic                    test_in_inv_r;
    logic                    test_in_ff_d_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid_r     <= 1'b0;
            in_pixel_r     <= '0;
            cfg_en_r       <= 1'b0;
            cfg_data_r     <= 1'b0;
            test_in_inv_r  <= 1'b0;
            test_in_ff_d_r <= 1'b0;
        end else begin
            in_valid_r     <= in_valid;
            in_pixel_r     <= in_pixel;
            cfg_en_r       <= cfg_en;
            cfg_data_r     <= cfg_data;
            test_in_inv_r  <= cfg_data;
            test_in_ff_d_r <= cfg_data;
        end
    end

    // Section 2: Configuration shift register
    // While cfg_en_r is high one bit is shifted in per clock, MSB first.
    // After 24 bits noise_var_reg holds the noise variance in Q16.8.

    logic [23:0] noise_var_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_var_reg <= 24'd0;
        end else if (cfg_en_r) begin
            noise_var_reg <= {noise_var_reg[22:0], cfg_data_r};
        end
    end

    // Convert the noise variance to the core format:
    // Q16.8 -> drop 4 fraction bits -> Q16.4 -> saturate to 18 bits -> Q14.4
    wire [19:0] noise_q16_4_c = noise_var_reg[23:4];
    wire [17:0] noise_q14_4_c = (|noise_q16_4_c[19:18]) ? 18'h3FFFF : noise_q16_4_c[17:0];

    // Section 3: Test circuits
    // Two independent 2 stage paths after the input register:
    //   test_inv_out = inverted cfg_data, 3 clocks after the pin
    //   test_ff_q    = cfg_data,          3 clocks after the pin

    logic test_inv_out_r;
    logic test_ff_q_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_inv_out_r <= 1'b0;
            test_ff_q_r    <= 1'b0;
        end else begin
            test_inv_out_r <= ~test_in_inv_r;   // Inverter stage
            test_ff_q_r    <= test_in_ff_d_r;   // Plain flip flop stage
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_inv_out <= 1'b0;
            test_ff_q    <= 1'b0;
        end else begin
            test_inv_out <= test_inv_out_r;     // Output register
            test_ff_q    <= test_ff_q_r;        // Output register
        end
    end

    // Section 4: Line buffers
    // Four delay lines of IMG_WIDTH stages each. Tap vK is the input stream
    // delayed by K rows, so v0 is the newest row (+2 relative to the centre)
    // and v4 is the oldest row (-2). v2 is the window centre row.

    logic                 v0_valid, v1_valid, v2_valid, v3_valid, v4_valid;
    logic [PIXEL_W-1:0]   v0_pixel, v1_pixel, v2_pixel, v3_pixel, v4_pixel;

    assign v0_valid = in_valid_r;
    assign v0_pixel = in_pixel_r;

    delay_line #(.DEPTH(IMG_WIDTH), .DW(PIXEL_W)) u_lb0 (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (v0_valid),
        .in_data   (v0_pixel),
        .out_valid (v1_valid),
        .out_data  (v1_pixel)
    );

    delay_line #(.DEPTH(IMG_WIDTH), .DW(PIXEL_W)) u_lb1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (v1_valid),
        .in_data   (v1_pixel),
        .out_valid (v2_valid),
        .out_data  (v2_pixel)
    );

    delay_line #(.DEPTH(IMG_WIDTH), .DW(PIXEL_W)) u_lb2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (v2_valid),
        .in_data   (v2_pixel),
        .out_valid (v3_valid),
        .out_data  (v3_pixel)
    );

    delay_line #(.DEPTH(IMG_WIDTH), .DW(PIXEL_W)) u_lb3 (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (v3_valid),
        .in_data   (v3_pixel),
        .out_valid (v4_valid),
        .out_data  (v4_pixel)
    );

    // The vertical mux registers its outputs, so the centre row valid is
    // delayed by one clock to match. v2_valid_r is the window shift strobe
    // and the enable for everything from here to the statistics block.
    logic v2_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v2_valid_r <= 1'b0;
        else        v2_valid_r <= v2_valid;
    end

    // Section 5: Border FSMs
    // The column FSM advances once per window shift and walks
    //   L0 -> L1 -> MID (IMG_WIDTH-4 shifts) -> R1 -> R0 -> L0 ...
    // The row FSM advances once per column wrap (in R0) and walks
    //   T0 -> T1 -> MID (IMG_HEIGHT-4 rows) -> B1 -> B0 -> T0 ...
    // Suffix 0 is the outermost row / column, suffix 1 the next one in.

    typedef enum logic [2:0] {
        COL_L0,    // 0: first column
        COL_L1,    // 1: second column
        COL_MID,   // 2: interior columns
        COL_R1,    // 3: second to last column
        COL_R0     // 4: last column
    } col_state_t;

    typedef enum logic [2:0] {
        ROW_T0,    // 0: first row
        ROW_T1,    // 1: second row
        ROW_MID,   // 2: interior rows
        ROW_B1,    // 3: second to last row
        ROW_B0     // 4: last row
    } row_state_t;

    col_state_t  col_state;
    row_state_t  row_state;

    // Down counters, only used while the FSM is in its MID state
    logic [15:0] col_mid_rem;
    logic [15:0] row_mid_rem;

    // Edge flags decoded from the states
    logic left0, left1, right1, right0;
    logic top0,  top1,  bottom1, bottom0;

    always_comb begin
        left0   = (col_state == COL_L0);
        left1   = (col_state == COL_L1);
        right1  = (col_state == COL_R1);
        right0  = (col_state == COL_R0);
        top0    = (row_state == ROW_T0);
        top1    = (row_state == ROW_T1);
        bottom1 = (row_state == ROW_B1);
        bottom0 = (row_state == ROW_B0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset to the top left corner of the frame
            col_state   <= COL_L0;
            row_state   <= ROW_T0;
            col_mid_rem <= IMG_WIDTH  - 16'd4;
            row_mid_rem <= IMG_HEIGHT - 16'd4;
        end else if (v2_valid_r) begin
            case (col_state)

                COL_L0: begin
                    col_state <= COL_L1;
                end

                COL_L1: begin
                    // Load the interior column count on entry to MID
                    col_mid_rem <= IMG_WIDTH - 16'd4;
                    col_state   <= COL_MID;
                end

                COL_MID: begin
                    // Leave MID when the count runs out
                    if (col_mid_rem <= 16'd1) begin
                        col_state <= COL_R1;
                    end
                    col_mid_rem <= col_mid_rem - 16'd1;
                end

                COL_R1: begin
                    col_state <= COL_R0;
                end

                COL_R0: begin
                    // End of a row: wrap the column FSM and advance the row FSM
                    col_state <= COL_L0;

                    case (row_state)
                        ROW_T0: begin
                            row_state <= ROW_T1;
                        end

                        ROW_T1: begin
                            // Load the interior row count on entry to MID
                            row_mid_rem <= IMG_HEIGHT - 16'd4;
                            row_state   <= ROW_MID;
                        end

                        ROW_MID: begin
                            if (row_mid_rem <= 16'd1) begin
                                row_state <= ROW_B1;
                            end
                            row_mid_rem <= row_mid_rem - 16'd1;
                        end

                        ROW_B1: begin
                            row_state <= ROW_B0;
                        end

                        ROW_B0: begin
                            // End of frame
                            row_state <= ROW_T0;
                        end

                        default: begin
                            row_state <= ROW_T0;
                        end
                    endcase
                end

                default: begin
                    col_state <= COL_L0;
                end
            endcase
        end
    end

    // Section 6: Vertical mux (top / bottom mirroring)

    logic [PIXEL_W-1:0] row_m2, row_m1, row_0, row_p1, row_p2;

    vert_mux5 #(.DW(PIXEL_W)) u_vert_mux (
        .clk       (clk),
        .rst_n     (rst_n),
        .top0      (top0),
        .top1      (top1),
        .bottom1   (bottom1),
        .bottom0   (bottom0),
        .v0_row_p2 (v0_pixel),   // Row +2, input stream
        .v1_row_p1 (v1_pixel),   // Row +1, line buffer 0
        .v2_row_0  (v2_pixel),   // Row  0, line buffer 1 (centre)
        .v3_row_m1 (v3_pixel),   // Row -1, line buffer 2
        .v4_row_m2 (v4_pixel),   // Row -2, line buffer 3
        .row_m2    (row_m2),
        .row_m1    (row_m1),
        .row_0     (row_0),
        .row_p1    (row_p1),
        .row_p2    (row_p2)
    );

    // Section 7: 5x5 sliding window

    logic                          win_valid_raw;      // Sticky "window filled" flag
    logic [2:0]                    win_valid_pipe;     // 3 stage valid shift register
    logic                          win_valid_aligned;  // Valid into the statistics block
    logic [4:0][4:0][PIXEL_W-1:0]  win;                // win[row][col]

    window5x5 #(.DW(PIXEL_W)) u_window (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (v2_valid_r),
        .row_m2    (row_m2),
        .row_m1    (row_m1),
        .row_0     (row_0),
        .row_p1    (row_p1),
        .row_p2    (row_p2),
        .win_shift (win_valid_raw),
        .win       (win)
    );

    // Delay the window valid by three window shifts so it lines up with the
    // registered horizontal mux outputs.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_valid_pipe <= 3'b0;
        end else if (v2_valid_r) begin
            win_valid_pipe <= {win_valid_pipe[1:0], win_valid_raw};
        end
    end

    assign win_valid_aligned = win_valid_pipe[2];

    // Section 8: Horizontal mux (left / right mirroring)
    // Each non centre column has a normal and a mirrored version (mirror
    // about the centre column). The column edge flags are delayed by three
    // window shifts so they match the pixel sitting in the window centre.

    logic [4:0][PIXEL_W-1:0] col_m2_norm, col_m2_refl;
    logic [4:0][PIXEL_W-1:0] col_m1_norm, col_m1_refl;
    logic [4:0][PIXEL_W-1:0] col_0;
    logic [4:0][PIXEL_W-1:0] col_p1_norm, col_p1_refl;
    logic [4:0][PIXEL_W-1:0] col_p2_norm, col_p2_refl;

    genvar r_idx;
    generate
        for (r_idx = 0; r_idx < 5; r_idx++) begin : g_cols
            assign col_m2_norm[r_idx] = win[r_idx][0];   // Column -2
            assign col_m2_refl[r_idx] = win[r_idx][4];   // Mirror of -2 is +2
            assign col_m1_norm[r_idx] = win[r_idx][1];   // Column -1
            assign col_m1_refl[r_idx] = win[r_idx][3];   // Mirror of -1 is +1
            assign col_0[r_idx]       = win[r_idx][2];   // Centre column, never mirrored
            assign col_p1_norm[r_idx] = win[r_idx][3];   // Column +1
            assign col_p1_refl[r_idx] = win[r_idx][1];   // Mirror of +1 is -1
            assign col_p2_norm[r_idx] = win[r_idx][4];   // Column +2
            assign col_p2_refl[r_idx] = win[r_idx][0];   // Mirror of +2 is -2
        end
    endgenerate

    // Column edge flags delayed by 1, 2 and 3 window shifts
    logic left0_r,  left1_r,  right1_r,  right0_r;
    logic left0_r2, left1_r2, right1_r2, right0_r2;
    logic left0_r3, left1_r3, right1_r3, right0_r3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            left0_r  <= 1'b0;  left1_r  <= 1'b0;  right1_r  <= 1'b0;  right0_r  <= 1'b0;
            left0_r2 <= 1'b0;  left1_r2 <= 1'b0;  right1_r2 <= 1'b0;  right0_r2 <= 1'b0;
            left0_r3 <= 1'b0;  left1_r3 <= 1'b0;  right1_r3 <= 1'b0;  right0_r3 <= 1'b0;
        end else if (v2_valid_r) begin
            // Stage 1: sample the FSM decode
            left0_r  <= left0;     left1_r  <= left1;     right1_r  <= right1;     right0_r  <= right0;
            // Stage 2
            left0_r2 <= left0_r;   left1_r2 <= left1_r;   right1_r2 <= right1_r;   right0_r2 <= right0_r;
            // Stage 3: aligned with the window centre
            left0_r3 <= left0_r2;  left1_r3 <= left1_r2;  right1_r3 <= right1_r2;  right0_r3 <= right0_r2;
        end
    end

    // Which columns fall outside the image for the current centre column
    logic sel_m2, sel_m1, sel_p1, sel_p2;

    always_comb begin
        sel_m2 = left0_r3 || left1_r3;    // Column -2 is outside in L0 and L1
        sel_m1 = left0_r3;                // Column -1 is outside only in L0
        sel_p1 = right0_r3;               // Column +1 is outside only in R0
        sel_p2 = right0_r3 || right1_r3;  // Column +2 is outside in R1 and R0
    end

    // Selected (and registered) window columns
    logic [4:0][PIXEL_W-1:0] col_m2, col_m1, col_p1, col_p2;
    logic [4:0][PIXEL_W-1:0] col_0_d;

    col_reflect_block #(.DW(PIXEL_W)) u_col_m2 (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (v2_valid_r),
        .sel_reflect (sel_m2),
        .normal      (col_m2_norm),
        .reflect     (col_m2_refl),
        .out_col     (col_m2)
    );

    col_reflect_block #(.DW(PIXEL_W)) u_col_m1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (v2_valid_r),
        .sel_reflect (sel_m1),
        .normal      (col_m1_norm),
        .reflect     (col_m1_refl),
        .out_col     (col_m1)
    );

    col_reflect_block #(.DW(PIXEL_W)) u_col_p1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (v2_valid_r),
        .sel_reflect (sel_p1),
        .normal      (col_p1_norm),
        .reflect     (col_p1_refl),
        .out_col     (col_p1)
    );

    col_reflect_block #(.DW(PIXEL_W)) u_col_p2 (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (v2_valid_r),
        .sel_reflect (sel_p2),
        .normal      (col_p2_norm),
        .reflect     (col_p2_refl),
        .out_col     (col_p2)
    );

    // The centre column has no mux, it is only registered to keep the same
    // latency as the other four columns. Note: this register has no enable.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) col_0_d <= '0;
        else        col_0_d <= col_0;
    end

    // Section 9: Local statistics (mean and variance)

    logic        stats_valid;
    logic [15:0] mu_q8_8;
    logic [17:0] var_q14_4;

    stats_calc_5x5 #(.DW(PIXEL_W)) u_stats (
        .clk            (clk),
        .rst_n          (rst_n),
        .stats_in_valid (win_valid_aligned),
        .mode_3x3       (mode_3x3),

        // Port name = p_<row offset>_<column offset>, array index = row
        .p_m2_m2 (col_m2[0]), .p_m2_m1 (col_m1[0]), .p_m2_0 (col_0_d[0]), .p_m2_p1 (col_p1[0]), .p_m2_p2 (col_p2[0]),
        .p_m1_m2 (col_m2[1]), .p_m1_m1 (col_m1[1]), .p_m1_0 (col_0_d[1]), .p_m1_p1 (col_p1[1]), .p_m1_p2 (col_p2[1]),
        .p_0_m2  (col_m2[2]), .p_0_m1  (col_m1[2]), .p_0_0  (col_0_d[2]), .p_0_p1  (col_p1[2]), .p_0_p2  (col_p2[2]),
        .p_p1_m2 (col_m2[3]), .p_p1_m1 (col_m1[3]), .p_p1_0 (col_0_d[3]), .p_p1_p1 (col_p1[3]), .p_p1_p2 (col_p2[3]),
        .p_p2_m2 (col_m2[4]), .p_p2_m1 (col_m1[4]), .p_p2_0 (col_0_d[4]), .p_p2_p1 (col_p1[4]), .p_p2_p2 (col_p2[4]),

        .out_valid      (stats_valid),
        .mu_q8_8        (mu_q8_8),
        .var_q14_4      (var_q14_4)
    );

    // Section 10: Centre pixel delay
    // The statistics block has 2 clocks of latency, so the noisy centre pixel
    // is delayed by 2 clocks to arrive at the Wiener core together with them.

    logic [PIXEL_W-1:0] center_pix_r;
    logic [PIXEL_W-1:0] center_pix_r2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            center_pix_r  <= '0;
            center_pix_r2 <= '0;
        end else begin
            center_pix_r  <= col_0_d[2];   // Window centre pixel (row 0, column 0)
            center_pix_r2 <= center_pix_r;
        end
    end

    // Section 11: Wiener core

    logic       wien_valid;
    logic [7:0] wien_pixel;

    wiener_core u_wiener_core (
        .clk               (clk),
        .rst_n             (rst_n),
        .in_valid          (stats_valid),
        .mu_q8_8           (mu_q8_8),
        .var_q14_4         (var_q14_4),
        .noise_q14_4       (noise_q14_4_c),
        .center_pixel_q8_0 (center_pix_r2),
        .out_valid         (wien_valid),
        .out_pixel_q8_0    (wien_pixel)
    );

    // Section 12: Output registers

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_pixel <= '0;
        end else begin
            out_valid <= wien_valid;
            out_pixel <= wien_pixel;
        end
    end

    // Section 13: Debug observation
    // Plain wires from existing registers, no extra flops and no extra delay.

    assign col_state_e           = col_state;
    assign row_state_e           = row_state;
    assign line_buffer_valid_out = v2_valid_r;
    assign window_valid_out      = win_valid_aligned;
    assign stats_valid_out       = stats_valid;

    // Section 14: DFT scan tie offs
    // RTL placeholder, insert_dft reconnects these during synthesis.

    assign scan_out1 = 1'b0;
    assign scan_out2 = 1'b0;

endmodule
