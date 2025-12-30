//------------------------------------------------------------------------------
// Module: color_bar_gen
// Description: Color bar pattern generator
//              Generate color bar colors based on pixel position
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module color_bar_gen (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         de,                 // Data enable
    input  wire [11:0]  pixel_x,            // Pixel X coordinate
    input  wire [11:0]  pixel_y,            // Pixel Y coordinate
    input  wire [1:0]   pattern_sel,        // Pattern select
    
    output reg  [7:0]   r_out,              // R component
    output reg  [7:0]   g_out,              // G component
    output reg  [7:0]   b_out               // B component
);

    //==========================================================================
    // Color bar index calculation
    //==========================================================================
    
    wire [2:0] bar_index;
    
    // bar_width = 1920 / 8 = 240
    assign bar_index = pixel_x[10:8];  // Simplified: use upper 3 bits
    
    //==========================================================================
    // Pattern generation
    //==========================================================================
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_out <= 8'd0;
            g_out <= 8'd0;
            b_out <= 8'd0;
        end else if (de) begin
            case (pattern_sel)
                2'b00: begin // Standard 8-color bar
                    case (bar_index)
                        3'd0: begin r_out <= 8'hFF; g_out <= 8'hFF; b_out <= 8'hFF; end // White
                        3'd1: begin r_out <= 8'hFF; g_out <= 8'hFF; b_out <= 8'h00; end // Yellow
                        3'd2: begin r_out <= 8'h00; g_out <= 8'hFF; b_out <= 8'hFF; end // Cyan
                        3'd3: begin r_out <= 8'h00; g_out <= 8'hFF; b_out <= 8'h00; end // Green
                        3'd4: begin r_out <= 8'hFF; g_out <= 8'h00; b_out <= 8'hFF; end // Magenta
                        3'd5: begin r_out <= 8'hFF; g_out <= 8'h00; b_out <= 8'h00; end // Red
                        3'd6: begin r_out <= 8'h00; g_out <= 8'h00; b_out <= 8'hFF; end // Blue
                        3'd7: begin r_out <= 8'h00; g_out <= 8'h00; b_out <= 8'h00; end // Black
                        default: begin r_out <= 8'h00; g_out <= 8'h00; b_out <= 8'h00; end
                    endcase
                end
                
                2'b01: begin // Horizontal grayscale gradient
                    r_out <= pixel_x[10:3];
                    g_out <= pixel_x[10:3];
                    b_out <= pixel_x[10:3];
                end
                
                2'b10: begin // Pure white
                    r_out <= 8'hFF;
                    g_out <= 8'hFF;
                    b_out <= 8'hFF;
                end
                
                2'b11: begin // Checkerboard
                    if (pixel_x[6] ^ pixel_y[6]) begin
                        r_out <= 8'hFF;
                        g_out <= 8'hFF;
                        b_out <= 8'hFF;
                    end else begin
                        r_out <= 8'h00;
                        g_out <= 8'h00;
                        b_out <= 8'h00;
                    end
                end
                
                default: begin
                    r_out <= 8'h00;
                    g_out <= 8'h00;
                    b_out <= 8'h00;
                end
            endcase
        end else begin
            r_out <= 8'd0;
            g_out <= 8'd0;
            b_out <= 8'd0;
        end
    end

endmodule
