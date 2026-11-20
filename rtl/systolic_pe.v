
`timescale 1ns / 1ps
module systolic_pe #(
    parameter ACT_WIDTH   = 8,
    parameter WGT_WIDTH   = 8,
    parameter ACC_WIDTH   = 32
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 en,
    input  wire                 clr_acc,
    input  wire signed [ACT_WIDTH-1:0]  in_a,
    input  wire signed [WGT_WIDTH-1:0]  in_b,
    output reg  signed [ACT_WIDTH-1:0]  out_a,
    output reg  signed [WGT_WIDTH-1:0]  out_b,
    output reg  signed [ACC_WIDTH-1:0]  accum_out
);
    wire signed [ACT_WIDTH+WGT_WIDTH-1:0] mult_product;
    assign mult_product = in_a * in_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_a     <= {ACT_WIDTH{1'b0}};
            out_b     <= {WGT_WIDTH{1'b0}};
            accum_out <= {ACC_WIDTH{1'b0}};
        end else begin
            if (en) begin
                out_a <= in_a;
                out_b <= in_b;
                if (clr_acc) begin
                    accum_out <= {{ (ACC_WIDTH-(ACT_WIDTH+WGT_WIDTH)){mult_product[ACT_WIDTH+WGT_WIDTH-1]} }, mult_product};
                end else begin
                    accum_out <= accum_out + {{ (ACC_WIDTH-(ACT_WIDTH+WGT_WIDTH)){mult_product[ACT_WIDTH+WGT_WIDTH-1]} }, mult_product};
                end
            end
        end
    end
endmodule
