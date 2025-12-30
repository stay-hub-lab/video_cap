//------------------------------------------------------------------------------
// Module: register_bank
// Description: 寄存器组模块
//              - 提供AXI-Lite从接口
//              - 包含控制寄存器和状态寄存器
//              - 支持中断生成和屏蔽
//
// Register Map:
//   0x0000 - VERSION    (RO)  版本号
//   0x0004 - CONTROL    (RW)  控制寄存器
//   0x0008 - STATUS     (RO)  状态寄存器
//   0x000C - IRQ_MASK   (RW)  中断屏蔽
//   0x0010 - IRQ_STATUS (RW1C) 中断状态
//   0x0100 - VID_FMT    (RW)  视频格式
//   0x0104 - VID_RES    (RO)  视频分辨率
//   0x0200 - BUF_ADDR0  (RW)  帧缓存地址0
//   0x0204 - BUF_ADDR1  (RW)  帧缓存地址1
//   0x0208 - BUF_ADDR2  (RW)  帧缓存地址2
//   0x0210 - BUF_IDX    (RO)  当前缓存索引
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module register_bank (
    input  wire         aclk,
    input  wire         aresetn,
    
    //--------------------------------------------------------------------------
    // AXI-Lite从接口
    //--------------------------------------------------------------------------
    input  wire [15:0]  s_axil_awaddr,
    input  wire         s_axil_awvalid,
    output wire         s_axil_awready,
    
    input  wire [31:0]  s_axil_wdata,
    input  wire [3:0]   s_axil_wstrb,
    input  wire         s_axil_wvalid,
    output wire         s_axil_wready,
    
    output reg  [1:0]   s_axil_bresp,
    output reg          s_axil_bvalid,
    input  wire         s_axil_bready,
    
    input  wire [15:0]  s_axil_araddr,
    input  wire         s_axil_arvalid,
    output wire         s_axil_arready,
    
    output reg  [31:0]  s_axil_rdata,
    output reg  [1:0]   s_axil_rresp,
    output reg          s_axil_rvalid,
    input  wire         s_axil_rready,
    
    //--------------------------------------------------------------------------
    // 控制输出
    //--------------------------------------------------------------------------
    output wire         ctrl_enable,        // 全局使能
    output wire         ctrl_soft_reset,    // 软复位
    output wire         ctrl_test_mode,     // 测试模式
    
    //--------------------------------------------------------------------------
    // 状态输入
    //--------------------------------------------------------------------------
    input  wire         sts_idle,           // 空闲状态
    input  wire         sts_mig_calib,      // MIG校准完成
    input  wire         sts_fifo_overflow,  // FIFO溢出
    input  wire         sts_pcie_link_up,   // PCIe链路状态
    
    //--------------------------------------------------------------------------
    // 中断输出
    //--------------------------------------------------------------------------
    output wire         irq_frame_done,     // 帧完成中断
    output wire         irq_error           // 错误中断
);

    //==========================================================================
    // 参数定义
    //==========================================================================
    
    // 地址偏移
    localparam ADDR_VERSION     = 16'h0000;
    localparam ADDR_CONTROL     = 16'h0004;
    localparam ADDR_STATUS      = 16'h0008;
    localparam ADDR_IRQ_MASK    = 16'h000C;
    localparam ADDR_IRQ_STATUS  = 16'h0010;
    localparam ADDR_VID_FMT     = 16'h0100;
    localparam ADDR_VID_RES     = 16'h0104;
    localparam ADDR_BUF_ADDR0   = 16'h0200;
    localparam ADDR_BUF_ADDR1   = 16'h0204;
    localparam ADDR_BUF_ADDR2   = 16'h0208;
    localparam ADDR_BUF_IDX     = 16'h0210;
    
    // 版本号 (日期格式: 0xYYYYMMDD)
    localparam VERSION = 32'h20251221;
    
    //==========================================================================
    // 寄存器定义
    //==========================================================================
    
    reg [31:0] reg_control;
    reg [31:0] reg_irq_mask;
    reg [31:0] reg_irq_status;
    reg [31:0] reg_vid_format;
    reg [31:0] reg_buf_addr0;
    reg [31:0] reg_buf_addr1;
    reg [31:0] reg_buf_addr2;
    reg [1:0]  reg_buf_idx;
    
    // AXI-Lite状态机
    reg        aw_ready;
    reg        w_ready;
    reg        ar_ready;
    reg [15:0] awaddr_reg;
    reg [15:0] araddr_reg;
    reg        write_pending;
    reg        read_pending;
    
    // 软复位脉冲
    reg        soft_reset_pulse;
    reg [3:0]  soft_reset_cnt;
    
    //==========================================================================
    // AXI-Lite写通道
    //==========================================================================
    
    assign s_axil_awready = aw_ready;
    assign s_axil_wready  = w_ready;
    
    // 写地址通道
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            aw_ready      <= 1'b1;
            awaddr_reg    <= 16'd0;
            write_pending <= 1'b0;
        end else begin
            if (aw_ready && s_axil_awvalid) begin
                aw_ready      <= 1'b0;
                awaddr_reg    <= s_axil_awaddr;
                write_pending <= 1'b1;
            end else if (s_axil_bvalid && s_axil_bready) begin
                aw_ready      <= 1'b1;
                write_pending <= 1'b0;
            end
        end
    end
    
    // 写数据通道
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            w_ready <= 1'b1;
        end else begin
            if (w_ready && s_axil_wvalid && write_pending) begin
                w_ready <= 1'b0;
            end else if (s_axil_bvalid && s_axil_bready) begin
                w_ready <= 1'b1;
            end
        end
    end
    
    // 写响应通道
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axil_bvalid <= 1'b0;
            s_axil_bresp  <= 2'b00;
        end else begin
            if (!w_ready && write_pending && !s_axil_bvalid) begin
                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00;  // OKAY
            end else if (s_axil_bready && s_axil_bvalid) begin
                s_axil_bvalid <= 1'b0;
            end
        end
    end
    
    //==========================================================================
    // 寄存器写入
    //==========================================================================
    
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            reg_control    <= 32'h0000_0005; // 默认开启使能(bit0)和测试模式(bit2)
            reg_irq_mask   <= 32'hFFFF_FFFF; // 默认屏蔽所有中断
            reg_irq_status <= 32'd0;
            reg_vid_format <= 32'd0;         // 默认RGB888
            reg_buf_addr0  <= 32'd0;
            reg_buf_addr1  <= 32'd0;
            reg_buf_addr2  <= 32'd0;
        end else if (!w_ready && write_pending) begin
            case (awaddr_reg)
                ADDR_CONTROL: begin
                    if (s_axil_wstrb[0]) reg_control[7:0]   <= s_axil_wdata[7:0];
                    if (s_axil_wstrb[1]) reg_control[15:8]  <= s_axil_wdata[15:8];
                    if (s_axil_wstrb[2]) reg_control[23:16] <= s_axil_wdata[23:16];
                    if (s_axil_wstrb[3]) reg_control[31:24] <= s_axil_wdata[31:24];
                end
                
                ADDR_IRQ_MASK: begin
                    if (s_axil_wstrb[0]) reg_irq_mask[7:0]   <= s_axil_wdata[7:0];
                    if (s_axil_wstrb[1]) reg_irq_mask[15:8]  <= s_axil_wdata[15:8];
                    if (s_axil_wstrb[2]) reg_irq_mask[23:16] <= s_axil_wdata[23:16];
                    if (s_axil_wstrb[3]) reg_irq_mask[31:24] <= s_axil_wdata[31:24];
                end
                
                ADDR_IRQ_STATUS: begin
                    // Write-1-to-Clear
                    reg_irq_status <= reg_irq_status & ~s_axil_wdata;
                end
                
                ADDR_VID_FMT: begin
                    if (s_axil_wstrb[0]) reg_vid_format[7:0]   <= s_axil_wdata[7:0];
                    if (s_axil_wstrb[1]) reg_vid_format[15:8]  <= s_axil_wdata[15:8];
                    if (s_axil_wstrb[2]) reg_vid_format[23:16] <= s_axil_wdata[23:16];
                    if (s_axil_wstrb[3]) reg_vid_format[31:24] <= s_axil_wdata[31:24];
                end
                
                ADDR_BUF_ADDR0: begin
                    if (s_axil_wstrb[0]) reg_buf_addr0[7:0]   <= s_axil_wdata[7:0];
                    if (s_axil_wstrb[1]) reg_buf_addr0[15:8]  <= s_axil_wdata[15:8];
                    if (s_axil_wstrb[2]) reg_buf_addr0[23:16] <= s_axil_wdata[23:16];
                    if (s_axil_wstrb[3]) reg_buf_addr0[31:24] <= s_axil_wdata[31:24];
                end
                
                ADDR_BUF_ADDR1: begin
                    if (s_axil_wstrb[0]) reg_buf_addr1[7:0]   <= s_axil_wdata[7:0];
                    if (s_axil_wstrb[1]) reg_buf_addr1[15:8]  <= s_axil_wdata[15:8];
                    if (s_axil_wstrb[2]) reg_buf_addr1[23:16] <= s_axil_wdata[23:16];
                    if (s_axil_wstrb[3]) reg_buf_addr1[31:24] <= s_axil_wdata[31:24];
                end
                
                ADDR_BUF_ADDR2: begin
                    if (s_axil_wstrb[0]) reg_buf_addr2[7:0]   <= s_axil_wdata[7:0];
                    if (s_axil_wstrb[1]) reg_buf_addr2[15:8]  <= s_axil_wdata[15:8];
                    if (s_axil_wstrb[2]) reg_buf_addr2[23:16] <= s_axil_wdata[23:16];
                    if (s_axil_wstrb[3]) reg_buf_addr2[31:24] <= s_axil_wdata[31:24];
                end
                
                default: ; // 忽略无效地址
            endcase
        end
    end
    
    //==========================================================================
    // AXI-Lite读通道
    //==========================================================================
    
    assign s_axil_arready = ar_ready;
    
    // 读地址通道
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ar_ready     <= 1'b1;
            araddr_reg   <= 16'd0;
            read_pending <= 1'b0;
        end else begin
            if (ar_ready && s_axil_arvalid) begin
                ar_ready     <= 1'b0;
                araddr_reg   <= s_axil_araddr;
                read_pending <= 1'b1;
            end else if (s_axil_rvalid && s_axil_rready) begin
                ar_ready     <= 1'b1;
                read_pending <= 1'b0;
            end
        end
    end
    
    // 读数据通道
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axil_rvalid <= 1'b0;
            s_axil_rresp  <= 2'b00;
            s_axil_rdata  <= 32'd0;
        end else begin
            if (read_pending && !s_axil_rvalid) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= 2'b00;  // OKAY
                
                case (araddr_reg)
                    ADDR_VERSION:    s_axil_rdata <= VERSION;
                    ADDR_CONTROL:    s_axil_rdata <= reg_control;
                    ADDR_STATUS:     s_axil_rdata <= {28'd0, sts_pcie_link_up, sts_fifo_overflow, sts_mig_calib, sts_idle};
                    ADDR_IRQ_MASK:   s_axil_rdata <= reg_irq_mask;
                    ADDR_IRQ_STATUS: s_axil_rdata <= reg_irq_status;
                    ADDR_VID_FMT:    s_axil_rdata <= reg_vid_format;
                    ADDR_VID_RES:    s_axil_rdata <= {16'd1080, 16'd1920}; // 固定1080P
                    ADDR_BUF_ADDR0:  s_axil_rdata <= reg_buf_addr0;
                    ADDR_BUF_ADDR1:  s_axil_rdata <= reg_buf_addr1;
                    ADDR_BUF_ADDR2:  s_axil_rdata <= reg_buf_addr2;
                    ADDR_BUF_IDX:    s_axil_rdata <= {30'd0, reg_buf_idx};
                    default:         s_axil_rdata <= 32'hDEAD_BEEF;
                endcase
            end else if (s_axil_rready && s_axil_rvalid) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end
    
    //==========================================================================
    // 控制信号输出
    //==========================================================================
    
    assign ctrl_enable     = reg_control[0];
    assign ctrl_test_mode  = reg_control[2];
    
    // 软复位脉冲生成 (写1自清零)
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            soft_reset_pulse <= 1'b0;
            soft_reset_cnt   <= 4'd0;
        end else begin
            if (reg_control[1] && soft_reset_cnt == 0) begin
                soft_reset_pulse <= 1'b1;
                soft_reset_cnt   <= 4'd15;
            end else if (soft_reset_cnt > 0) begin
                soft_reset_cnt <= soft_reset_cnt - 1;
                if (soft_reset_cnt == 1) begin
                    soft_reset_pulse <= 1'b0;
                end
            end
        end
    end
    
    assign ctrl_soft_reset = soft_reset_pulse;
    
    //==========================================================================
    // 中断生成
    //==========================================================================
    
    // 中断源: [0] Frame Done, [1] Error
    assign irq_frame_done = reg_irq_status[0] & ~reg_irq_mask[0];
    assign irq_error      = reg_irq_status[1] & ~reg_irq_mask[1];
    
    // TODO: 添加中断源触发逻辑
    // 这里需要连接到实际的帧完成信号和错误信号

endmodule
