// File      : window5x5.sv
// Module    : window5x5
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   5x5 sliding window register array. Every valid cycle the whole window
//   shifts one column to the left and the new column (five pixels from
//   vert_mux5) enters on the right, at column index 4.
//
//   Indexing is win[row][col]. Row 0 is the top row (-2), row 4 is the
//   bottom row (+2). Column 0 is the oldest column, column 4 the newest.
//   The window centre pixel is win[2][2].
//
// Timing
//   Registered. The window only changes when in_valid is high.
//   win_shift goes high on the first shift after reset and then STAYS high
//   (it is a "window has been filled at least once" flag, not a per cycle
//   strobe).
//
// Ports
//   clk        in   1          Clock, rising edge
//   rst_n      in   1          Asynchronous active low reset
//   in_valid   in   1          Shift in a new column this cycle
//   row_m2     in   DW         New pixel for window row 0 (row -2)
//   row_m1     in   DW         New pixel for window row 1 (row -1)
//   row_0      in   DW         New pixel for window row 2 (centre row)
//   row_p1     in   DW         New pixel for window row 3 (row +1)
//   row_p2     in   DW         New pixel for window row 4 (row +2)
//   win_shift  out  1          Sticky flag, high after the first shift
//   win        out  5x5xDW     Window contents, win[row][col]

module window5x5 #(
    parameter int DW = 8   // Pixel data width
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    in_valid,
    input  logic [DW-1:0]           row_m2,
    input  logic [DW-1:0]           row_m1,
    input  logic [DW-1:0]           row_0,
    input  logic [DW-1:0]           row_p1,
    input  logic [DW-1:0]           row_p2,

    output logic                    win_shift,
    output logic [4:0][4:0][DW-1:0] win
);

    // Pack the incoming column so the shift can be written as a loop
    logic [4:0][DW-1:0] new_col;
    assign new_col[0] = row_m2;
    assign new_col[1] = row_m1;
    assign new_col[2] = row_0;
    assign new_col[3] = row_p1;
    assign new_col[4] = row_p2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_shift <= 1'b0;
            win       <= '0;
        end else if (in_valid) begin
            // Each row shifts one column to the left (1->0, 2->1, 3->2, 4->3)
            // and its new pixel enters at the rightmost column (index 4).
            // Written as {new, old[4:1]} because the packed row is stored
            // with column 4 as the most significant element.
            // Indices are constants on purpose (Icarus does not accept a
            // loop variable as a packed array index in a nonblocking write).
            win[0] <= {new_col[0], win[0][4:1]};   // Row -2
            win[1] <= {new_col[1], win[1][4:1]};   // Row -1
            win[2] <= {new_col[2], win[2][4:1]};   // Row  0 (centre)
            win[3] <= {new_col[3], win[3][4:1]};   // Row +1
            win[4] <= {new_col[4], win[4][4:1]};   // Row +2
            // Sticky: once the window has shifted it stays marked as filled
            win_shift <= 1'b1;
        end
        // When in_valid is low the window and win_shift hold their values
    end

endmodule
