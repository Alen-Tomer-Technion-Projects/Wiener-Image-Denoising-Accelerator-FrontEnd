// File      : col_reflect_block.sv
// Module    : col_reflect_block
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   Horizontal (left and right) border handling for one window column.
//   Chooses, for all five rows at once, between the normal column and its
//   mirror about the window centre column, then registers the result.
//   wiener_top uses four of these, one per non centre column (-2, -1, +1, +2).
//
// Timing
//   Combinational select, then one register stage with clock enable.
//   Latency is 1 enabled clock.
//
// Ports
//   clk          in   1        Clock, rising edge
//   rst_n        in   1        Asynchronous active low reset
//   sel_reflect  in   1        1 = output the reflected column, 0 = normal
//   en           in   1        Register enable (window shift strobe)
//   normal       in   5xDW     Normal column, index 0 = top row
//   reflect      in   5xDW     Mirrored column, index 0 = top row
//   out_col      out  5xDW     Registered selected column

module col_reflect_block #(
    parameter int DW = 8
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sel_reflect,
    input  logic               en,
    input  logic [4:0][DW-1:0] normal,
    input  logic [4:0][DW-1:0] reflect,
    output logic [4:0][DW-1:0] out_col
);

    // Selected column before the register
    logic [4:0][DW-1:0] out_col_c;

    // One 2:1 mux per row of the column, all driven by the same select
    genvar i;
    generate
        for (i = 0; i < 5; i++) begin : g_row_mux
            assign out_col_c[i] = sel_reflect ? reflect[i] : normal[i];
        end
    endgenerate

    // Output register, updates only when the window shifts
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_col <= '0;
        end else if (en) begin
            out_col <= out_col_c;
        end
    end

endmodule
