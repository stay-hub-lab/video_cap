//------------------------------------------------------------------------------
// Module: video_cap_top_pcie
// Description: PCIe Video Capture Card Top Module with XDMA
//              - Target: XC7K480TFFG1156-2
//              - Phase 2: XDMA Stream Mode (128-bit)
//
// Data Flow:
//   Color Bar Generator -> AXI-Stream FIFO -> XDMA C2H -> PCIe -> Host
//
// Author: Auto-generated
// Date: 2025-12-21
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module video_cap_top_pcie (
    //--------------------------------------------------------------------------
    // PCIe Interface
    //--------------------------------------------------------------------------
    input  wire         sys_clk_p,          // PCIe reference clock 100MHz
    input  wire         sys_clk_n,
    input  wire         sys_rst_n,          // PCIe reset (Active Low)
    
    output wire [7:0]   pci_exp_txp,        // PCIe TX (x8)
    output wire [7:0]   pci_exp_txn,
    input  wire [7:0]   pci_exp_rxp,        // PCIe RX (x8)
    input  wire [7:0]   pci_exp_rxn,
    
    //--------------------------------------------------------------------------
    // System Clock
    //--------------------------------------------------------------------------
    input  wire         sys_clk_200m,       // 200MHz oscillator
    
    //--------------------------------------------------------------------------
    // LED Status
    //--------------------------------------------------------------------------
    output wire [2:0]   led                 // LED[0]: Heartbeat
                                            // LED[1]: PCIe Link Up
                                            // LED[2]: Video Active
);

    //==========================================================================
    // Internal signals
    //==========================================================================
    
    // PCIe clock and reset
    wire        pcie_refclk;
(* mark_debug="true" *)    wire        pcie_rst_n;
    
    // XDMA user interface
    wire        axi_aclk;                   // XDMA user clock (~250MHz)
    wire        axi_aresetn;                // XDMA user reset
(* mark_debug="true" *)    wire        user_lnk_up;                // PCIe link status
    
    // AXI-Lite Master (for register access)
    wire [31:0] m_axil_awaddr;
    wire        m_axil_awvalid;
    wire        m_axil_awready;
    wire [31:0] m_axil_wdata;
    wire [3:0]  m_axil_wstrb;
    wire        m_axil_wvalid;
    wire        m_axil_wready;
    wire [1:0]  m_axil_bresp;
    wire        m_axil_bvalid;
    wire        m_axil_bready;
    wire [31:0] m_axil_araddr;
    wire        m_axil_arvalid;
    wire        m_axil_arready;
    wire [31:0] m_axil_rdata;
    wire [1:0]  m_axil_rresp;
    wire        m_axil_rvalid;
    wire        m_axil_rready;
    
    // AXI-Stream C2H (Card to Host - Video Data, 128-bit)
    wire [127:0] s_axis_c2h_tdata_0;
    wire [15:0]  s_axis_c2h_tkeep_0;
(* mark_debug="true" *)    wire         s_axis_c2h_tlast_0;
(* mark_debug="true" *)    wire         s_axis_c2h_tvalid_0;
(* mark_debug="true" *)    wire         s_axis_c2h_tready_0;
    
    // AXI-Stream H2C (Host to Card - Not used)
    wire [127:0] m_axis_h2c_tdata_0;
    wire [15:0]  m_axis_h2c_tkeep_0;
    wire         m_axis_h2c_tlast_0;
    wire         m_axis_h2c_tvalid_0;
    wire         m_axis_h2c_tready_0;
    
    // User interrupts
(* mark_debug="true" *)    wire [3:0]  usr_irq_req;
(* mark_debug="true" *)    wire [3:0]  usr_irq_ack;
    
    // Video pixel clock
    wire        sys_clk_200m_buf;
    wire        vid_pixel_clk;              // 148.5MHz
    wire        clk_200m_out;              // 200MHz
    wire        vid_pixel_clk_locked;
    wire        pcie_vio_rstn;
    // Video signals from color bar generator
(* mark_debug="true" *)    wire [23:0] vid_data;
(* mark_debug="true" *)    wire        vid_vsync;
(* mark_debug="true" *)    wire        vid_hsync;
(* mark_debug="true" *)    wire        vid_de;
(* mark_debug="true" *)    wire        vid_field;
    
    // Video to AXI-Stream (24-bit)
(* mark_debug="true" *)    wire [23:0] axis_vid_tdata;
(* mark_debug="true" *)    wire        axis_vid_tvalid;
(* mark_debug="true" *)    wire        axis_vid_tready;
(* mark_debug="true" *)    wire        axis_vid_tlast;
(* mark_debug="true" *)    wire        axis_vid_tuser;
    
    // Control and status signals
