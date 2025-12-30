//------------------------------------------------------------------------------
// Module: video_cap_top
// Description: PCIe Video Capture Card Top Module
//              - Target: XC7K480TFFG1156-2
//              - Phase 1: Color bar generator + LED status
//
// Author: Auto-generated
// Date: 2025-12-21
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module video_cap_top (
    //--------------------------------------------------------------------------
    // System Clock
    //--------------------------------------------------------------------------
    input  wire         sys_clk_200m,       // 200MHz oscillator
    input  wire         sys_rst_n,          // System reset (Active Low)
    
    //--------------------------------------------------------------------------
    // LED Status (only 3 LEDs to match available pins)
    //--------------------------------------------------------------------------
    output wire [2:0]   led                 // LED[0]: Heartbeat
                                            // LED[1]: PLL locked
                                            // LED[2]: Frame activity
);

    //==========================================================================
    // Internal signals
    //==========================================================================
    
    // Clock and reset
    wire        sys_clk_200m_buf;
    wire        sys_rst_n_buf;
    
    // Video pixel clock
    wire        vid_pixel_clk;              // 148.5MHz
    wire        vid_clk_200m;               // 200MHz
    wire        vid_pixel_clk_locked;
    
    // Video signals (from color bar generator)
    wire [23:0] vid_data;                   // RGB888 video data
    wire        vid_vsync;                  // Vertical sync
    wire        vid_hsync;                  // Horizontal sync
    wire        vid_de;                     // Data enable
    wire        vid_field;                  // Field ID
    
    // Control signals
    wire        ctrl_enable;
    wire        ctrl_test_mode;
    
    // Heartbeat counter
    reg [26:0]  heartbeat_cnt;
    wire        heartbeat_led;
    
    // Frame counter
    reg [31:0]  frame_count;
    reg         vid_vsync_d1;
    wire        vid_vsync_rising;
    
    //==========================================================================
    // Clock and reset buffers
    //==========================================================================
    
    IBUF ibuf_sys_clk_200m (
        .I(sys_clk_200m),
        .O(sys_clk_200m_buf)
    );
    
    IBUF ibuf_sys_rst_n (
        .I(sys_rst_n),
        .O(sys_rst_n_buf)
    );
    
    //==========================================================================
    // Video pixel clock generation (148.5MHz for 1080p60)
    //==========================================================================
    
    clk_wiz_video u_clk_wiz_video (
        .clk_in1    (sys_clk_200m_buf),
        .resetn     (sys_rst_n_buf),
        .clk_out1   (vid_pixel_clk),        // 148.5MHz
        .clk_out2   (vid_clk_200m),         // 200MHz
        .locked     (vid_pixel_clk_locked)
    );
    
    //==========================================================================
    // Simple control logic (always enabled)
    //==========================================================================
    
    assign ctrl_enable    = 1'b1;
    assign ctrl_test_mode = 1'b1;
    
    //==========================================================================
    // Color bar generator
    //==========================================================================
    
    video_pattern_gen u_video_pattern_gen (
        .pix_clk            (vid_pixel_clk),
        .rst_n              (vid_pixel_clk_locked),
        
        // Control
        .enable             (ctrl_enable & ctrl_test_mode),
        .pattern_sel        (2'b00),        // Default color bar
        .format_sel         (2'b00),        // Default RGB888
        
        // Video output
        .vid_data           (vid_data),
        .vid_vsync          (vid_vsync),
        .vid_hsync          (vid_hsync),
        .vid_de             (vid_de),
        .vid_field          (vid_field)
    );
    
    //==========================================================================
    // Frame counter (for debug)
    //==========================================================================
    
    always @(posedge vid_pixel_clk or negedge vid_pixel_clk_locked) begin
        if (!vid_pixel_clk_locked) begin
            vid_vsync_d1 <= 1'b0;
        end else begin
            vid_vsync_d1 <= vid_vsync;
        end
    end
    
    assign vid_vsync_rising = vid_vsync & ~vid_vsync_d1;
    
    always @(posedge vid_pixel_clk or negedge vid_pixel_clk_locked) begin
        if (!vid_pixel_clk_locked) begin
            frame_count <= 32'd0;
        end else if (vid_vsync_rising) begin
            frame_count <= frame_count + 1'b1;
        end
    end
    
    //==========================================================================
    // Heartbeat LED
    //==========================================================================
    
    always @(posedge vid_pixel_clk or negedge vid_pixel_clk_locked) begin
        if (!vid_pixel_clk_locked) begin
            heartbeat_cnt <= 27'd0;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
        end
    end
    
    // ~0.9Hz blink @ 148.5MHz
    assign heartbeat_led = heartbeat_cnt[26];
    
    //==========================================================================
    // LED output (only 3 LEDs)
    //==========================================================================
    
    assign led[0] = heartbeat_led;           // Heartbeat (clock running)
    assign led[1] = vid_pixel_clk_locked;    // PLL locked
    assign led[2] = frame_count[5];          // Frame count (~1Hz)

endmodule
