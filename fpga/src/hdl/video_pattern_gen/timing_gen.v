//------------------------------------------------------------------------------
// Module: timing_gen
// Description: 视频时序生成器
//              生成标准1080P60时序信号
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module timing_gen (
    input  wire         pix_clk,            // 像素时钟 (148.5MHz)
    input  wire         rst_n,              // 复位 (Active Low)
    input  wire         enable,             // 使能
    
    // 时序输出
    output reg          vsync,              // 场同步
    output reg          hsync,              // 行同步
    output reg          de,                 // 数据使能
    output reg  [11:0]  pixel_x,            // 当前像素X坐标
    output reg  [11:0]  pixel_y,            // 当前像素Y坐标
    output wire         frame_start,        // 帧起始脉冲
    output wire         line_start          // 行起始脉冲
);

    //==========================================================================
    // 1080P60时序参数
    //==========================================================================
    
    // 水平时序
    localparam H_ACTIVE     = 12'd1920;
    localparam H_FP         = 12'd88;
    localparam H_SYNC       = 12'd44;
    localparam H_BP         = 12'd148;
    localparam H_TOTAL      = 12'd2200;
    
    // 垂直时序
    localparam V_ACTIVE     = 12'd1080;
    localparam V_FP         = 12'd4;
    localparam V_SYNC       = 12'd5;
    localparam V_BP         = 12'd36;
    localparam V_TOTAL      = 12'd1125;
    
    // 同步信号位置
    localparam H_SYNC_START = H_ACTIVE + H_FP;
    localparam H_SYNC_END   = H_SYNC_START + H_SYNC;
    localparam V_SYNC_START = V_ACTIVE + V_FP;
    localparam V_SYNC_END   = V_SYNC_START + V_SYNC;
    
    //==========================================================================
    // 计数器
    //==========================================================================
    
    reg [11:0] h_cnt;
    reg [11:0] v_cnt;
    
    // 水平计数器
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 12'd0;
        end else if (enable) begin
            if (h_cnt >= H_TOTAL - 1)
                h_cnt <= 12'd0;
            else
                h_cnt <= h_cnt + 1'b1;
        end else begin
            h_cnt <= 12'd0;
        end
    end
    
    // 垂直计数器
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            v_cnt <= 12'd0;
        end else if (enable) begin
            if (h_cnt >= H_TOTAL - 1) begin
                if (v_cnt >= V_TOTAL - 1)
                    v_cnt <= 12'd0;
                else
                    v_cnt <= v_cnt + 1'b1;
            end
        end else begin
            v_cnt <= 12'd0;
        end
    end
    
    //==========================================================================
    // 同步信号生成
    //==========================================================================
    
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            hsync   <= 1'b0;
            vsync   <= 1'b0;
            de      <= 1'b0;
            pixel_x <= 12'd0;
            pixel_y <= 12'd0;
        end else if (enable) begin
            // HSYNC
            hsync <= (h_cnt >= H_SYNC_START) && (h_cnt < H_SYNC_END);
            
            // VSYNC
            vsync <= (v_cnt >= V_SYNC_START) && (v_cnt < V_SYNC_END);
            
            // DE
            de <= (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);
            
            // 像素坐标
            if (h_cnt < H_ACTIVE)
                pixel_x <= h_cnt;
            else
                pixel_x <= 12'd0;
                
            if (v_cnt < V_ACTIVE)
                pixel_y <= v_cnt;
            else
                pixel_y <= 12'd0;
        end else begin
            hsync   <= 1'b0;
            vsync   <= 1'b0;
            de      <= 1'b0;
            pixel_x <= 12'd0;
            pixel_y <= 12'd0;
        end
    end
    
    //==========================================================================
    // 起始脉冲
    //==========================================================================
    
    assign frame_start = (h_cnt == 12'd0) && (v_cnt == 12'd0);
    assign line_start  = (h_cnt == 12'd0);

endmodule
