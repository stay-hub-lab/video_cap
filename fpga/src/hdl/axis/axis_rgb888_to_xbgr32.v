//------------------------------------------------------------------------------
// Module: axis_rgb888_to_xbgr32
// Description:
//   AXI4-Stream 像素适配器：把 24-bit RGB888（{R,G,B}）扩展为 32-bit XBGR32（BGR0）。
//
// 约定：
// - 输入 tdata = {R,G,B}（即 [23:16]=R, [15:8]=G, [7:0]=B）
// - 输出 32-bit word 的内存字节序（little-endian）为 [B,G,R,0]，对应 ffplay 的 bgr0。
// - 只做字节/位宽适配，不做帧对齐、不做打包。
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module axis_rgb888_to_xbgr32 (
    input  wire         aclk,
    input  wire         aresetn,

    // s_axis：RGB888
    input  wire [23:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,

    // m_axis：XBGR32（BGR0）
    output wire [31:0]  m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire         m_axis_tuser
);

    reg        vld;
    reg [31:0] dat;
    reg        lst;
    reg        usr;

    assign s_axis_tready = (~vld) || m_axis_tready;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            vld <= 1'b0;
            dat <= 32'd0;
            lst <= 1'b0;
            usr <= 1'b0;
        end else begin
            if (s_axis_tready) begin
                vld <= s_axis_tvalid;
                dat <= {8'h00, s_axis_tdata}; // 内存 bytes: [B,G,R,0]
                lst <= s_axis_tlast;
                usr <= s_axis_tuser;
            end
        end
    end

    assign m_axis_tvalid = vld;
    assign m_axis_tdata  = dat;
    assign m_axis_tlast  = lst;
    assign m_axis_tuser  = usr;

endmodule

