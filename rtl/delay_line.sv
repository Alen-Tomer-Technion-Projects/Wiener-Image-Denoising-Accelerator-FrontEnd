// File      : delay_line.sv
// Module    : delay_line
// Project   : Wiener Image Denoising Accelerator (front end RTL)
//
// Purpose
//   One image line buffer. A plain shift register that delays a pixel and
//   its valid flag by exactly DEPTH clock cycles. Four of these are chained
//   in wiener_top to give five vertically aligned rows of the image.
//
// Timing
//   Latency is DEPTH clocks. The register shifts on EVERY clock, it is not
//   gated by in_valid. This means one row of delay equals one row of pixels
//   only when the input stream has no idle cycles inside a frame.
//
// Ports
//   clk        in   1        Clock, rising edge
//   rst_n      in   1        Asynchronous active low reset
//   in_valid   in   1        Valid flag that travels with the pixel
//   in_data    in   DW       Input pixel
//   out_valid  out  1        in_valid delayed by DEPTH clocks
//   out_data   out  DW       in_data delayed by DEPTH clocks

module delay_line #(
    parameter int DEPTH = 128,   // Number of clocks of delay (image width)
    parameter int DW    = 8      // Data width in bits (bits per pixel)
)(
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [DW-1:0] in_data,
    output logic          out_valid,
    output logic [DW-1:0] out_data
);

    // Storage: one data word and one valid bit per stage
    logic [DW-1:0] shift_reg [0:DEPTH-1];
    logic          valid_reg [0:DEPTH-1];
    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Clear every stage on reset so no stale valid flags leak out
            for (i = 0; i < DEPTH; i++) begin
                shift_reg[i] <= '0;
                valid_reg[i] <= 1'b0;
            end
        end else begin
            // Stage 0 captures the new input
            shift_reg[0] <= in_data;
            valid_reg[0] <= in_valid;
            // Every other stage takes the value of the stage before it
            for (i = 1; i < DEPTH; i++) begin
                shift_reg[i] <= shift_reg[i-1];
                valid_reg[i] <= valid_reg[i-1];
            end
        end
    end

    // The last stage is the delayed output
    assign out_data  = shift_reg[DEPTH-1];
    assign out_valid = valid_reg[DEPTH-1];

endmodule