(* mark_debug="true" *)    wire        ctrl_enable;
(* mark_debug="true" *)    wire        ctrl_soft_reset;
(* mark_debug="true" *)    wire        ctrl_test_mode;
(* mark_debug="true" *)    wire        sts_idle;
(* mark_debug="true" *)    wire        sts_fifo_overflow;

    // v_vid_in_axi4s overflow/underflow are generated in the video-side logic;
    // synchronize into axi_aclk domain before use/status to avoid CDC timing storms.
(* mark_debug="true" *)    wire        vid_fifo_overflow_axi;
(* mark_debug="true" *)    wire        vid_fifo_underflow_axi;
(* mark_debug="true" *)    reg         vid_fifo_error_sticky;
    
    // Heartbeat counter
    reg [26:0]  heartbeat_cnt;
    
    //==========================================================================
    // PCIe Reference Clock Buffer
    //==========================================================================
    
    IBUFDS_GTE2 refclk_ibuf (
        .O      (pcie_refclk),
        .ODIV2  (),
        .I      (sys_clk_p),
        .IB     (sys_clk_n),
        .CEB    (1'b0)
    );
    
    // 外部复位信号缓冲
    wire sys_rst_n_ibuf_out;
    IBUF sys_reset_n_ibuf (
        .O  (sys_rst_n_ibuf_out),
        .I  (sys_rst_n)
    );
    
    //==========================================================================
    // PCIe Reset Synchronization
    // 参考 Xilinx 官方例程的复位同步方式
    //==========================================================================
    
    // 复位同步寄存器
    (* ASYNC_REG = "TRUE" *) reg sys_rst_n_sync1;
    (* ASYNC_REG = "TRUE" *) reg sys_rst_n_sync2;
    
    // 使用XDMA输出的用户时钟进行同步
    // 注意：在复位期间，axi_aclk可能不稳定，所以用异步复位
    always @(posedge clk_200m_out or negedge sys_rst_n_ibuf_out) begin
        if (!sys_rst_n_ibuf_out) begin
            sys_rst_n_sync1 <= 1'b0;
            sys_rst_n_sync2 <= 1'b0;
        end else begin
            sys_rst_n_sync1 <= 1'b1;
            sys_rst_n_sync2 <= sys_rst_n_sync1;
        end
    end
//vio_pcie u_vio_pcie(
//    .clk        (clk_200m_out),
//    .probe_out0 (pcie_vio_rstn)

//);

    //==========================================================================
    // Power-on Reset Generator
    // FPGA 上电后自动产生约 100ms 的复位脉冲
    // 200MHz 时钟，100ms = 20,000,000 个时钟周期
    //==========================================================================
    
    reg [24:0] por_cnt;        // 上电复位计数器 (25-bit, 可数到 33M)
    reg        por_done;       // 上电复位完成标志
    wire       por_rst_n;      // 上电复位信号（低有效）
    
    always @(posedge clk_200m_out or negedge sys_rst_n_ibuf_out) begin
        if (!sys_rst_n_ibuf_out) begin
            por_cnt  <= 25'd0;
            por_done <= 1'b0;
        end else begin
            if (!por_done) begin
                if (por_cnt >= 25'd20_000_000) begin  // 100ms @ 200MHz
                    por_done <= 1'b1;
                end else begin
                    por_cnt <= por_cnt + 1'b1;
                end
            end
        end
    end
    
    // 上电复位期间 por_rst_n = 0，完成后 por_rst_n = 1
    assign por_rst_n = por_done;
    
    // 直接把IBUF输出连接到XDMA的复位端口
    // XDMA IP内部有复位同步逻辑
    // PCIe 复位 = 外部复位 AND 上电复位 AND VIO复位（用于调试）
    assign pcie_rst_n = sys_rst_n_ibuf_out;
    
    //==========================================================================
    // System Clock Buffer
    //==========================================================================
    
    IBUF ibuf_sys_clk_200m (
        .I(sys_clk_200m),
        .O(sys_clk_200m_buf)
    );
    
    //==========================================================================
    // Video Pixel Clock Generation (148.5MHz)
    //==========================================================================
    
    clk_wiz_video u_clk_wiz_video (
        .clk_in1    (sys_clk_200m_buf),
      //  .resetn     (pcie_rst_n),
        .clk_out1   (vid_pixel_clk),
        .clk_out2   (clk_200m_out),
        .locked     (vid_pixel_clk_locked)
    );
    
    //==========================================================================
    // XDMA IP Core (Stream Mode, 128-bit)
    // Note: Port names are generated by Vivado IP, may need adjustment
    //==========================================================================
    
    xdma_0 u_xdma_0 (
        // PCIe Interface
        .sys_clk            (pcie_refclk),
        .sys_rst_n          (pcie_rst_n),
        
        .pci_exp_txp        (pci_exp_txp),
        .pci_exp_txn        (pci_exp_txn),
        .pci_exp_rxp        (pci_exp_rxp),
        .pci_exp_rxn        (pci_exp_rxn),
        
        // User Clock and Reset
        .axi_aclk           (axi_aclk),
        .axi_aresetn        (axi_aresetn),
        .user_lnk_up        (user_lnk_up),
        
        // AXI-Lite Master (Register Access)
        .m_axil_awaddr      (m_axil_awaddr),
        .m_axil_awprot      (),
        .m_axil_awvalid     (m_axil_awvalid),
        .m_axil_awready     (m_axil_awready),
        .m_axil_wdata       (m_axil_wdata),
        .m_axil_wstrb       (m_axil_wstrb),
        .m_axil_wvalid      (m_axil_wvalid),
        .m_axil_wready      (m_axil_wready),
        .m_axil_bresp       (m_axil_bresp),
        .m_axil_bvalid      (m_axil_bvalid),
        .m_axil_bready      (m_axil_bready),
        .m_axil_araddr      (m_axil_araddr),
        .m_axil_arprot      (),
        .m_axil_arvalid     (m_axil_arvalid),
        .m_axil_arready     (m_axil_arready),
        .m_axil_rdata       (m_axil_rdata),
        .m_axil_rresp       (m_axil_rresp),
        .m_axil_rvalid      (m_axil_rvalid),
        .m_axil_rready      (m_axil_rready),
        
        // AXI-Stream C2H Channel 0 (Card to Host - Video Data)
        .s_axis_c2h_tdata_0 (s_axis_c2h_tdata_0),
        .s_axis_c2h_tkeep_0 (s_axis_c2h_tkeep_0),
        .s_axis_c2h_tlast_0 (s_axis_c2h_tlast_0),
        .s_axis_c2h_tvalid_0(s_axis_c2h_tvalid_0),
        .s_axis_c2h_tready_0(s_axis_c2h_tready_0),
        
        // AXI-Stream H2C Channel 0 (Host to Card - Not used)
        .m_axis_h2c_tdata_0 (m_axis_h2c_tdata_0),
        .m_axis_h2c_tkeep_0 (m_axis_h2c_tkeep_0),
        .m_axis_h2c_tlast_0 (m_axis_h2c_tlast_0),
        .m_axis_h2c_tvalid_0(m_axis_h2c_tvalid_0),
        .m_axis_h2c_tready_0(1'b1),             // Always ready (not used)
        
        // User Interrupts
        .usr_irq_req        (usr_irq_req),
        .usr_irq_ack        (usr_irq_ack)
    );
    
    //==========================================================================
    // Register Bank
    //==========================================================================
    
    register_bank u_register_bank (
        .aclk               (axi_aclk),
        .aresetn            (axi_aresetn),
        
        // AXI-Lite Slave Interface
        .s_axil_awaddr      (m_axil_awaddr[15:0]),
        .s_axil_awvalid     (m_axil_awvalid),
        .s_axil_awready     (m_axil_awready),
        .s_axil_wdata       (m_axil_wdata),
        .s_axil_wstrb       (m_axil_wstrb),
        .s_axil_wvalid      (m_axil_wvalid),
        .s_axil_wready      (m_axil_wready),
        .s_axil_bresp       (m_axil_bresp),
        .s_axil_bvalid      (m_axil_bvalid),
        .s_axil_bready      (m_axil_bready),
        .s_axil_araddr      (m_axil_araddr[15:0]),
        .s_axil_arvalid     (m_axil_arvalid),
        .s_axil_arready     (m_axil_arready),
        .s_axil_rdata       (m_axil_rdata),
        .s_axil_rresp       (m_axil_rresp),
        .s_axil_rvalid      (m_axil_rvalid),
        .s_axil_rready      (m_axil_rready),
        
        // Control Outputs
        .ctrl_enable        (ctrl_enable),
        .ctrl_soft_reset    (ctrl_soft_reset),
        .ctrl_test_mode     (ctrl_test_mode),
        
        // Status Inputs
        .sts_idle           (sts_idle),
        .sts_mig_calib      (1'b1),
        .sts_fifo_overflow  (sts_fifo_overflow),
        .sts_pcie_link_up   (user_lnk_up),
        
        // Interrupts (not used - we use our own interrupt logic)
        .irq_frame_done     (),    // Unused - see VSYNC interrupt logic
        .irq_error          ()     // Unused
    );
    
    // usr_irq_req is driven by irq_req_reg (see VSYNC Interrupt Generation section)
    assign sts_idle = ~ctrl_enable;
    assign sts_fifo_overflow = vid_fifo_error_sticky;
    
    //==========================================================================
    // CDC Synchronizers for control signals (AXI clock -> Video clock)
    //==========================================================================
    
    wire ctrl_enable_sync;
    wire ctrl_test_mode_sync;
    wire ctrl_soft_reset_sync;
    
    // Synchronize ctrl_enable to video clock domain
    cdc_sync #(.WIDTH(1), .STAGES(2)) u_cdc_enable (
        .clk_dst    (vid_pixel_clk),
        .rst_n      (vid_pixel_clk_locked),
        .sig_in     (ctrl_enable),
        .sig_out    (ctrl_enable_sync)
    );
    
    // Synchronize ctrl_test_mode to video clock domain
    cdc_sync #(.WIDTH(1), .STAGES(2)) u_cdc_test_mode (
        .clk_dst    (vid_pixel_clk),
        .rst_n      (vid_pixel_clk_locked),
        .sig_in     (ctrl_test_mode),
        .sig_out    (ctrl_test_mode_sync)
    );
    
    // Synchronize ctrl_soft_reset to video clock domain
    cdc_sync #(.WIDTH(1), .STAGES(2)) u_cdc_soft_reset (
        .clk_dst    (vid_pixel_clk),
        .rst_n      (1'b1),  // Don't reset the reset sync
        .sig_in     (ctrl_soft_reset),
        .sig_out    (ctrl_soft_reset_sync)
    );
    
    //==========================================================================
    // Color Bar Generator (使用经过验证可工作的 color_bar 模块)
    // 时序: 标准视频时序 FP -> SYNC -> BP -> ACTIVE
    //==========================================================================
    
    wire [7:0] vid_rgb_r, vid_rgb_g, vid_rgb_b;
    
    color_bar u_color_bar (
        .clk        (vid_pixel_clk),
        .rst        (~vid_pixel_clk_locked | ctrl_soft_reset_sync | ~(ctrl_enable_sync & ctrl_test_mode_sync)),
        
        .hs         (vid_hsync),
        .vs         (vid_vsync),
        .de         (vid_de),
        .rgb_r      (vid_rgb_r),
        .rgb_g      (vid_rgb_g),
        .rgb_b      (vid_rgb_b)
    );
    
    // 组合 RGB 数据为 24-bit
    assign vid_data = {vid_rgb_r, vid_rgb_g, vid_rgb_b};
    
    //==========================================================================
    // 自定义 SOF (Start of Frame) 检测
    // 检测 VSYNC 下降沿后的第一个 DE 上升沿 = 帧的第一个有效像素
    //==========================================================================
    
    // 视频时钟域：检测帧起始
    reg vid_de_d1;
    reg vid_vsync_d1;
(* mark_debug="true" *)    reg sof_pulse_vid;      // 视频时钟域的 SOF 脉冲
(* mark_debug="true" *)    reg sof_flag_vid;       // SOF 标志（保持直到被 AXI 时钟域读取）
(* mark_debug="true" *)    reg wait_for_de;        // 等待 DE 上升沿的标志
    
    always @(posedge vid_pixel_clk or negedge vid_pixel_clk_locked) begin
        if (!vid_pixel_clk_locked) begin
            vid_de_d1     <= 1'b0;
            vid_vsync_d1  <= 1'b0;
            sof_pulse_vid <= 1'b0;
            sof_flag_vid  <= 1'b0;
            wait_for_de   <= 1'b0;
        end else begin
            vid_de_d1    <= vid_de;
            vid_vsync_d1 <= vid_vsync;
            
            // 步骤1：检测 VSYNC 下降沿（从高变低），设置等待标志
            // 对于 1080p，VS_POL = 1 表示 VSYNC 在消隐期间为高
            if (!vid_vsync && vid_vsync_d1) begin
                // VSYNC 下降沿 = 消隐结束，有效区域即将开始
                wait_for_de  <= 1'b1;
                sof_flag_vid <= 1'b0;  // 关键：清除旧的 SOF 标志，为下一帧准备
            end
            
            // 步骤2：在等待状态下，检测 DE 上升沿 = SOF
            if (wait_for_de && vid_de && !vid_de_d1) begin
                // 第一个有效行的第一个像素 = SOF
                sof_pulse_vid <= 1'b1;
                sof_flag_vid  <= 1'b1;
                wait_for_de   <= 1'b0;  // 清除等待标志
            end else begin
                sof_pulse_vid <= 1'b0;
            end
        end
    end
    
    // 跨时钟域同步 SOF 到 AXI 时钟域
    (* ASYNC_REG = "TRUE" *) reg sof_sync1, sof_sync2, sof_sync3;
    wire custom_sof;
    
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            sof_sync1 <= 1'b0;
            sof_sync2 <= 1'b0;
            sof_sync3 <= 1'b0;
        end else begin
            sof_sync1 <= sof_flag_vid;
            sof_sync2 <= sof_sync1;
            sof_sync3 <= sof_sync2;
        end
    end
    
    // SOF 上升沿检测（在 AXI 时钟域）
    assign custom_sof = sof_sync2 && !sof_sync3;
    
    //==========================================================================
    // Video to AXI-Stream Converter (使用 v_vid_in_axi4s IP)
    // 此 IP 与 color_bar 的标准视频时序兼容
    //==========================================================================

    // Overflow/underflow signals for debugging
(* mark_debug="true" *)    wire vid_fifo_overflow;
(* mark_debug="true" *)    wire vid_fifo_underflow;

    v_vid_in_axi4s_0 u_vid_in_axi4s (
        .vid_io_in_clk         (vid_pixel_clk),
        .vid_io_in_ce          (1'b1),
        .vid_io_in_reset       (~vid_pixel_clk_locked),  // 只在时钟未锁定时复位
        .vid_active_video      (vid_de),
        .vid_vsync             (vid_vsync),
        .vid_hsync             (vid_hsync),
        .vid_data              (vid_data),
        .aclk                  (axi_aclk),
        .aclken                (1'b1),
        .aresetn               (axi_aresetn),
        .axis_enable           (1'b1),
        .m_axis_video_tdata    (axis_vid_tdata),
        .m_axis_video_tvalid   (axis_vid_tvalid),
        .m_axis_video_tready   (axis_vid_tready),
        .m_axis_video_tuser    (axis_vid_tuser),
        .m_axis_video_tlast    (axis_vid_tlast),
        .overflow              (vid_fifo_overflow),
        .underflow             (vid_fifo_underflow)
    );

    // CDC: bring overflow/underflow into axi_aclk domain
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

    // Sticky status (cleared on disable/soft-reset) so software can observe errors.
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            vid_fifo_error_sticky <= 1'b0;
        end else if (~ctrl_enable || ctrl_soft_reset) begin
            vid_fifo_error_sticky <= 1'b0;
        end else begin
            vid_fifo_error_sticky <= vid_fifo_error_sticky | vid_fifo_overflow_axi | vid_fifo_underflow_axi;
        end
    end

    //==========================================================================
    // Frame Synchronization Logic (帧对齐版)
    // 使用 custom_sof 信号来检测帧起始 (自己基于 VSYNC/DE 生成)
    // 这确保每次传输都从帧头开始，防止图像错位
    //==========================================================================
    
    // SOF 信号选择：
    // - axis_vid_tuser: v_vid_in_axi4s IP 输出（与 tdata 同域同链路，推荐用于帧对齐）
    // - custom_sof: 自己基于 VSYNC/DE 生成（保留用于对照/调试）
(* mark_debug="true" *)    wire sof_detected;
(* mark_debug="true" *)    wire custom_sof_dbg;
    assign custom_sof_dbg = custom_sof;  // 用于调试

    // 关键：SOF 以 AXI4-Stream 输出的 TUSER 为准（典型语义：帧首有效像素）
    // 这样 SOF 与 tdata 同属 axi_aclk 域、同一条数据链路，避免跨域 SOF 与数据延迟不一致引起的“错位”。
    // SOF 事件（用于调试观察；不代表真正采集起点）
    // - custom_sof: VSYNC/DE 生成并跨域同步（可能早于对应的第一像素数据）
    // - axis_vid_tuser: 若 v_vid_in_axi4s 配置为输出 SOF，可作为同域参考（某些配置下可能恒为 0）
    // SOF å¯¹é½ç­–ç•¥ï¼š
    // 1) ä¼˜å…ˆä½¿ç”¨ AXIS TUSER(SOF)ï¼Œå› ä¸ºå®ƒä¸Ž tdata åŒåŸŸåŒé“¾è·¯ï¼Œå¯¹é½æœ€å‡†
    // 2) å¦‚æžœ TUSER åœ¨å½“å‰ IP é…ç½®ä¸‹æ’ä¸º 0ï¼Œåˆ™ä½¿ç”¨ VSYNC è¾¹æ²¿ + "ç¬¬ä¸€æ‹?AXIS æ¡æ‰‹" æ¥ç”Ÿæˆ SOF
    //    (SOF ä¸Ž AXIS æ•°æ®ç”±åŒä¸€æ¡æ‰‹å†³å®šï¼Œé¿å…ç‹¬ç«‹è·¨åŸŸ SOF å»¶è¿Ÿå¯¼è‡´å¸§å¤´ä¸¢åƒç´ /å¸§å¤´é”™ä½)

    // Local handshake (used only for SOF detection logic).
    wire axis_vid_xfer_sof = axis_vid_tvalid && axis_vid_tready;
    wire sof_axis_tuser    = axis_vid_xfer_sof && axis_vid_tuser;

    // Fallback SOF: detect VSYNC edge (axi_aclk domain) and then use the first AXIS handshake as SOF.
    // This keeps SOF aligned with v_vid_in_axi4s internal latency.
    (* ASYNC_REG = "TRUE" *) reg vsync_sof_sync1, vsync_sof_sync2, vsync_sof_sync3;
    wire vsync_falling_sof = !vsync_sof_sync2 && vsync_sof_sync3;

    (* mark_debug="true" *) reg sof_wait_axis;

    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            vsync_sof_sync1 <= 1'b0;
            vsync_sof_sync2 <= 1'b0;
            vsync_sof_sync3 <= 1'b0;
            sof_wait_axis   <= 1'b0;
        end else begin
            vsync_sof_sync1 <= vid_vsync;
            vsync_sof_sync2 <= vsync_sof_sync1;
            vsync_sof_sync3 <= vsync_sof_sync2;

            if (vid_fifo_overflow_axi || vid_fifo_underflow_axi) begin
                sof_wait_axis <= 1'b0;
            end else if (vsync_falling_sof) begin
                sof_wait_axis <= 1'b1;
            end else if (sof_wait_axis && axis_vid_xfer_sof) begin
                sof_wait_axis <= 1'b0;
            end
        end
    end

    wire sof_axis_vsync = sof_wait_axis && axis_vid_xfer_sof;
    assign sof_detected = sof_axis_tuser || sof_axis_vsync;

    // 将 SOF 与 AXIS 数据对齐：先“挂起”SOF，等待第一拍 AXIS 握手后再真正启动帧采集
    (* mark_debug="true" *) wire sof_event;
    wire axis_vid_xfer;
    (* mark_debug="true" *) wire frame_start_pulse;
    (* mark_debug="true" *) reg  sof_pending;
    (* mark_debug="true" *) reg  capture_armed;
    (* mark_debug="true" *) wire out_path_idle;

    assign sof_event        = sof_detected;
    assign axis_vid_xfer    = axis_vid_tvalid && axis_vid_tready;
    assign frame_start_pulse = axis_vid_xfer && capture_armed && (sof_pending || sof_event);
    
(* mark_debug="true" *)    reg [10:0] line_cnt;           // 行计数器 (0-1079)
(* mark_debug="true" *)    reg        frame_in_progress;  // 帧传输进行中标志 (寄存器)
(* mark_debug="true" *)    reg        first_frame_seen;   // 已看到第一帧标志
    
    // 帧同步状态机
    // 以 AXIS 真实握手为准：只有在 (tvalid&tready) 时才认为“接收到了 SOF 像素”。
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            line_cnt         <= 11'd0;
            frame_in_progress <= 1'b0;
            first_frame_seen  <= 1'b0;
            sof_pending       <= 1'b0;
            capture_armed     <= 1'b0;
        end else begin
            // 如果 v_vid_in_axi4s 发生溢出/欠载，直接丢弃当前帧，等待下一次 SOF 重对齐
            if (vid_fifo_overflow_axi || vid_fifo_underflow_axi) begin
                line_cnt          <= 11'd0;
                frame_in_progress <= 1'b0;
                sof_pending       <= 1'b0;
                capture_armed     <= 1'b0;
            end else begin
                // 主机发起 C2H 读取（XDMA 拉高 tready）时才允许开始输出一帧；
                // 否则在主机不读的间隙会积压/溢出，导致后续帧错位。
                if (!frame_in_progress && !sof_pending) begin
                    capture_armed <= s_axis_c2h_tready_0 && out_path_idle;
                end

                // 记录 SOF 事件，直到看到第一拍 AXIS 握手后再真正开始采集
                if (frame_start_pulse) begin
                    sof_pending <= 1'b0;
                end else if (!frame_in_progress && capture_armed && sof_event) begin
                    sof_pending <= 1'b1;
                end

                if (frame_start_pulse) begin
                    // 新帧开始（以第一拍 AXIS 握手像素为准）
                    frame_in_progress <= 1'b1;
                    first_frame_seen  <= 1'b1;
                    line_cnt          <= 11'd0;
                    capture_armed     <= 1'b0;
                end else if (frame_in_progress && axis_vid_tvalid && axis_vid_tready && axis_vid_tlast) begin
                    // 行结束（TLAST 语义：EOL）
                    if (line_cnt >= 11'd1079) begin
                        line_cnt          <= 11'd0;
                        frame_in_progress <= 1'b0;  // 帧传输完成，等待下一个 SOF
                    end else begin
                        line_cnt <= line_cnt + 1'b1;
                    end
                end
            end
        end
    end
    
    //==========================================================================
    // 帧活跃信号 (组合逻辑，立即响应 SOF)
    // 关键：使用组合逻辑确保检测到 SOF 的同一周期就设置 frame_active
    // frame_active = 1 when:
    //   - 帧正在进行中 (frame_in_progress = 1), OR
    //   - 当前周期刚检测到 SOF (sof_detected)
    //==========================================================================
    
(* mark_debug="true" *)    wire frame_active;
    assign frame_active = frame_in_progress || frame_start_pulse;
    
    // 有效数据标志：使用 frame_active 而不是 frame_in_progress
    // 当 frame_active=1 且有有效数据时，开始处理像素
(* mark_debug="true" *)    wire frame_data_valid;
    assign frame_data_valid = axis_vid_tvalid && frame_active;




    //==========================================================================
    // Data Width Conversion (24-bit to 128-bit)
    // Pack 4 pixels (96 bits) + 32 bits padding into 128-bit word
    //==========================================================================
    
    // Deep BRAM FIFO handles XDMA backpressure; no need for a tiny skid buffer here.

    // Deep BRAM FIFO before XDMA (axi_aclk domain).
    // Absorbs XDMA tready backpressure bursts to prevent v_vid_in_axi4s overflow/underflow.
    localparam integer C2H_BRAM_FIFO_DEPTH_WORDS = 4096;  // 4096 * 16B = 64KB
    localparam integer C2H_BRAM_FIFO_WIDTH       = 129;   // {tlast, tdata[127:0]}

    (* mark_debug="true" *) wire c2h_bram_fifo_full;
    (* mark_debug="true" *) wire c2h_bram_fifo_empty;
    (* mark_debug="true" *) wire [C2H_BRAM_FIFO_WIDTH-1:0] c2h_bram_fifo_dout;
    wire [C2H_BRAM_FIFO_WIDTH-1:0] c2h_bram_fifo_din;

    wire c2h_bram_fifo_rd_fire  = (~c2h_bram_fifo_empty) && s_axis_c2h_tready_0;
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
        .FIFO_READ_LATENCY (0),
        .DOUT_RESET_VALUE  ("0"),
        .ECC_MODE          ("no_ecc"),
        .SIM_ASSERT_CHK    (0)
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

    // Small FIFO behind the head register to absorb XDMA backpressure glitches.
    // 注意：head refill 与 direct-to-head enqueue 若同周期发生，必须避免覆盖 head，
    // 否则会丢 word，表现为帧内“分段错位/条带”。

    // Output path is fully drained (no pending 128-bit words).
    assign out_path_idle = c2h_bram_fifo_empty;

    // (removed) 2-deep skid helpers: deep BRAM FIFO provides elasticity.

    // Pixel transfer / pack helpers
    wire axis_pixel_xfer = frame_data_valid && axis_vid_tready;
    // 帧起点时把当前像素视为 pixel0，避免残留 pixel_cnt 造成相位错。
    wire [1:0] pixel_cnt_eff = frame_start_pulse ? 2'd0 : pixel_cnt;
    wire pack_word_fire  = axis_pixel_xfer && (pixel_cnt_eff == 2'd3);
    wire [127:0] pack_word_data = {8'h00, axis_vid_tdata,
                                   8'h00, pixel_buf[2],
                                   8'h00, pixel_buf[1],
                                   8'h00, pixel_buf[0]};
    wire pack_word_last = axis_vid_tlast && (line_cnt == 11'd1079);

    // Pack -> BRAM FIFO
    assign c2h_bram_fifo_din   = {pack_word_last, pack_word_data};
    assign c2h_bram_fifo_wr_en = pack_word_fire && c2h_bram_fifo_wr_ready;

(* mark_debug="true" *)    reg [1:0]   pixel_cnt;              // Count 0-3 (4 pixels per 128-bit word)
    reg [23:0]  pixel_buf [0:2];        // Buffer for first 3 pixels

    // Connect overflow/underflow signals (for debugging)
    // Note: These are exposed by v_vid_in_axi4s IP
    
    //==========================================================================
    // Pixel Packing Logic (24-bit x4 -> 128-bit)
    // 只处理帧同步后的数据
    //==========================================================================
    
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            pixel_cnt       <= 2'd0;
            pixel_buf[0]    <= 24'd0;
            pixel_buf[1]    <= 24'd0;
            pixel_buf[2]    <= 24'd0;
        end else begin
            // If v_vid_in_axi4s reports overflow/underflow, drop any partial output and restart on next SOF.
            if (vid_fifo_overflow_axi || vid_fifo_underflow_axi) begin
                pixel_cnt       <= 2'd0;
                pixel_buf[0]    <= 24'd0;
                pixel_buf[1]    <= 24'd0;
                pixel_buf[2]    <= 24'd0;
            end else begin
            //==================================================================
            // XDMA output FIFO (head + memory)
            //==================================================================

            // 帧起点：清空输出 FIFO，避免异常情况下残留数据混入下一帧
            // Deep BRAM FIFO is the only elasticity buffer before XDMA.
            // No local output registers are needed here.

            //==================================================================
            // Pixel packing state machine (24-bit pixels -> 128-bit words)
            //==================================================================

            if (axis_pixel_xfer) begin
                // 帧起点时重置 pixel_cnt，确保从 0 开始（严格帧对齐）
                if (frame_start_pulse) begin
                    pixel_buf[0] <= axis_vid_tdata;
                    pixel_buf[1] <= 24'd0;
                    pixel_buf[2] <= 24'd0;
                    pixel_cnt    <= 2'd1;
                end else begin
                    case (pixel_cnt)
                        2'd0: begin
                            pixel_buf[0] <= axis_vid_tdata;
                            pixel_cnt    <= 2'd1;
                        end
                        2'd1: begin
                            pixel_buf[1] <= axis_vid_tdata;
                            pixel_cnt    <= 2'd2;
                        end
                        2'd2: begin
                            pixel_buf[2] <= axis_vid_tdata;
                            pixel_cnt    <= 2'd3;
                        end
                        2'd3: begin
                            // The 128-bit word is published via the BRAM FIFO write enable
                            pixel_cnt <= 2'd0;
                        end
                    endcase
                end
            end
            end
        end
    end
    
    assign s_axis_c2h_tdata_0  = c2h_bram_fifo_dout[127:0];
    assign s_axis_c2h_tkeep_0  = 16'hFFFF;
    assign s_axis_c2h_tlast_0  = c2h_bram_fifo_dout[128];
    assign s_axis_c2h_tvalid_0 = ~c2h_bram_fifo_empty;
    
    // Ready signal:
    // - 非帧内：强制 ready=1，持续冲刷 v_vid_in_axi4s FIFO
    // - 帧内：尽量保持 ready=1，只在即将完成一个 128-bit word 且输出 FIFO 已满时拉低
(* mark_debug="true" *)    wire axis_vid_tready_normal;
    // Word 边界上，如果 memory FIFO 已满但 head 正在被 XDMA pop，
    // 同周期会从 memory 拉一条到 head（count--），等价于释放了 1 个槽位，
    // 允许继续接收第 4 个像素，避免不必要的停顿。
    assign axis_vid_tready_normal = (pixel_cnt != 2'd3) ? 1'b1 : c2h_bram_fifo_wr_ready;
    
    // 关键：帧未活跃时强制 tready=1，丢弃旧数据，清空 v_vid_in_axi4s 内部 FIFO
    // 关键：非帧内强制 tready=1，持续冲刷 v_vid_in_axi4s 内部 FIFO，直到看到 axis_vid_tuser(SOF) 才开始打包/输出
    // 不使用 frame_active/sof_detected 参与 ready 计算，避免 SOF 周期被 backpressure 卡住，导致无法重对齐。
    assign axis_vid_tready = frame_in_progress ? axis_vid_tready_normal : 1'b1;
    
    //==========================================================================
    // VSYNC Interrupt Generation
    // 在 VSYNC 边沿产生中断，用于帧同步
    // usr_irq_req[0]: VSYNC 上升沿（帧开始）
    // usr_irq_req[1]: VSYNC 下降沿/DE 开始（有效数据开始）
    // usr_irq_req[2]: 帧传输完成（line_cnt 达到 1079 且 TLAST）
    // usr_irq_req[3]: 保留
    //==========================================================================
    
    // 同步 VSYNC 到 AXI 时钟域
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
    
    // VSYNC 边沿检测
    wire vsync_rising  = vsync_sync2 && !vsync_sync3;  // 上升沿
    wire vsync_falling = !vsync_sync2 && vsync_sync3;  // 下降沿
    
    // 帧完成检测（在 TLAST 且 line_cnt=1079 时）
    wire frame_complete = s_axis_c2h_tvalid_0 && s_axis_c2h_tlast_0 && s_axis_c2h_tready_0;
    
    // 中断请求寄存器（电平保持，直到 ACK）
    reg [3:0] irq_req_reg;
    
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            irq_req_reg <= 4'b0000;
        end else begin
            // IRQ 0: VSYNC 上升沿（帧开始）
            if (vsync_rising) begin
                irq_req_reg[0] <= 1'b1;
            end else if (usr_irq_ack[0]) begin
                irq_req_reg[0] <= 1'b0;
            end
            
            // IRQ 1: VSYNC 下降沿（有效数据即将开始）
            if (vsync_falling) begin
                irq_req_reg[1] <= 1'b1;
            end else if (usr_irq_ack[1]) begin
                irq_req_reg[1] <= 1'b0;
            end
            
            // IRQ 2: 帧传输完成
            if (frame_complete) begin
                irq_req_reg[2] <= 1'b1;
            end else if (usr_irq_ack[2]) begin
                irq_req_reg[2] <= 1'b0;
            end
            
            // IRQ 3: 保留
            irq_req_reg[3] <= 1'b0;
        end
    end
    
    assign usr_irq_req = irq_req_reg;
    
    //==========================================================================
    // Heartbeat LED
    //==========================================================================
    
    always @(posedge axi_aclk or negedge axi_aresetn) begin
        if (!axi_aresetn) begin
            heartbeat_cnt <= 27'd0;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
        end
    end
    
    //==========================================================================
    // LED Output
    //==========================================================================
    
    assign led[0] = heartbeat_cnt[26];       // Heartbeat (~1Hz)
    assign led[1] = user_lnk_up;             // PCIe Link Up
    assign led[2] = ctrl_enable;             // Video Enabled

endmodule
