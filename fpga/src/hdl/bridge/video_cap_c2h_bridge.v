//------------------------------------------------------------------------------
// Module: video_cap_c2h_bridge
// Description:
//   纯“DMA 适配/鲁棒性”模块：不做色彩空间转换，只负责把已经准备好的像素字节流
//   做帧对齐/门控/打包/深 FIFO 缓冲，然后输出给 XDMA C2H 的 128-bit AXI4-Stream，
//   并生成 user IRQ（VSYNC 上升沿/下降沿/帧完成）。
//
// 设计目标（低延时/高鲁棒性）：
// - 不做帧缓存：按行/按帧的连续数据直接走 stream
// - 在 XDMA 前放置深 FIFO，吸收 tready 抖动（避免 backpressure 直接影响上游）
// - 帧对齐以 AXIS TUSER(SOF) 优先；fallback 用 VSYNC falling + 首次握手锁定 SOF
// - overflow/underflow 时丢弃当前帧并等待下一次 SOF 重对齐
//
// 输入格式约定（重要）：
// - 本模块输入为 32-bit/word 的 AXI4-Stream：axis_pix
// - word 的“内存字节序”（host 看到的 raw bytes）由上游保证与 pixelformat 匹配：
//   - XBGR32（ffplay: bgr0）：每 word 的 bytes 为 [B,G,R,0]（little-endian）
//   - YUYV422（ffplay: yuyv422）：每 word 的 bytes 为 [Y0,U0,Y1,V0]（little-endian）
// - 本模块只做 4 words -> 128-bit 的拼接，保持字节流顺序，不解释像素含义。
//
// 注意：
// - pack_word_last 仍保持“整帧最后一个 beat 才置位”的语义。
// - 为了让行尾/帧尾能落在 128-bit beat 边界，上游每行输出的 32-bit word 数应能被 4 整除。
//   例如：RGB32: 1920 words/line；YUYV: 960 words/line，均满足。
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module video_cap_c2h_bridge #(
    parameter integer USER_IRQ_WIDTH = 4,
    parameter integer VSYNC_IRQ_BIT  = 1,
    parameter integer FRAME_LINES = 1080,
    parameter integer C2H_BRAM_FIFO_DEPTH_WORDS = 4096  // 4096 * 16B = 64KB
) (
    // 说明：为了让 “Add Module to Block Design”（Module Reference）方式在 BD 中不报
    // “AXIS 接口未关联时钟/复位”等错误，这里显式声明时钟/复位与 AXIS bus 的关联关系。
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF axis_pix:s_axis_c2h, ASSOCIATED_RESET axi_aresetn" *)
    input  wire         axi_aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         axi_aresetn,

    // 控制（AXI 域）
    input  wire         ctrl_enable,
    input  wire         ctrl_soft_reset,

    // 来自视频源的 VSYNC（可能异步输入到 axi_aclk 域，由本模块内部同步）
    input  wire         vid_vsync,

    // 像素 AXI4-Stream 输入（axi_aclk 域，32-bit/word）
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 axis_pix TDATA" *)
    input  wire [31:0]  axis_pix_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 axis_pix TVALID" *)
    input  wire         axis_pix_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 axis_pix TREADY" *)
    output wire         axis_pix_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 axis_pix TLAST" *)
    input  wire         axis_pix_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis_rtl:1.0 axis_pix TUSER" *)
    input  wire         axis_pix_tuser,

    // 上游 overflow/underflow（可能来自视频域；本模块内部同步到 axi_aclk）
    input  wire         vid_fifo_overflow,
    input  wire         vid_fifo_underflow,

    // 输出到 XDMA C2H（axi_aclk 域，128-bit）
    output wire [127:0] s_axis_c2h_tdata,
    output wire [15:0]  s_axis_c2h_tkeep,
    output wire         s_axis_c2h_tlast,
    output wire         s_axis_c2h_tvalid,
    input  wire         s_axis_c2h_tready,

    // user IRQ（电平保持直到 ack）
    // user IRQ（电平保持直到 ack）
    output wire [USER_IRQ_WIDTH-1:0]   usr_irq_req,
    input  wire [USER_IRQ_WIDTH-1:0]   usr_irq_ack,

    // 状态：sticky 的 overflow/underflow（用于寄存器 STATUS）
    output wire         sts_fifo_overflow
);

    //--------------------------------------------------------------------------
    // overflow/underflow 同步 + sticky 状态
    //--------------------------------------------------------------------------
    wire vid_fifo_overflow_axi;
    wire vid_fifo_underflow_axi;
    reg  vid_fifo_error_sticky;

    cdc_sync #(.WIDTH(1), .STAGES(2)) u_cdc_vid_overflow (
        .clk_dst (axi_aclk),
        .rst_n   (axi_aresetn),
        .sig_in  (vid_fifo_overflow),
        .sig_out (vid_fifo_overflow_axi)
    );

    cdc_sync #(.WIDTH(1), .STAGES(2)) u_cdc_vid_underflow (
        .clk_dst (axi_aclk),
        .rst_n   (axi_aresetn),
        .sig_in  (vid_fifo_underflow),
        .sig_out (vid_fifo_underflow_axi)
    );

    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            vid_fifo_error_sticky <= 1'b0;
        end else if (~ctrl_enable || ctrl_soft_reset) begin
            vid_fifo_error_sticky <= 1'b0;
        end else begin
            vid_fifo_error_sticky <= vid_fifo_error_sticky |
                                     vid_fifo_overflow_axi | vid_fifo_underflow_axi;
        end
    end

    assign sts_fifo_overflow = vid_fifo_error_sticky;

    //--------------------------------------------------------------------------
    // VSYNC 同步（axi_aclk 域）
    //--------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg vsync_sync1, vsync_sync2, vsync_sync3;
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            vsync_sync1 <= 1'b0;
            vsync_sync2 <= 1'b0;
            vsync_sync3 <= 1'b0;
        end else begin
            vsync_sync1 <= vid_vsync;
            vsync_sync2 <= vsync_sync1;
            vsync_sync3 <= vsync_sync2;
        end
    end

    wire vsync_rising  =  vsync_sync2 && !vsync_sync3;
    wire vsync_falling = !vsync_sync2 &&  vsync_sync3;

    //--------------------------------------------------------------------------
    // 帧对齐/门控：保证每次传输从 SOF 开始
    //--------------------------------------------------------------------------
    // SOF 优先使用 axis_pix_tuser；fallback：VSYNC falling 之后的第一次握手视为 SOF
    wire axis_pix_xfer_sof = axis_pix_tvalid && axis_pix_tready;
    wire sof_axis_tuser    = axis_pix_xfer_sof && axis_pix_tuser;

    (* mark_debug="true" *) reg sof_wait_axis;
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            sof_wait_axis <= 1'b0;
        end else if (~ctrl_enable || ctrl_soft_reset) begin
            sof_wait_axis <= 1'b0;
        end else begin
            if (sof_axis_tuser) begin
                sof_wait_axis <= 1'b0;
            end else if (vsync_falling) begin
                sof_wait_axis <= 1'b1;
            end else if (sof_wait_axis && axis_pix_xfer_sof) begin
                sof_wait_axis <= 1'b0;
            end
        end
    end

    wire sof_axis_vsync = sof_wait_axis && axis_pix_xfer_sof;
    wire sof_detected   = sof_axis_tuser || sof_axis_vsync;

    // 记录 SOF 事件（电平保持到开始真正拉流时清零）
    (* mark_debug="true" *) reg sof_event;
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            sof_event <= 1'b0;
        end else if (~ctrl_enable || ctrl_soft_reset) begin
            sof_event <= 1'b0;
        end else if (sof_detected) begin
            sof_event <= 1'b1;
        end else if (sof_event && axis_pix_xfer_sof) begin
            sof_event <= 1'b0;
        end
    end

    // 只有在输出路径空闲 & XDMA ready 时才 arm，避免帧中途切入
    (* mark_debug="true" *) reg  capture_armed;
    (* mark_debug="true" *) reg  sof_pending;
    (* mark_debug="true" *) reg  frame_in_progress;
    (* mark_debug="true" *) reg  first_frame_seen;
    (* mark_debug="true" *) reg  [10:0] line_cnt;
    wire out_path_idle;

    wire axis_pix_xfer = axis_pix_tvalid && axis_pix_tready;
    wire frame_start_pulse = axis_pix_xfer && capture_armed && (sof_pending || sof_event);

    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            capture_armed     <= 1'b0;
            sof_pending       <= 1'b0;
            frame_in_progress <= 1'b0;
            first_frame_seen  <= 1'b0;
            line_cnt          <= 11'd0;
        end else begin
            if (~ctrl_enable || ctrl_soft_reset || vid_fifo_overflow_axi || vid_fifo_underflow_axi) begin
                capture_armed     <= 1'b0;
                sof_pending       <= 1'b0;
                frame_in_progress <= 1'b0;
                first_frame_seen  <= 1'b0;
                line_cnt          <= 11'd0;
            end else begin
                if (!frame_in_progress && !sof_pending) begin
                    capture_armed <= s_axis_c2h_tready && out_path_idle;
                end

                if (frame_start_pulse) begin
                    sof_pending <= 1'b0;
                end else if (!frame_in_progress && capture_armed && sof_event) begin
                    sof_pending <= 1'b1;
                end

                if (frame_start_pulse) begin
                    frame_in_progress <= 1'b1;
                    first_frame_seen  <= 1'b1;
                    line_cnt          <= 11'd0;
                    capture_armed     <= 1'b0;
                end else if (frame_in_progress && axis_pix_tvalid && axis_pix_tready && axis_pix_tlast) begin
                    if (line_cnt >= (FRAME_LINES - 1)) begin
                        line_cnt          <= 11'd0;
                        frame_in_progress <= 1'b0;
                    end else begin
                        line_cnt <= line_cnt + 1'b1;
                    end
                end
            end
        end
    end

    // 帧活跃：SOF 周期立即响应（组合逻辑）
    wire frame_active = frame_in_progress || frame_start_pulse;
    wire frame_data_valid = axis_pix_tvalid && frame_active;

    //--------------------------------------------------------------------------
    // 深 BRAM FIFO（在 XDMA 前提供弹性）
    //--------------------------------------------------------------------------
    localparam integer C2H_BRAM_FIFO_WIDTH = 129;   // {tlast, tdata[127:0]}

    (* mark_debug="true" *) wire c2h_bram_fifo_full;
    (* mark_debug="true" *) wire c2h_bram_fifo_empty;
    (* mark_debug="true" *) wire [C2H_BRAM_FIFO_WIDTH-1:0] c2h_bram_fifo_dout;
    wire [C2H_BRAM_FIFO_WIDTH-1:0] c2h_bram_fifo_din;

    wire c2h_bram_fifo_rd_fire  = (~c2h_bram_fifo_empty) && s_axis_c2h_tready;
    wire c2h_bram_fifo_wr_ready = (~c2h_bram_fifo_full) || c2h_bram_fifo_rd_fire;
    wire c2h_bram_fifo_wr_en;

    wire c2h_bram_fifo_rst = (~axi_aresetn) || (~ctrl_enable) || ctrl_soft_reset ||
                             vid_fifo_overflow_axi || vid_fifo_underflow_axi;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE  ("block"),
        .FIFO_WRITE_DEPTH  (C2H_BRAM_FIFO_DEPTH_WORDS),
        .WRITE_DATA_WIDTH  (C2H_BRAM_FIFO_WIDTH),
        .READ_DATA_WIDTH   (C2H_BRAM_FIFO_WIDTH),
        .READ_MODE         ("fwft"),
        .FULL_RESET_VALUE  (1),
        .USE_ADV_FEATURES  ("0000")
    ) u_c2h_bram_fifo (
        .rst    (c2h_bram_fifo_rst),
        .wr_clk (axi_aclk),
        .wr_en  (c2h_bram_fifo_wr_en),
        .din    (c2h_bram_fifo_din),
        .full   (c2h_bram_fifo_full),
        .rd_en  (c2h_bram_fifo_rd_fire),
        .dout   (c2h_bram_fifo_dout),
        .empty  (c2h_bram_fifo_empty)
    );

    assign out_path_idle = c2h_bram_fifo_empty;

    //--------------------------------------------------------------------------
    // 32-bit words -> 128-bit（4 words/beat）
    //--------------------------------------------------------------------------
    wire axis_word_xfer = frame_data_valid && axis_pix_tready;
    reg  [1:0]  word_cnt;
    reg  [31:0] word_buf [0:2];

    wire [1:0] word_cnt_eff = frame_start_pulse ? 2'd0 : word_cnt;
    wire pack_word_fire      = axis_word_xfer && (word_cnt_eff == 2'd3);

    // pack：最新 word 放在最高 32bit，保证“低地址=更早数据”的顺序
    wire [127:0] pack_word_data = {axis_pix_tdata, word_buf[2], word_buf[1], word_buf[0]};
    wire pack_word_last = axis_pix_tlast && (line_cnt == (FRAME_LINES - 1));

    assign c2h_bram_fifo_din   = {pack_word_last, pack_word_data};
    assign c2h_bram_fifo_wr_en = pack_word_fire && c2h_bram_fifo_wr_ready;

    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            word_cnt    <= 2'd0;
            word_buf[0] <= 32'd0;
            word_buf[1] <= 32'd0;
            word_buf[2] <= 32'd0;
        end else begin
            if (~ctrl_enable || ctrl_soft_reset || vid_fifo_overflow_axi || vid_fifo_underflow_axi) begin
                word_cnt    <= 2'd0;
                word_buf[0] <= 32'd0;
                word_buf[1] <= 32'd0;
                word_buf[2] <= 32'd0;
            end else if (axis_word_xfer) begin
                if (frame_start_pulse) begin
                    word_buf[0] <= axis_pix_tdata;
                    word_buf[1] <= 32'd0;
                    word_buf[2] <= 32'd0;
                    word_cnt    <= 2'd1;
                end else begin
                    case (word_cnt)
                        2'd0: begin word_buf[0] <= axis_pix_tdata; word_cnt <= 2'd1; end
                        2'd1: begin word_buf[1] <= axis_pix_tdata; word_cnt <= 2'd2; end
                        2'd2: begin word_buf[2] <= axis_pix_tdata; word_cnt <= 2'd3; end
                        2'd3: begin word_cnt    <= 2'd0; end
                    endcase
                end
            end
        end
    end

    // 输出到 XDMA（来自 FIFO，FWFT）
    assign s_axis_c2h_tdata  = c2h_bram_fifo_dout[127:0];
    assign s_axis_c2h_tkeep  = 16'hFFFF;
    assign s_axis_c2h_tlast  = c2h_bram_fifo_dout[128];
    assign s_axis_c2h_tvalid = ~c2h_bram_fifo_empty;

    // tready：帧外强制 1（冲刷上游 FIFO）；帧内仅在 beat 边界受 FIFO 写入能力影响
    wire axis_pix_tready_normal = (word_cnt != 2'd3) ? 1'b1 : c2h_bram_fifo_wr_ready;
    assign axis_pix_tready = frame_in_progress ? axis_pix_tready_normal : 1'b1;

      //--------------------------------------------------------------------------
      // user IRQ（level）：本实例只使用 1 个 user IRQ bit（VSYNC 上升沿）
      // - 使用位：VSYNC_IRQ_BIT（建议让它与 Linux 驱动的 irq_index + channel 对齐）
      // - 其它位：保持为 0，避免未注册/未 ACK 时一直 pending
      //--------------------------------------------------------------------------
    wire [USER_IRQ_WIDTH-1:0] vsync_mask = ({ {(USER_IRQ_WIDTH-1){1'b0}}, 1'b1 } << VSYNC_IRQ_BIT);
    reg  [USER_IRQ_WIDTH-1:0] irq_req_reg;

    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            irq_req_reg <= {USER_IRQ_WIDTH{1'b0}};
        end else if (~ctrl_enable || ctrl_soft_reset) begin
            irq_req_reg <= {USER_IRQ_WIDTH{1'b0}};
        end else begin
            // only keep VSYNC bit, force other bits low (avoid pending IRQs without ACK)
            irq_req_reg <= irq_req_reg & vsync_mask;

            if (vsync_rising) begin
                irq_req_reg[VSYNC_IRQ_BIT] <= 1'b1;
            end else if (usr_irq_ack[VSYNC_IRQ_BIT]) begin
                irq_req_reg[VSYNC_IRQ_BIT] <= 1'b0;
            end
        end
    end

    assign usr_irq_req = irq_req_reg;


endmodule
