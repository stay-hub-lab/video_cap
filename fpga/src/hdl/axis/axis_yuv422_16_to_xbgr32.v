//------------------------------------------------------------------------------
// Module: axis_yuv422_16_to_xbgr32
// Description:
//   AXI4-Stream 像素转换器：把“16-bit/像素”的 YUV422 流转换为 XBGR32（BGR0）。
//
// 为什么需要 16-bit 版本：
// - 你在 BD 里用 v_vid_in_axi4s 把并行 YUV422（hs/vs/de/data[15:0]）转成 AXIS 时，
//   很常见的做法是把 AXIS 的 tdata 配成 16-bit（每个像素 1 个 16-bit word）。
// - YUV422 的色度是 2 像素共享一组 U/V，所以 16-bit/像素的常见编码是：
//   - 偶数像素：{U, Y0}
//   - 奇数像素：{V, Y1}
//   这样连续字节流就是：Y0 U0 Y1 V0 Y2 U2 Y3 V2 ...
//
// 输入/输出约定：
// - s_axis_tdata[15:0] 为 1 像素：
//   - data[7:0]  = Y
//   - data[15:8] = 偶数像素为 U；奇数像素为 V
// - m_axis_tdata[31:0] 为 1 像素 XBGR32（BGR0）：
//   - bits: [31:24]=0, [23:16]=R, [15:8]=G, [7:0]=B
//   - little-endian 内存字节序为 [B,G,R,0]，对应 ffplay 的 bgr0
//
// 时序/握手：
// - 由于偶数像素只有 U、奇数像素才带 V，所以必须等到“成对的两个像素”都收到后才能转换。
// - 本模块会缓存 1 对像素（Y0/U + Y1/V），然后输出 2 个 XBGR32 像素（先像素0，再像素1）。
// - 因为只有 1 对缓存，输出期间会对上游施加 backpressure（s_axis_tready=0）。
//
// 色彩转换：
// - 采用近似 BT.601 full-range（用于测试/显示足够）。
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module axis_yuv422_16_to_xbgr32 (
    input  wire         aclk,
    input  wire         aresetn,

    // s_axis：16-bit/像素 的 YUV422
    input  wire [15:0]  s_axis_tdata,
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

    // 状态机：收偶数像素 -> 收奇数像素 -> 输出2像素
    localparam [1:0] ST_IDLE     = 2'd0;
    localparam [1:0] ST_HAVE_EVN = 2'd1;
    localparam [1:0] ST_OUT_0    = 2'd2;
    localparam [1:0] ST_OUT_1    = 2'd3;
    reg [1:0] state;

    reg [7:0] y0_reg;
    reg [7:0] y1_reg;
    reg [7:0] u_reg;
    reg [7:0] v_reg;
    reg       last_reg;  // 保存“奇数像素”上的 TLAST（常见：行尾在奇数像素）
    reg       user_reg;  // 保存 SOF（通常在偶数像素上出现）

    wire fire_in  = s_axis_tvalid && s_axis_tready;
    wire fire_out = m_axis_tvalid && m_axis_tready;

    // 只有在收输入阶段才允许继续接收；输出阶段对上游 backpressure
    assign s_axis_tready = (state == ST_IDLE) || (state == ST_HAVE_EVN);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state    <= ST_IDLE;
            y0_reg   <= 8'd0;
            y1_reg   <= 8'd0;
            u_reg    <= 8'd0;
            v_reg    <= 8'd0;
            last_reg <= 1'b0;
            user_reg <= 1'b0;
        end else begin
            case (state)
            ST_IDLE: begin
                if (fire_in) begin
                    // 偶数像素：{U, Y0}
                    u_reg    <= s_axis_tdata[15:8];
                    y0_reg   <= s_axis_tdata[7:0];
                    user_reg <= s_axis_tuser;
                    last_reg <= 1'b0;
                    state    <= ST_HAVE_EVN;
                end
            end

            ST_HAVE_EVN: begin
                if (fire_in) begin
                    // 奇数像素：{V, Y1}
                    v_reg    <= s_axis_tdata[15:8];
                    y1_reg   <= s_axis_tdata[7:0];
                    last_reg <= s_axis_tlast;
                    state    <= ST_OUT_0;
                end
            end

            ST_OUT_0: begin
                if (fire_out) begin
                    state <= ST_OUT_1;
                end
            end

            ST_OUT_1: begin
                if (fire_out) begin
                    // 一对像素输出完毕，回到 IDLE 收下一对
                    state    <= ST_IDLE;
                    last_reg <= 1'b0;
                    user_reg <= 1'b0;
                end
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

    assign m_axis_tvalid = (state == ST_OUT_0) || (state == ST_OUT_1);
    assign m_axis_tdata  = (state == ST_OUT_1) ? yuv_to_xbgr32(y1_reg, u_reg, v_reg)
                                               : yuv_to_xbgr32(y0_reg, u_reg, v_reg);

    // TUSER：只在输出第一个像素时透传（SOF 标记）
    assign m_axis_tuser = (state == ST_OUT_0) && user_reg;

    // TLAST：行尾通常在奇数像素上，因此放在第二个输出像素
    assign m_axis_tlast = (state == ST_OUT_1) && last_reg;

endmodule

