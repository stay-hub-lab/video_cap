//------------------------------------------------------------------------------
// Module: video_cap_c2h_bridge
// Description:
//   将视频侧 v_vid_in_axi4s 输出的 24-bit AXI4-Stream，进行帧对齐/门控/打包/缓冲，
//   最终输出给 XDMA C2H 的 128-bit AXI4-Stream，同时生成 VSYNC/帧完成等 user IRQ。
//
// 设计原则（面向低延时/高鲁棒性）：
// - 不做帧缓存：按行/按帧的连续数据直接走 stream
// - 在 XDMA 前放置深 FIFO，吸收 tready 抖动（避免 backpressure 直接影响视频输入）
// - 帧对齐以 AXIS TUSER(SOF) 优先；fallback 用 VSYNC 边沿 + 首次握手锁定 SOF
// - 发生 overflow/underflow 时丢弃当前帧并等待下一次 SOF 重对齐
//
// 备注：
// - 当前实现保持与原 top 逻辑一致：每个 24-bit 像素扩展为 32-bit（高 8bit 填 0），
//   4 像素打包为 128-bit。
// - 后续要支持 64-bit XDMA 或 YUV422，可在此模块内参数化/替换打包策略。
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module video_cap_c2h_bridge #(
    parameter integer FRAME_LINES = 1080,
    parameter integer C2H_BRAM_FIFO_DEPTH_WORDS = 4096  // 4096 * 16B = 64KB
) (
    // 说明：为了让 “Add Module to Block Design”（Module Reference）方式在 BD 中不报
    // “AXIS 接口未关联时钟/复位”等错误，这里显式声明时钟/复位与 AXIS bus 的关联关系。
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF axis_vid:s_axis_c2h, ASSOCIATED_RESET axi_aresetn" *)
    input  wire         axi_aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         axi_aresetn,

    // 控制（AXI 域）
    input  wire         ctrl_enable,
    input  wire         ctrl_soft_reset,

    // 来自视频源的 VSYNC（异步输入到 axi_aclk 域，由本模块内部同步）
    input  wire         vid_vsync,

    // v_vid_in_axi4s 输出（axi_aclk 域）
    input  wire [23:0]  axis_vid_tdata,
    input  wire         axis_vid_tvalid,
    output wire         axis_vid_tready,
    input  wire         axis_vid_tlast,
    input  wire         axis_vid_tuser,

    // v_vid_in_axi4s overflow/underflow（可能来自视频域；本模块内部同步到 axi_aclk）
    input  wire         vid_fifo_overflow,
    input  wire         vid_fifo_underflow,

    // 输出到 XDMA C2H（axi_aclk 域，128-bit）
    output wire [127:0] s_axis_c2h_tdata,
    output wire [15:0]  s_axis_c2h_tkeep,
    output wire         s_axis_c2h_tlast,
    output wire         s_axis_c2h_tvalid,
    input  wire         s_axis_c2h_tready,

    // user IRQ（电平保持直到 ack）
    output wire [3:0]   usr_irq_req,
    input  wire [3:0]   usr_irq_ack,

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
    // VSYNC 同步（axi_aclk 域）与 SOF fallback 逻辑
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

    // SOF 优先使用 axis_vid_tuser；fallback：VSYNC falling 之后的第一次握手视为 SOF
    wire axis_vid_xfer_sof = axis_vid_tvalid && axis_vid_tready;
    wire sof_axis_tuser    = axis_vid_xfer_sof && axis_vid_tuser;

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
            end else if (sof_wait_axis && axis_vid_xfer_sof) begin
                sof_wait_axis <= 1'b0;
            end
        end
    end

    wire sof_axis_vsync = sof_wait_axis && axis_vid_xfer_sof;
    wire sof_detected   = sof_axis_tuser || sof_axis_vsync;

    //--------------------------------------------------------------------------
    // 帧对齐/门控状态机（与原 top 保持一致）
    //--------------------------------------------------------------------------
    wire sof_event;
    wire axis_vid_xfer;
    wire frame_start_pulse;
    reg  sof_pending;
    reg  capture_armed;
    wire out_path_idle;

    assign sof_event         = sof_detected;
    assign axis_vid_xfer     = axis_vid_tvalid && axis_vid_tready;
    assign frame_start_pulse = axis_vid_xfer && capture_armed && (sof_pending || sof_event);

    (* mark_debug="true" *) reg [10:0] line_cnt;
    (* mark_debug="true" *) reg        frame_in_progress;
    (* mark_debug="true" *) reg        first_frame_seen;

    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            line_cnt          <= 11'd0;
            frame_in_progress <= 1'b0;
            first_frame_seen  <= 1'b0;
            sof_pending       <= 1'b0;
            capture_armed     <= 1'b0;
        end else begin
            if (~ctrl_enable || ctrl_soft_reset) begin
                line_cnt          <= 11'd0;
                frame_in_progress <= 1'b0;
                sof_pending       <= 1'b0;
                capture_armed     <= 1'b0;
            end else if (vid_fifo_overflow_axi || vid_fifo_underflow_axi) begin
                // v_vid_in_axi4s 异常：丢帧并等待下一次 SOF
                line_cnt          <= 11'd0;
                frame_in_progress <= 1'b0;
                sof_pending       <= 1'b0;
                capture_armed     <= 1'b0;
            end else begin
                // 主机开始拉数据（XDMA tready=1）且输出路径空闲时才允许 arm
                if (!frame_in_progress && !sof_pending) begin
                    capture_armed <= s_axis_c2h_tready && out_path_idle;
                end

                // 记录 SOF 事件，直到看到第一次“真实握手”才启动帧
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
                end else if (frame_in_progress && axis_vid_tvalid && axis_vid_tready && axis_vid_tlast) begin
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
    wire frame_data_valid = axis_vid_tvalid && frame_active;

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
    // 24-bit 像素打包为 128-bit（保持原 top 行为）
    //--------------------------------------------------------------------------
    wire axis_pixel_xfer = frame_data_valid && axis_vid_tready;
    reg  [1:0]  pixel_cnt;
    reg  [23:0] pixel_buf [0:2];

    // 帧起点时把当前像素视为 pixel0，避免残留 pixel_cnt 造成相位错
    wire [1:0] pixel_cnt_eff = frame_start_pulse ? 2'd0 : pixel_cnt;
    wire pack_word_fire      = axis_pixel_xfer && (pixel_cnt_eff == 2'd3);
    wire [127:0] pack_word_data = {8'h00, axis_vid_tdata,
                                   8'h00, pixel_buf[2],
                                   8'h00, pixel_buf[1],
                                   8'h00, pixel_buf[0]};
    wire pack_word_last = axis_vid_tlast && (line_cnt == (FRAME_LINES - 1));

    assign c2h_bram_fifo_din   = {pack_word_last, pack_word_data};
    assign c2h_bram_fifo_wr_en = pack_word_fire && c2h_bram_fifo_wr_ready;

    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            pixel_cnt    <= 2'd0;
            pixel_buf[0] <= 24'd0;
            pixel_buf[1] <= 24'd0;
            pixel_buf[2] <= 24'd0;
        end else begin
            if (~ctrl_enable || ctrl_soft_reset || vid_fifo_overflow_axi || vid_fifo_underflow_axi) begin
                pixel_cnt    <= 2'd0;
                pixel_buf[0] <= 24'd0;
                pixel_buf[1] <= 24'd0;
                pixel_buf[2] <= 24'd0;
            end else if (axis_pixel_xfer) begin
                if (frame_start_pulse) begin
                    pixel_buf[0] <= axis_vid_tdata;
                    pixel_buf[1] <= 24'd0;
                    pixel_buf[2] <= 24'd0;
                    pixel_cnt    <= 2'd1;
                end else begin
                    case (pixel_cnt)
                        2'd0: begin pixel_buf[0] <= axis_vid_tdata; pixel_cnt <= 2'd1; end
                        2'd1: begin pixel_buf[1] <= axis_vid_tdata; pixel_cnt <= 2'd2; end
                        2'd2: begin pixel_buf[2] <= axis_vid_tdata; pixel_cnt <= 2'd3; end
                        2'd3: begin pixel_cnt    <= 2'd0; end
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

    // tready：帧外强制 1（冲刷 v_vid_in_axi4s 内部 FIFO）；帧内仅在 word 边界受 FIFO 写入能力影响
    wire axis_vid_tready_normal = (pixel_cnt != 2'd3) ? 1'b1 : c2h_bram_fifo_wr_ready;
    assign axis_vid_tready = frame_in_progress ? axis_vid_tready_normal : 1'b1;

    //--------------------------------------------------------------------------
    // user IRQ：保持与原 top 一致的映射
    //--------------------------------------------------------------------------
    wire frame_complete = s_axis_c2h_tvalid && s_axis_c2h_tlast && s_axis_c2h_tready;
    reg  [3:0] irq_req_reg;

    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            irq_req_reg <= 4'b0000;
        end else begin
            if (vsync_rising) begin
                irq_req_reg[0] <= 1'b1;
            end else if (usr_irq_ack[0]) begin
                irq_req_reg[0] <= 1'b0;
            end

            if (vsync_falling) begin
                irq_req_reg[1] <= 1'b1;
            end else if (usr_irq_ack[1]) begin
                irq_req_reg[1] <= 1'b0;
            end

            if (frame_complete) begin
                irq_req_reg[2] <= 1'b1;
            end else if (usr_irq_ack[2]) begin
                irq_req_reg[2] <= 1'b0;
            end

            irq_req_reg[3] <= 1'b0;
        end
    end

    assign usr_irq_req = irq_req_reg;

endmodule
