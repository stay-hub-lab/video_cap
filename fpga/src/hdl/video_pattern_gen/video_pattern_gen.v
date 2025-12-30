//------------------------------------------------------------------------------
// Module: video_pattern_gen
// Description: 彩条视频测试图案生成器
//              - 支持1080P60 (1920x1080@60Hz)
//              - 支持RGB888和YUV422输出格式
//              - 支持多种测试图案
//
// Timing:
//   - Pixel Clock: 148.5 MHz
//   - H Total: 2200 pixels (1920 active + 280 blanking)
//   - V Total: 1125 lines (1080 active + 45 blanking)
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module video_pattern_gen (
    input  wire         pix_clk,            // 像素时钟 (148.5MHz for 1080p60)
    input  wire         rst_n,              // 复位 (Active Low)
    
    // 控制接口
    input  wire         enable,             // 使能信号
    input  wire [1:0]   pattern_sel,        // 图案选择
                                            // 00: 标准彩条
                                            // 01: 渐变灰度
                                            // 10: 纯色 (白)
                                            // 11: 棋盘格
    input  wire [1:0]   format_sel,         // 格式选择
                                            // 00: RGB888
                                            // 01: YUV422 (YUYV)
    
    // 视频输出
    output reg  [23:0]  vid_data,           // 视频数据 [R/Cr, G/Y, B/Cb]
    output reg          vid_vsync,          // 场同步 (Active High)
    output reg          vid_hsync,          // 行同步 (Active High)
    output reg          vid_de,             // 数据使能
    output reg          vid_field           // 场标识 (逐行扫描固定为0)
);

    //==========================================================================
    // 时序参数定义 (1080P60)
    //==========================================================================
    
    // 水平时序参数
    localparam H_ACTIVE     = 12'd1920;     // 有效像素
    localparam H_FP         = 12'd88;       // 前沿
    localparam H_SYNC       = 12'd44;       // 同步脉冲
    localparam H_BP         = 12'd148;      // 后沿
    localparam H_TOTAL      = 12'd2200;     // 总像素
    
    // 垂直时序参数
    localparam V_ACTIVE     = 12'd1080;     // 有效行数
    localparam V_FP         = 12'd4;        // 前沿
    localparam V_SYNC       = 12'd5;        // 同步脉冲
    localparam V_BP         = 12'd36;       // 后沿
    localparam V_TOTAL      = 12'd1125;     // 总行数
    
    // 同步信号起止位置
    localparam H_SYNC_START = H_ACTIVE + H_FP;
    localparam H_SYNC_END   = H_SYNC_START + H_SYNC;
    localparam V_SYNC_START = V_ACTIVE + V_FP;
    localparam V_SYNC_END   = V_SYNC_START + V_SYNC;
    
    //==========================================================================
    // 彩条颜色定义 (RGB888)
    //==========================================================================
    
    // 标准8色彩条
    localparam [23:0] COLOR_WHITE   = 24'hFFFFFF;
    localparam [23:0] COLOR_YELLOW  = 24'hFFFF00;
    localparam [23:0] COLOR_CYAN    = 24'h00FFFF;
    localparam [23:0] COLOR_GREEN   = 24'h00FF00;
    localparam [23:0] COLOR_MAGENTA = 24'hFF00FF;
    localparam [23:0] COLOR_RED     = 24'hFF0000;
    localparam [23:0] COLOR_BLUE    = 24'h0000FF;
    localparam [23:0] COLOR_BLACK   = 24'h000000;
    
    //==========================================================================
    // 内部信号定义
    //==========================================================================
    
    reg  [11:0] h_cnt;                      // 水平计数器
    reg  [11:0] v_cnt;                      // 垂直计数器
    
    wire        h_active;                   // 水平有效区
    wire        v_active;                   // 垂直有效区
    wire        de_internal;                // 内部数据使能
    
    reg  [23:0] pattern_rgb;                // 图案RGB数据
    wire [23:0] yuv422_data;                // YUV422转换数据
    
    // 彩条区域计算
    wire [2:0]  bar_index;                  // 当前彩条索引 (0-7)
    wire [11:0] bar_width;                  // 彩条宽度 = 1920/8 = 240
    
    //==========================================================================
    // 水平/垂直计数器
    //==========================================================================
    
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
    // 同步信号和数据使能生成
    //==========================================================================
    
    assign h_active = (h_cnt < H_ACTIVE);
    assign v_active = (v_cnt < V_ACTIVE);
    assign de_internal = h_active & v_active;
    
    // 时序信号寄存输出
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            vid_hsync <= 1'b0;
            vid_vsync <= 1'b0;
            vid_de    <= 1'b0;
            vid_field <= 1'b0;
        end else if (enable) begin
            // HSYNC: Active High during H_SYNC period
            vid_hsync <= (h_cnt >= H_SYNC_START) && (h_cnt < H_SYNC_END);
            
            // VSYNC: Active High during V_SYNC period
            vid_vsync <= (v_cnt >= V_SYNC_START) && (v_cnt < V_SYNC_END);
            
            // DE: Active during active video area
            vid_de <= de_internal;
            
            // Field: Always 0 for progressive scan
            vid_field <= 1'b0;
        end else begin
            vid_hsync <= 1'b0;
            vid_vsync <= 1'b0;
            vid_de    <= 1'b0;
            vid_field <= 1'b0;
        end
    end
    
    //==========================================================================
    // 彩条图案生成
    //==========================================================================
    
    assign bar_width = H_ACTIVE >> 3;       // 1920 / 8 = 240
    assign bar_index = h_cnt / bar_width;   // 当前处于哪个彩条
    
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            pattern_rgb <= COLOR_BLACK;
        end else if (enable && de_internal) begin
            case (pattern_sel)
                2'b00: begin // 标准8色彩条
                    case (bar_index)
                        3'd0: pattern_rgb <= COLOR_WHITE;
                        3'd1: pattern_rgb <= COLOR_YELLOW;
                        3'd2: pattern_rgb <= COLOR_CYAN;
                        3'd3: pattern_rgb <= COLOR_GREEN;
                        3'd4: pattern_rgb <= COLOR_MAGENTA;
                        3'd5: pattern_rgb <= COLOR_RED;
                        3'd6: pattern_rgb <= COLOR_BLUE;
                        3'd7: pattern_rgb <= COLOR_BLACK;
                        default: pattern_rgb <= COLOR_BLACK;
                    endcase
                end
                
                2'b01: begin // 渐变灰度
                    // 水平渐变: 0-255 across 1920 pixels
                    pattern_rgb <= {3{h_cnt[10:3]}};
                end
                
                2'b10: begin // 纯白色
                    pattern_rgb <= COLOR_WHITE;
                end
                
                2'b11: begin // 棋盘格 (64x64像素)
                    if ((h_cnt[6] ^ v_cnt[6]) == 1'b0)
                        pattern_rgb <= COLOR_WHITE;
                    else
                        pattern_rgb <= COLOR_BLACK;
                end
                
                default: pattern_rgb <= COLOR_BLACK;
            endcase
        end else begin
            pattern_rgb <= COLOR_BLACK;
        end
    end
    
    //==========================================================================
    // RGB到YUV转换 (可选)
    //==========================================================================
    
    rgb_to_yuv u_rgb_to_yuv (
        .clk        (pix_clk),
        .rst_n      (rst_n),
        .rgb_in     (pattern_rgb),
        .yuv_out    (yuv422_data)
    );
    
    //==========================================================================
    // 输出格式选择
    //==========================================================================
    
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            vid_data <= 24'd0;
        end else if (enable) begin
            case (format_sel)
                2'b00:   vid_data <= pattern_rgb;    // RGB888
                2'b01:   vid_data <= yuv422_data;    // YUV422
                default: vid_data <= pattern_rgb;
            endcase
        end else begin
            vid_data <= 24'd0;
        end
    end

endmodule


//------------------------------------------------------------------------------
// RGB到YUV422转换模块
//------------------------------------------------------------------------------
module rgb_to_yuv (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [23:0]  rgb_in,             // [R, G, B]
    output reg  [23:0]  yuv_out             // [V/U, Y, Y] for YUV422
);

    // RGB分量
    wire [7:0] R = rgb_in[23:16];
    wire [7:0] G = rgb_in[15:8];
    wire [7:0] B = rgb_in[7:0];
    
    // YUV计算 (BT.601标准, 定点运算)
    // Y  =  0.299*R + 0.587*G + 0.114*B
    // Cb = -0.169*R - 0.331*G + 0.500*B + 128
    // Cr =  0.500*R - 0.419*G - 0.081*B + 128
    
    reg [15:0] Y_temp, Cb_temp, Cr_temp;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            Y_temp  <= 16'd0;
            Cb_temp <= 16'd0;
            Cr_temp <= 16'd0;
        end else begin
            // 使用8位定点系数 (x256)
            Y_temp  <= (77 * R + 150 * G + 29 * B) >> 8;
            Cb_temp <= ((-43 * R - 85 * G + 128 * B) >> 8) + 128;
            Cr_temp <= ((128 * R - 107 * G - 21 * B) >> 8) + 128;
        end
    end
    
    // 饱和处理和输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            yuv_out <= 24'd0;
        end else begin
            // 输出格式: [Cb/Cr, Y, Y] 简化为 [Cb, Y, Y]
            yuv_out <= {Cb_temp[7:0], Y_temp[7:0], Y_temp[7:0]};
        end
    end

endmodule
