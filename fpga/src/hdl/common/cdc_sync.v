//------------------------------------------------------------------------------
// Module: cdc_sync
// Description: Clock Domain Crossing synchronizer for control signals
//              Double-flop synchronizer for slow-changing signals
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module cdc_sync #(
    parameter WIDTH = 1,
    parameter STAGES = 2
)(
    input  wire             clk_dst,        // Destination clock
    input  wire             rst_n,          // Reset (active low)
    input  wire [WIDTH-1:0] sig_in,         // Input signal (source clock domain)
    output wire [WIDTH-1:0] sig_out         // Output signal (destination clock domain)
);

    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_reg [0:STAGES-1];
    
    integer i;
    
    always @(posedge clk_dst or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) begin
                sync_reg[i] <= {WIDTH{1'b0}};
            end
        end else begin
            sync_reg[0] <= sig_in;
            for (i = 1; i < STAGES; i = i + 1) begin
                sync_reg[i] <= sync_reg[i-1];
            end
        end
    end
    
    assign sig_out = sync_reg[STAGES-1];

endmodule
