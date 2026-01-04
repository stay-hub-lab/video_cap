//------------------------------------------------------------------------------
// Module: register_bank
//
// AXI-Lite register bank for video_cap user BAR.
//
// Legacy/global registers are kept for backwards compatibility (map to ch0).
// A per-channel register window is added under 0x1000 to allow concurrent
// multi-channel streaming without mutual exclusion in the driver.
//
// Register Map (32-bit):
//   0x0000 - VERSION     (RO)
//   0x0004 - CONTROL     (RW)   legacy/global (mirrors CH0_CONTROL)
//   0x0008 - STATUS      (RO)   global status
//   0x000C - IRQ_MASK    (RW)
//   0x0010 - IRQ_STATUS  (RW1C)
//   0x0014 - CAPS        (RO)   capability / parameters
//   0x0100 - VID_FMT     (RW)   legacy/global (mirrors CH0_VID_FORMAT)
//   0x0104 - VID_RES     (RO)
//   0x0200 - BUF_ADDR0   (RW)
//   0x0204 - BUF_ADDR1   (RW)
//   0x0208 - BUF_ADDR2   (RW)
//   0x0210 - BUF_IDX     (RO)
//
// Per-channel window:
//   CH_BASE(ch) = 0x1000 + ch * CH_STRIDE
//     +0x00 CH_CONTROL     (RW)  same bit meaning as CONTROL
//     +0x04 CH_VID_FORMAT  (RW)  same meaning as VID_FMT
//     +0x08 CH_STATUS      (RO)  (currently mirrors global STATUS)
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module register_bank #(
    parameter integer CH_COUNT  = 2,
    parameter integer CH_STRIDE = 16'h0100  // per-channel stride in bytes
) (
    input  wire         aclk,
    input  wire         aresetn,

    // AXI-Lite slave
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

    // legacy/global control outputs (map to channel 0)
    output wire         ctrl0_enable,
    output wire         ctrl0_soft_reset,
    output wire         ctrl0_test_mode,
    output wire [7:0]   ctrl0_vid_format,

    output wire         ctrl1_enable,
    output wire         ctrl1_soft_reset,
    output wire         ctrl1_test_mode,
    output wire [7:0]   ctrl1_vid_format,

    // per-channel control outputs (AXI clock domain)
    output wire [CH_COUNT-1:0]   ctrl_enable_ch,
    output wire [CH_COUNT-1:0]   ctrl_test_mode_ch,
    output wire [CH_COUNT-1:0]   ctrl_soft_reset_ch,
    output wire [CH_COUNT*8-1:0] ctrl_vid_format_ch,

    // status inputs
    input  wire         sts_idle,
    input  wire         sts_mig_calib,
    input  wire         sts_fifo_overflow,
    input  wire         sts_pcie_link_up,

    // interrupts (placeholders; hook up later if needed)
    output wire         irq_frame_done,
    output wire         irq_error
);

    //--------------------------------------------------------------------------
    // Address map
    //--------------------------------------------------------------------------
    localparam [15:0] ADDR_VERSION    = 16'h0000;
    localparam [15:0] ADDR_CONTROL    = 16'h0004;
    localparam [15:0] ADDR_STATUS     = 16'h0008;
    localparam [15:0] ADDR_IRQ_MASK   = 16'h000C;
    localparam [15:0] ADDR_IRQ_STATUS = 16'h0010;
    localparam [15:0] ADDR_CAPS       = 16'h0014;
    localparam [15:0] ADDR_VID_FMT    = 16'h0100;
    localparam [15:0] ADDR_VID_RES    = 16'h0104;
    localparam [15:0] ADDR_BUF_ADDR0  = 16'h0200;
    localparam [15:0] ADDR_BUF_ADDR1  = 16'h0204;
    localparam [15:0] ADDR_BUF_ADDR2  = 16'h0208;
    localparam [15:0] ADDR_BUF_IDX    = 16'h0210;

    localparam [15:0] ADDR_CH_BASE    = 16'h1000;
    localparam [15:0] CH_OFF_CONTROL  = 16'h0000;
    localparam [15:0] CH_OFF_VID_FMT  = 16'h0004;
    localparam [15:0] CH_OFF_STATUS   = 16'h0008;

    //--------------------------------------------------------------------------
    // Constants / defaults
    //--------------------------------------------------------------------------
    localparam [31:0] VERSION         = 32'h20251221;
    localparam [31:0] CONTROL_DEFAULT = 32'h0000_0005; // enable(bit0) + test(bit2)
    localparam [31:0] VID_FMT_DEFAULT = 32'd0;         // RGB888

    // REG_CAPS: [0]=per-ch ctrl, [1]=per-ch fmt, [15:8]=ch_count, [31:16]=stride(bytes)
    localparam [31:0] REG_CAPS_VALUE =
        (32'h0000_0003 |
         ((CH_COUNT[7:0]) << 8) |
         ((CH_STRIDE[15:0]) << 16));

    //--------------------------------------------------------------------------
    // Registers
    //--------------------------------------------------------------------------
    reg [31:0] reg_control;
    reg [31:0] reg_irq_mask;
    reg [31:0] reg_irq_status;
    reg [31:0] reg_vid_format;
    reg [31:0] reg_buf_addr0;
    reg [31:0] reg_buf_addr1;
    reg [31:0] reg_buf_addr2;
    reg [1:0]  reg_buf_idx;

    reg [31:0] reg_ch_control    [0:CH_COUNT-1];
    reg [31:0] reg_ch_vid_format [0:CH_COUNT-1];

    // write-1-to-pulse start strobe, per-channel
    reg [CH_COUNT-1:0] soft_reset_start_ch;
    reg [CH_COUNT-1:0] soft_reset_pulse_ch_r;
    reg [3:0]          soft_reset_cnt_ch [0:CH_COUNT-1];

    //--------------------------------------------------------------------------
    // AXI-Lite write channel (single outstanding write)
    //--------------------------------------------------------------------------
    reg        have_aw;
    reg        have_w;
    reg [15:0] awaddr_reg;
    reg [31:0] wdata_reg;
    reg [3:0]  wstrb_reg;

    assign s_axil_awready = (!have_aw) && (!s_axil_bvalid);
    assign s_axil_wready  = (!have_w)  && (!s_axil_bvalid);

    //--------------------------------------------------------------------------
    // AXI-Lite read channel (single outstanding read)
    //--------------------------------------------------------------------------
    reg        ar_pending;
    reg [15:0] araddr_reg;

    assign s_axil_arready = (!ar_pending) && (!s_axil_rvalid);

    //--------------------------------------------------------------------------
    // per-channel address decode (combinational)
    //--------------------------------------------------------------------------
    integer di_wr;
    integer di_rd;
    integer base_wr;
    integer base_rd;
    integer awaddr_i;
    integer araddr_i;

    reg        wr_is_ch;
    reg [7:0]  wr_ch_idx;
    reg [15:0] wr_ch_off;

    reg        rd_is_ch;
    reg [7:0]  rd_ch_idx;
    reg [15:0] rd_ch_off;

    always @* begin
        wr_is_ch  = 1'b0;
        wr_ch_idx = 8'd0;
        wr_ch_off = 16'd0;
        awaddr_i  = awaddr_reg;

        for (di_wr = 0; di_wr < CH_COUNT; di_wr = di_wr + 1) begin
            base_wr = ADDR_CH_BASE + (di_wr * CH_STRIDE);
            if ((awaddr_i >= base_wr) && (awaddr_i < (base_wr + CH_STRIDE))) begin
                wr_is_ch  = 1'b1;
                wr_ch_idx = di_wr[7:0];
                wr_ch_off = awaddr_i - base_wr;
            end
        end
    end

    always @* begin
        rd_is_ch  = 1'b0;
        rd_ch_idx = 8'd0;
        rd_ch_off = 16'd0;
        araddr_i  = araddr_reg;

        for (di_rd = 0; di_rd < CH_COUNT; di_rd = di_rd + 1) begin
            base_rd = ADDR_CH_BASE + (di_rd * CH_STRIDE);
            if ((araddr_i >= base_rd) && (araddr_i < (base_rd + CH_STRIDE))) begin
                rd_is_ch  = 1'b1;
                rd_ch_idx = di_rd[7:0];
                rd_ch_off = araddr_i - base_rd;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Register write + AXI write response
    //--------------------------------------------------------------------------
    integer ri;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            have_aw <= 1'b0;
            have_w  <= 1'b0;
            awaddr_reg <= 16'd0;
            wdata_reg  <= 32'd0;
            wstrb_reg  <= 4'd0;

            s_axil_bvalid <= 1'b0;
            s_axil_bresp  <= 2'b00;

            reg_control    <= CONTROL_DEFAULT;
            reg_irq_mask   <= 32'hFFFF_FFFF;
            reg_irq_status <= 32'd0;
            reg_vid_format <= VID_FMT_DEFAULT;
            reg_buf_addr0  <= 32'd0;
            reg_buf_addr1  <= 32'd0;
            reg_buf_addr2  <= 32'd0;
            reg_buf_idx    <= 2'd0;

            soft_reset_start_ch <= {CH_COUNT{1'b0}};

            for (ri = 0; ri < CH_COUNT; ri = ri + 1) begin
                reg_ch_control[ri]    <= (ri == 0) ? CONTROL_DEFAULT : 32'd0;
                reg_ch_vid_format[ri] <= VID_FMT_DEFAULT;
            end
        end else begin
            // default: 1-cycle strobe
            soft_reset_start_ch <= {CH_COUNT{1'b0}};

            // capture AW
            if (s_axil_awready && s_axil_awvalid) begin
                have_aw   <= 1'b1;
                awaddr_reg <= s_axil_awaddr;
            end

            // capture W
            if (s_axil_wready && s_axil_wvalid) begin
                have_w   <= 1'b1;
                wdata_reg <= s_axil_wdata;
                wstrb_reg <= s_axil_wstrb;
            end

            // execute write when both address and data present and no response pending
            if (have_aw && have_w && !s_axil_bvalid) begin
                // default OKAY
                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00;

                case (awaddr_reg)
                    ADDR_CONTROL: begin
                        if (wstrb_reg[0]) begin
                            reg_control[7:0] <= {wdata_reg[7:2], 1'b0, wdata_reg[0]};
                            reg_ch_control[0][7:0] <= {wdata_reg[7:2], 1'b0, wdata_reg[0]};
                            if (wdata_reg[1])
                                soft_reset_start_ch[0] <= 1'b1;
                        end
                        if (wstrb_reg[1]) begin
                            reg_control[15:8] <= wdata_reg[15:8];
                            reg_ch_control[0][15:8] <= wdata_reg[15:8];
                        end
                        if (wstrb_reg[2]) begin
                            reg_control[23:16] <= wdata_reg[23:16];
                            reg_ch_control[0][23:16] <= wdata_reg[23:16];
                        end
                        if (wstrb_reg[3]) begin
                            reg_control[31:24] <= wdata_reg[31:24];
                            reg_ch_control[0][31:24] <= wdata_reg[31:24];
                        end
                    end

                    ADDR_IRQ_MASK: begin
                        if (wstrb_reg[0]) reg_irq_mask[7:0]   <= wdata_reg[7:0];
                        if (wstrb_reg[1]) reg_irq_mask[15:8]  <= wdata_reg[15:8];
                        if (wstrb_reg[2]) reg_irq_mask[23:16] <= wdata_reg[23:16];
                        if (wstrb_reg[3]) reg_irq_mask[31:24] <= wdata_reg[31:24];
                    end

                    ADDR_IRQ_STATUS: begin
                        // write-1-to-clear
                        reg_irq_status <= reg_irq_status & ~wdata_reg;
                    end

                    ADDR_VID_FMT: begin
                        if (wstrb_reg[0]) begin
                            reg_vid_format[7:0] <= wdata_reg[7:0];
                            reg_ch_vid_format[0][7:0] <= wdata_reg[7:0];
                        end
                        if (wstrb_reg[1]) begin
                            reg_vid_format[15:8] <= wdata_reg[15:8];
                            reg_ch_vid_format[0][15:8] <= wdata_reg[15:8];
                        end
                        if (wstrb_reg[2]) begin
                            reg_vid_format[23:16] <= wdata_reg[23:16];
                            reg_ch_vid_format[0][23:16] <= wdata_reg[23:16];
                        end
                        if (wstrb_reg[3]) begin
                            reg_vid_format[31:24] <= wdata_reg[31:24];
                            reg_ch_vid_format[0][31:24] <= wdata_reg[31:24];
                        end
                    end

                    ADDR_BUF_ADDR0: begin
                        if (wstrb_reg[0]) reg_buf_addr0[7:0]   <= wdata_reg[7:0];
                        if (wstrb_reg[1]) reg_buf_addr0[15:8]  <= wdata_reg[15:8];
                        if (wstrb_reg[2]) reg_buf_addr0[23:16] <= wdata_reg[23:16];
                        if (wstrb_reg[3]) reg_buf_addr0[31:24] <= wdata_reg[31:24];
                    end

                    ADDR_BUF_ADDR1: begin
                        if (wstrb_reg[0]) reg_buf_addr1[7:0]   <= wdata_reg[7:0];
                        if (wstrb_reg[1]) reg_buf_addr1[15:8]  <= wdata_reg[15:8];
                        if (wstrb_reg[2]) reg_buf_addr1[23:16] <= wdata_reg[23:16];
                        if (wstrb_reg[3]) reg_buf_addr1[31:24] <= wdata_reg[31:24];
                    end

                    ADDR_BUF_ADDR2: begin
                        if (wstrb_reg[0]) reg_buf_addr2[7:0]   <= wdata_reg[7:0];
                        if (wstrb_reg[1]) reg_buf_addr2[15:8]  <= wdata_reg[15:8];
                        if (wstrb_reg[2]) reg_buf_addr2[23:16] <= wdata_reg[23:16];
                        if (wstrb_reg[3]) reg_buf_addr2[31:24] <= wdata_reg[31:24];
                    end

                    default: begin
                        if (wr_is_ch) begin
                            case (wr_ch_off)
                                CH_OFF_CONTROL: begin
                                    if (wstrb_reg[0]) begin
                                        reg_ch_control[wr_ch_idx][7:0] <= {wdata_reg[7:2], 1'b0, wdata_reg[0]};
                                        if (wr_ch_idx == 0)
                                            reg_control[7:0] <= {wdata_reg[7:2], 1'b0, wdata_reg[0]};
                                        if (wdata_reg[1])
                                            soft_reset_start_ch[wr_ch_idx] <= 1'b1;
                                    end
                                    if (wstrb_reg[1]) begin
                                        reg_ch_control[wr_ch_idx][15:8] <= wdata_reg[15:8];
                                        if (wr_ch_idx == 0)
                                            reg_control[15:8] <= wdata_reg[15:8];
                                    end
                                    if (wstrb_reg[2]) begin
                                        reg_ch_control[wr_ch_idx][23:16] <= wdata_reg[23:16];
                                        if (wr_ch_idx == 0)
                                            reg_control[23:16] <= wdata_reg[23:16];
                                    end
                                    if (wstrb_reg[3]) begin
                                        reg_ch_control[wr_ch_idx][31:24] <= wdata_reg[31:24];
                                        if (wr_ch_idx == 0)
                                            reg_control[31:24] <= wdata_reg[31:24];
                                    end
                                end

                                CH_OFF_VID_FMT: begin
                                    if (wstrb_reg[0]) begin
                                        reg_ch_vid_format[wr_ch_idx][7:0] <= wdata_reg[7:0];
                                        if (wr_ch_idx == 0)
                                            reg_vid_format[7:0] <= wdata_reg[7:0];
                                    end
                                    if (wstrb_reg[1]) begin
                                        reg_ch_vid_format[wr_ch_idx][15:8] <= wdata_reg[15:8];
                                        if (wr_ch_idx == 0)
                                            reg_vid_format[15:8] <= wdata_reg[15:8];
                                    end
                                    if (wstrb_reg[2]) begin
                                        reg_ch_vid_format[wr_ch_idx][23:16] <= wdata_reg[23:16];
                                        if (wr_ch_idx == 0)
                                            reg_vid_format[23:16] <= wdata_reg[23:16];
                                    end
                                    if (wstrb_reg[3]) begin
                                        reg_ch_vid_format[wr_ch_idx][31:24] <= wdata_reg[31:24];
                                        if (wr_ch_idx == 0)
                                            reg_vid_format[31:24] <= wdata_reg[31:24];
                                    end
                                end

                                default: begin
                                    // ignore
                                end
                            endcase
                        end
                    end
                endcase

                have_aw <= 1'b0;
                have_w  <= 1'b0;
            end

            // write response handshake
            if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // soft reset pulse generation (per-channel, AXI clock domain)
    //--------------------------------------------------------------------------
    integer si;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            for (si = 0; si < CH_COUNT; si = si + 1) begin
                soft_reset_pulse_ch_r[si] <= 1'b0;
                soft_reset_cnt_ch[si] <= 4'd0;
            end
        end else begin
            for (si = 0; si < CH_COUNT; si = si + 1) begin
                if (soft_reset_start_ch[si] && (soft_reset_cnt_ch[si] == 0)) begin
                    soft_reset_pulse_ch_r[si] <= 1'b1;
                    soft_reset_cnt_ch[si] <= 4'd15;
                end else if (soft_reset_cnt_ch[si] > 0) begin
                    soft_reset_cnt_ch[si] <= soft_reset_cnt_ch[si] - 1;
                    if (soft_reset_cnt_ch[si] == 1) begin
                        soft_reset_pulse_ch_r[si] <= 1'b0;
                    end
                end else begin
                    soft_reset_pulse_ch_r[si] <= 1'b0;
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // AXI-Lite read
    //--------------------------------------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ar_pending <= 1'b0;
            araddr_reg <= 16'd0;
            s_axil_rvalid <= 1'b0;
            s_axil_rresp  <= 2'b00;
            s_axil_rdata  <= 32'd0;
        end else begin
            if (s_axil_arready && s_axil_arvalid) begin
                ar_pending <= 1'b1;
                araddr_reg <= s_axil_araddr;
            end

            if (ar_pending && !s_axil_rvalid) begin
                ar_pending <= 1'b0;
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= 2'b00;

                if (rd_is_ch) begin
                    case (rd_ch_off)
                        CH_OFF_CONTROL: s_axil_rdata <= reg_ch_control[rd_ch_idx];
                        CH_OFF_VID_FMT: s_axil_rdata <= reg_ch_vid_format[rd_ch_idx];
                        CH_OFF_STATUS:  s_axil_rdata <= {28'd0, sts_pcie_link_up, sts_fifo_overflow, sts_mig_calib, sts_idle};
                        default:        s_axil_rdata <= 32'hDEAD_BEEF;
                    endcase
                end else begin
                    case (araddr_reg)
                        ADDR_VERSION:    s_axil_rdata <= VERSION;
                        ADDR_CONTROL:    s_axil_rdata <= reg_control;
                        ADDR_STATUS:     s_axil_rdata <= {28'd0, sts_pcie_link_up, sts_fifo_overflow, sts_mig_calib, sts_idle};
                        ADDR_IRQ_MASK:   s_axil_rdata <= reg_irq_mask;
                        ADDR_IRQ_STATUS: s_axil_rdata <= reg_irq_status;
                        ADDR_CAPS:       s_axil_rdata <= REG_CAPS_VALUE;
                        ADDR_VID_FMT:    s_axil_rdata <= reg_vid_format;
                        ADDR_VID_RES:    s_axil_rdata <= {16'd1080, 16'd1920}; // fixed 1080P
                        ADDR_BUF_ADDR0:  s_axil_rdata <= reg_buf_addr0;
                        ADDR_BUF_ADDR1:  s_axil_rdata <= reg_buf_addr1;
                        ADDR_BUF_ADDR2:  s_axil_rdata <= reg_buf_addr2;
                        ADDR_BUF_IDX:    s_axil_rdata <= {30'd0, reg_buf_idx};
                        default:         s_axil_rdata <= 32'hDEAD_BEEF;
                    endcase
                end
            end

            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Control outputs
    //--------------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < CH_COUNT; gi = gi + 1) begin : gen_ctrl_out
            assign ctrl_enable_ch[gi]     = reg_ch_control[gi][0];
            assign ctrl_test_mode_ch[gi]  = reg_ch_control[gi][2];
            assign ctrl_soft_reset_ch[gi] = soft_reset_pulse_ch_r[gi];
            assign ctrl_vid_format_ch[(gi*8)+7:(gi*8)] = reg_ch_vid_format[gi][7:0];
        end
    endgenerate

    assign ctrl0_enable     = ctrl_enable_ch[0];
    assign ctrl0_test_mode  = ctrl_test_mode_ch[0];
    assign ctrl0_soft_reset = ctrl_soft_reset_ch[0];
    assign ctrl0_vid_format = ctrl_vid_format_ch[7:0];

    assign ctrl1_enable     = ctrl_enable_ch[1];
    assign ctrl1_test_mode  = ctrl_test_mode_ch[1];
    assign ctrl1_soft_reset = ctrl_soft_reset_ch[1];
    assign ctrl1_vid_format = ctrl_vid_format_ch[15:8];
    //--------------------------------------------------------------------------
    // IRQ generation (placeholder)
    //--------------------------------------------------------------------------
    assign irq_frame_done = reg_irq_status[0] & ~reg_irq_mask[0];
    assign irq_error      = reg_irq_status[1] & ~reg_irq_mask[1];

endmodule
