//------------------------------------------------------------------------------
// Module: axis_yuv422_to_xbgr32
// Description:
//   AXI4-Stream 像素转换器：把“32-bit/word 的 YUYV(YUV422, 2像素/word)”转为 XBGR32（BGR0）。
//
// 输入/输出约定：
// - s_axis_tdata[31:0] 为一个 YUYV word（2 像素/word）：
//   - little-endian 内存字节序为 [Y0, U0, Y1, V0]
//   - 即：Y0=s_axis_tdata[7:0], U0=s_axis_tdata[15:8],
//         Y1=s_axis_tdata[23:16], V0=s_axis_tdata[31:24]
// - m_axis_tdata[31:0] 为一个 XBGR32 像素（BGR0）：
//   - bits: [31:24]=0, [23:16]=R, [15:8]=G, [7:0]=B
//   - little-endian 内存字节序为 [B, G, R, 0]，对应 ffplay 的 bgr0
//
// 时序/握手：
// - 每收到 1 个输入 word，会输出 2 个像素（先输出像素0，再输出像素1）。
// - 本模块内部只做 1-word 缓冲；因此在像素1未输出前，会对上游施加 backpressure。
//   适合“输入每 word 代表 2 像素”的 YUYV 传输链路（输出像素率为输入 word 率的 2 倍）。
//
// 如果你的上游是“16-bit/像素”的 YUV422（常见于 v_vid_in_axi4s 输出 16-bit tdata），请使用：
//   axis_yuv422_16_to_xbgr32.v
//
// 色彩转换：
// - 采用近似 BT.601 full-range（用于测试/显示足够）。
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module axis_yuv422_to_xbgr32 (
    input  wire         aclk,
    input  wire         aresetn,

    // s_axis：YUYV422（2 像素/word）
    input  wire [31:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,

    // m_axis：XBGR32（1 像素/word）
    output wire [31:0]  m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire         m_axis_tuser
);

    function automatic [7:0] clamp_u8;
        input signed [31:0] val;
        begin
            if (val < 0) clamp_u8 = 8'd0;
            else if (val > 255) clamp_u8 = 8'd255;
            else clamp_u8 = val[7:0];
        end
    endfunction

    function automatic [31:0] yuv_to_xbgr32;
        input [7:0] y;
        input [7:0] u;
        input [7:0] v;
        reg signed [31:0] d;
        reg signed [31:0] e;
        reg signed [31:0] r;
        reg signed [31:0] g;
        reg signed [31:0] b;
        begin
            // full-range 近似：
            // R = Y + 1.402*(V-128)
            // G = Y - 0.344*(U-128) - 0.714*(V-128)
            // B = Y + 1.772*(U-128)
            d = $signed({1'b0, u}) - 32'sd128;
            e = $signed({1'b0, v}) - 32'sd128;
            r = $signed({1'b0, y}) + ((32'sd359 * e) >>> 8);
            g = $signed({1'b0, y}) - ((32'sd88 * d + 32'sd183 * e) >>> 8);
            b = $signed({1'b0, y}) + ((32'sd454 * d) >>> 8);
            yuv_to_xbgr32 = {8'h00, clamp_u8(r), clamp_u8(g), clamp_u8(b)};
        end
    endfunction

    // 1-word 输入缓冲 + 两相输出
    reg        have_word;
    reg        phase; // 0=输出像素0，1=输出像素1
    reg [31:0] word_reg;
    reg        last_reg;
    reg        user_reg;

    wire fire_out = m_axis_tvalid && m_axis_tready;

    // 只有当内部没有挂起的输入 word（或已完成两相输出）时才接收新 word
    assign s_axis_tready = (~have_word) || (have_word && phase && fire_out);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            have_word <= 1'b0;
            phase     <= 1'b0;
            word_reg  <= 32'd0;
            last_reg  <= 1'b0;
            user_reg  <= 1'b0;
        end else begin
            // 接收新输入 word（发生在 ready && valid）
            if (s_axis_tready && s_axis_tvalid) begin
                word_reg  <= s_axis_tdata;
                last_reg  <= s_axis_tlast;
                user_reg  <= s_axis_tuser;
                have_word <= 1'b1;
                phase     <= 1'b0;
            end else if (fire_out && have_word) begin
                // 输出像素0 -> 切到像素1；输出像素1 -> 清空 word
                if (!phase) begin
                    phase <= 1'b1;
                end else begin
                    phase     <= 1'b0;
                    have_word <= 1'b0;
                    last_reg  <= 1'b0;
                    user_reg  <= 1'b0;
                end
            end
        end
    end

    // 解包：little-endian bytes [Y0,U0,Y1,V0]
    wire [7:0] y0 = word_reg[7:0];
    wire [7:0] u0 = word_reg[15:8];
    wire [7:0] y1 = word_reg[23:16];
    wire [7:0] v0 = word_reg[31:24];

    // 输出当前相位对应的像素
    assign m_axis_tvalid = have_word;
    assign m_axis_tdata  = phase ? yuv_to_xbgr32(y1, u0, v0) : yuv_to_xbgr32(y0, u0, v0);

    // tuser：只在像素0时透传（一帧只需要在首像素标 SOF）
    assign m_axis_tuser = user_reg && (~phase);

    // tlast：如果输入 word 是行尾（tlast=1），则把 tlast 放在像素1上（避免行尾只输出半个像素对）
    assign m_axis_tlast = last_reg && phase;

endmodule
