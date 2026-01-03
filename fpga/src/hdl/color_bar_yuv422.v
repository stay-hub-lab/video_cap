`include "video_define.v"
//------------------------------------------------------------------------------
// Module: color_bar_yuv422
// Description:
//   生成 YUV422（YCbCr 4:2:2）的彩条测试图（并行视频时序：hs/vs/de/data）。
//
// 输出数据格式（16-bit）：
// - 每个像素输出 1 个 16-bit word：
//   - 偶数像素：data[7:0]=Y, data[15:8]=U(Cb)
//   - 奇数像素：data[7:0]=Y, data[15:8]=V(Cr)
//   对应内存连续字节流为：Y0 U0 Y1 V0 Y2 U2 Y3 V2 ...
//
// 说明：
// - 本模块只负责产生“并行 YUV422”，方便你在 BD 中接到 v_vid_in_axi4s 转成 AXIS。
// - 色彩计算采用近似 BT.601 full-range（用于测试足够）。
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module color_bar_yuv422 (
    input                 clk,
    input                 rst,
    output                hs,
    output                vs,
    output                de,
    output [15:0]         data
);

`ifdef  VIDEO_1280_720
parameter H_ACTIVE = 16'd1280;
parameter H_FP = 16'd110;
parameter H_SYNC = 16'd40;
parameter H_BP = 16'd220;
parameter V_ACTIVE = 16'd720;
parameter V_FP  = 16'd5;
parameter V_SYNC  = 16'd5;
parameter V_BP  = 16'd20;
parameter HS_POL = 1'b1;
parameter VS_POL = 1'b1;
`elsif  VIDEO_800_600
parameter H_ACTIVE = 16'd800;
parameter H_FP = 16'd40;
parameter H_SYNC = 16'd128;
parameter H_BP = 16'd88;
parameter V_ACTIVE = 16'd600;
parameter V_FP  = 16'd1;
parameter V_SYNC  = 16'd4;
parameter V_BP  = 16'd23;
parameter HS_POL = 1'b1;
parameter VS_POL = 1'b1;
`elsif  VIDEO_1920_1080
parameter H_ACTIVE = 16'd1920;
parameter H_FP = 16'd88;
parameter H_SYNC = 16'd44;
parameter H_BP = 16'd148;
parameter V_ACTIVE = 16'd1080;
parameter V_FP  = 16'd4;
parameter V_SYNC  = 16'd5;
parameter V_BP  = 16'd36;
parameter HS_POL = 1'b1;
parameter VS_POL = 1'b1;
`elsif  VIDEO_3840_2160
parameter H_ACTIVE = 16'd3840;
parameter H_FP = 16'd176;
parameter H_SYNC = 16'd88;
parameter H_BP = 16'd296;
parameter V_ACTIVE = 16'd2160;
parameter V_FP  = 16'd8;
parameter V_SYNC  = 16'd10;
parameter V_BP  = 16'd72;
parameter HS_POL = 1'b1;
parameter VS_POL = 1'b1;
`else
parameter H_ACTIVE = 16'd0;
parameter H_FP = 16'd0;
parameter H_SYNC = 16'd0;
parameter H_BP = 16'd0;
parameter V_ACTIVE = 16'd0;
parameter V_FP  = 16'd0;
parameter V_SYNC  = 16'd0;
parameter V_BP  = 16'd0;
parameter HS_POL = 1'b0;
parameter VS_POL = 1'b0;
`endif

parameter H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
parameter V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

reg hs_reg;
reg vs_reg;
reg hs_reg_d0;
reg vs_reg_d0;
reg [15:0] h_cnt;
reg [15:0] v_cnt;
reg [15:0] active_x;
reg [15:0] active_y;
reg h_active;
reg v_active;
reg video_active_d0;
wire video_active = h_active & v_active;

assign hs = hs_reg_d0;
assign vs = vs_reg_d0;
assign de = video_active_d0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        hs_reg_d0 <= 1'b0;
        vs_reg_d0 <= 1'b0;
        video_active_d0 <= 1'b0;
    end else begin
        hs_reg_d0 <= hs_reg;
        vs_reg_d0 <= vs_reg;
        video_active_d0 <= video_active;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst)
        h_cnt <= 16'd0;
    else if (h_cnt == H_TOTAL - 1)
        h_cnt <= 16'd0;
    else
        h_cnt <= h_cnt + 16'd1;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        v_cnt <= 16'd0;
    else if (h_cnt == H_TOTAL - 1) begin
        if (v_cnt == V_TOTAL - 1)
            v_cnt <= 16'd0;
        else
            v_cnt <= v_cnt + 16'd1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst)
        hs_reg <= HS_POL;
    else if (h_cnt == H_FP - 1)
        hs_reg <= ~HS_POL;
    else if (h_cnt == H_FP + H_SYNC - 1)
        hs_reg <= HS_POL;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        vs_reg <= VS_POL;
    else if ((v_cnt == V_FP - 1) && (h_cnt == H_TOTAL - 1))
        vs_reg <= ~VS_POL;
    else if ((v_cnt == V_FP + V_SYNC - 1) && (h_cnt == H_TOTAL - 1))
        vs_reg <= VS_POL;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        h_active <= 1'b0;
    else if (h_cnt == H_FP + H_SYNC + H_BP - 1)
        h_active <= 1'b1;
    else if (h_cnt == H_TOTAL - 1)
        h_active <= 1'b0;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        v_active <= 1'b0;
    else if ((v_cnt == V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_TOTAL - 1))
        v_active <= 1'b1;
    else if ((v_cnt == V_TOTAL - 1) && (h_cnt == H_TOTAL - 1))
        v_active <= 1'b0;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        active_x <= 16'd0;
    else if (h_cnt >= H_FP + H_SYNC + H_BP - 1)
        active_x <= h_cnt - (H_FP + H_SYNC + H_BP - 16'd1);
    else
        active_x <= 16'd0;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        active_y <= 16'd0;
    else if ((v_cnt >= V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_TOTAL - 1))
        active_y <= v_cnt - (V_FP + V_SYNC + V_BP - 16'd1);
    else if (v_cnt < V_FP + V_SYNC + V_BP - 1)
        active_y <= 16'd0;
end

//--------------------------------------------------------------------------
// 8 色彩条（与原 color_bar 一致的色序）
//--------------------------------------------------------------------------
wire [15:0] BAR_W = (H_ACTIVE / 8);
wire [2:0] bar_idx = (BAR_W == 0) ? 3'd0 : (active_x / BAR_W);

// 直接输出 YUV 常量，避免 RGB->YUV 乘法影响时序
// Rec.709 limited-range 8-bit constants (good enough for bring-up)
// white   : Y=235 U=128 V=128
// yellow  : Y=219 U= 16 V=138
// cyan    : Y=188 U=154 V= 16
// green   : Y=173 U= 42 V= 26
// magenta : Y= 78 U=214 V=230
// red     : Y= 63 U=102 V=240
// blue    : Y= 32 U=240 V=118
// black   : Y= 16 U=128 V=128
reg [7:0] y_val;
reg [7:0] u_val;
reg [7:0] v_val;

always @(*) begin
    case (bar_idx)
        3'd0: begin y_val = 8'd235; u_val = 8'd128; v_val = 8'd128; end // white
        3'd1: begin y_val = 8'd219; u_val = 8'd16;  v_val = 8'd138; end // yellow
        3'd2: begin y_val = 8'd188; u_val = 8'd154; v_val = 8'd16;  end // cyan
        3'd3: begin y_val = 8'd173; u_val = 8'd42;  v_val = 8'd26;  end // green
        3'd4: begin y_val = 8'd78;  u_val = 8'd214; v_val = 8'd230; end // magenta
        3'd5: begin y_val = 8'd63;  u_val = 8'd102; v_val = 8'd240; end // red
        3'd6: begin y_val = 8'd32;  u_val = 8'd240; v_val = 8'd118; end // blue
        default: begin y_val = 8'd16; u_val = 8'd128; v_val = 8'd128; end // black
    endcase
end

// 输出：偶数像素输出 {U,Y}；奇数像素输出 {V,Y}
wire x_is_odd = active_x[0];
wire [7:0] c_val = x_is_odd ? v_val : u_val;

reg [15:0] data_reg;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        data_reg <= 16'd0;
    end else if (video_active) begin
        data_reg <= {c_val, y_val};
    end else begin
        data_reg <= 16'd0;
    end
end

assign data = data_reg;

endmodule
