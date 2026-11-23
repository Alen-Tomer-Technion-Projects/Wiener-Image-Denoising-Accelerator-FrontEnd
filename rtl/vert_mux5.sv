// File      : vert_mux5.sv
// Module    : vert_mux5
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   Vertical (top and bottom) border handling. Takes the five row taps from
//   the line buffer chain and, when the window centre is on one of the two
//   outer rows of the image, replaces the rows that fall outside the image
//   with their mirror about the window centre row.
//
//   Edge flag    Missing rows    Replacement
//   top0         -2, -1          -2 <= +2,  -1 <= +1
//   top1         -2              -2 <= +2
//   bottom0      +1, +2          +2 <= -2,  +1 <= -1
//   bottom1      +2              +2 <= -2
//   none         nothing         straight through
//
// Timing
//   Combinational select, then one register stage on all five outputs.
//   Latency is 1 clock. The registers are free running (no enable).
//
// Ports
//   clk         in   1    Clock, rising edge
//   rst_n       in   1    Asynchronous active low reset
//   top0        in   1    Centre row is image row 0
//   top1        in   1    Centre row is image row 1
//   bottom1     in   1    Centre row is image row H-2
//   bottom0     in   1    Centre row is image row H-1
//   v0_row_p2   in   DW   Row +2 tap (raw input stream)
//   v1_row_p1   in   DW   Row +1 tap (line buffer 0 output)
//   v2_row_0    in   DW   Row  0 tap (line buffer 1 output, centre row)
//   v3_row_m1   in   DW   Row -1 tap (line buffer 2 output)
//   v4_row_m2   in   DW   Row -2 tap (line buffer 3 output)
//   row_m2      out  DW   Window row -2 after border handling
//   row_m1      out  DW   Window row -1 after border handling
//   row_0       out  DW   Window row  0 (always the centre row)
//   row_p1      out  DW   Window row +1 after border handling
//   row_p2      out  DW   Window row +2 after border handling

module vert_mux5 #(
    parameter int DW = 8
)(
    input  logic           clk,
    input  logic           rst_n,

    // Edge flags from the row FSM in wiener_top
    input  logic           top0,
    input  logic           top1,
    input  logic           bottom1,
    input  logic           bottom0,

    // Row taps from the line buffer chain
    input  logic [DW-1:0]  v0_row_p2,
    input  logic [DW-1:0]  v1_row_p1,
    input  logic [DW-1:0]  v2_row_0,
    input  logic [DW-1:0]  v3_row_m1,
    input  logic [DW-1:0]  v4_row_m2,

    // Registered window column, top to bottom
    output logic [DW-1:0]  row_m2,
    output logic [DW-1:0]  row_m1,
    output logic [DW-1:0]  row_0,
    output logic [DW-1:0]  row_p1,
    output logic [DW-1:0]  row_p2
);

    // Combinational version of the outputs, before the register
    logic [DW-1:0] row_m2_c, row_m1_c, row_0_c, row_p1_c, row_p2_c;

    always_comb begin
        // Default: interior row, every tap goes straight through
        row_m2_c = v4_row_m2;
        row_m1_c = v3_row_m1;
        row_0_c  = v2_row_0;
        row_p1_c = v1_row_p1;
        row_p2_c = v0_row_p2;

        // Only one flag can be active at a time (they come from one FSM),
        // the priority order below is just for synthesis.
        if (top0) begin
            // Rows -2 and -1 are above the image, mirror them from +2 and +1
            row_m2_c = v0_row_p2;
            row_m1_c = v1_row_p1;
        end
        else if (top1) begin
            // Only row -2 is above the image, mirror it from +2
            row_m2_c = v0_row_p2;
        end
        else if (bottom0) begin
            // Rows +1 and +2 are below the image, mirror them from -1 and -2
            row_p2_c = v4_row_m2;
            row_p1_c = v3_row_m1;
        end
        else if (bottom1) begin
            // Only row +2 is below the image, mirror it from -2
            row_p2_c = v4_row_m2;
        end
    end

    // Output register, gives a clean registered column to the window
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_m2 <= '0;
            row_m1 <= '0;
            row_0  <= '0;
            row_p1 <= '0;
            row_p2 <= '0;
        end else begin
            row_m2 <= row_m2_c;
            row_m1 <= row_m1_c;
            row_0  <= row_0_c;
            row_p1 <= row_p1_c;
            row_p2 <= row_p2_c;
        end
    end

endmodule
