//------------------------------------------------------------------------------
// Module: vid_to_axi_stream
// Description: 视频信号到AXI-Stream转换模块
//              - 将标准视频时序信号转换为AXI-Stream协议
//              - 包含异步FIFO进行跨时钟域传输
//              - 支持帧起始标记 (SOF via TUSER)
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module vid_to_axi_stream (
    // 视频时钟域
    input  wire         vid_clk,            // 视频像素时钟
    input  wire         vid_rst_n,          // 视频复位 (Active Low)
    
    // 视频输入
    input  wire [23:0]  vid_data,           // 视频数据 (RGB888)
    input  wire         vid_vsync,          // 场同步
    input  wire         vid_hsync,          // 行同步
    input  wire         vid_de,             // 数据使能
    
    // AXI-Stream时钟域
    input  wire         m_axis_aclk,        // AXI-Stream时钟
    input  wire         m_axis_aresetn,     // AXI-Stream复位 (Active Low)
    
    // AXI-Stream输出
    output wire [23:0]  m_axis_tdata,       // 数据
    output wire         m_axis_tvalid,      // 有效
    input  wire         m_axis_tready,      // 就绪
    output wire         m_axis_tlast,       // 行结束
    output wire         m_axis_tuser        // 帧起始 (SOF)
);

    //==========================================================================
    // 内部信号
    //==========================================================================
    
    // 视频时钟域信号
    reg         vid_de_d1;
    reg         vid_vsync_d1;
    wire        vid_de_rising;
    wire        vid_de_falling;
    wire        vid_vsync_rising;
    
    reg         sof_flag;                   // 帧起始标志
    reg         first_pixel;                // 第一个像素标志
    
    // FIFO接口
    wire [25:0] fifo_din;                   // {SOF, EOL, DATA[23:0]}
    wire        fifo_wr_en;
    wire        fifo_full;
    
    wire [25:0] fifo_dout;
    wire        fifo_rd_en;
    wire        fifo_empty;
    
    //==========================================================================
    // 边沿检测
    //==========================================================================
    
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            vid_de_d1    <= 1'b0;
            vid_vsync_d1 <= 1'b0;
        end else begin
            vid_de_d1    <= vid_de;
            vid_vsync_d1 <= vid_vsync;
        end
    end
    
    assign vid_de_rising   = vid_de & ~vid_de_d1;
    assign vid_de_falling  = ~vid_de & vid_de_d1;
    assign vid_vsync_rising = vid_vsync & ~vid_vsync_d1;
    
    //==========================================================================
    // 帧起始标志 (SOF)
    //==========================================================================
    
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            sof_flag    <= 1'b0;
            first_pixel <= 1'b0;
        end else begin
            // VSYNC上升沿后的第一个有效像素标记SOF
            if (vid_vsync_rising) begin
                sof_flag <= 1'b1;
            end else if (vid_de && sof_flag) begin
                sof_flag    <= 1'b0;
                first_pixel <= 1'b1;
            end else begin
                first_pixel <= 1'b0;
            end
        end
    end
    
    //==========================================================================
    // 写入FIFO
    //==========================================================================
    
    // EOL: 当当前像素是行内最后一个像素时标记
    // 检测方法: 当前DE=1且下一个时钟DE将变为0 (vid_de_d1=1 且 vid_de=0的前一拍)
    // 简化: 在DE下降沿的前一个像素标记，即当vid_de=1且即将变0时
    // 实际实现: 使用流水线，在检测到下降沿时补充标记上一个写入的像素
    
    // 方案: 延迟写入，在写入时检查未来DE状态
    wire eol_flag;
    assign eol_flag = vid_de_d1 & ~vid_de;  // DE下降沿时标记前一个像素的EOL
    
    // FIFO数据格式: {SOF(1bit), EOL(1bit), DATA(24bit)}
    // 使用流水线数据和标志
    reg [23:0] vid_data_d1;
    reg        first_pixel_d1;
    reg        data_valid_d1;
    
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            vid_data_d1    <= 24'd0;
            first_pixel_d1 <= 1'b0;
            data_valid_d1  <= 1'b0;
        end else begin
            vid_data_d1    <= vid_data;
            first_pixel_d1 <= first_pixel;
            data_valid_d1  <= vid_de & ~fifo_full;
        end
    end
    
    // 写入FIFO: 使用延迟的数据，这样可以在EOL时正确标记
    assign fifo_din   = {first_pixel_d1, eol_flag, vid_data_d1};
    assign fifo_wr_en = data_valid_d1;
    
    //==========================================================================
    // 异步FIFO实例化
    //==========================================================================
    
    async_fifo_vid #(
        .DATA_WIDTH (26),
        .ADDR_WIDTH (12)                    // 4096深度 (足够缓冲1行1920像素)
    ) u_async_fifo (
        // 写端口 (视频时钟域)
        .wr_clk     (vid_clk),
        .wr_rst_n   (vid_rst_n),
        .wr_en      (fifo_wr_en),
        .wr_data    (fifo_din),
        .full       (fifo_full),
        
        // 读端口 (AXI时钟域)
        .rd_clk     (m_axis_aclk),
        .rd_rst_n   (m_axis_aresetn),
        .rd_en      (fifo_rd_en),
        .rd_data    (fifo_dout),
        .empty      (fifo_empty)
    );
    
    //==========================================================================
    // AXI-Stream输出
    //==========================================================================
    
    assign m_axis_tvalid = ~fifo_empty;
    assign m_axis_tdata  = fifo_dout[23:0];
    assign m_axis_tlast  = fifo_dout[24];   // EOL
    assign m_axis_tuser  = fifo_dout[25];   // SOF
    
    assign fifo_rd_en    = m_axis_tvalid & m_axis_tready;

endmodule


//------------------------------------------------------------------------------
// 异步FIFO模块 (Gray码指针)
//------------------------------------------------------------------------------
module async_fifo_vid #(
    parameter DATA_WIDTH = 26,
    parameter ADDR_WIDTH = 10
)(
    // 写端口
    input  wire                     wr_clk,
    input  wire                     wr_rst_n,
    input  wire                     wr_en,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output wire                     full,
    
    // 读端口
    input  wire                     rd_clk,
    input  wire                     rd_rst_n,
    input  wire                     rd_en,
    output wire [DATA_WIDTH-1:0]    rd_data,
    output wire                     empty
);

    localparam DEPTH = 1 << ADDR_WIDTH;
    
    // 存储器
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    
    // 指针 (二进制)
    reg [ADDR_WIDTH:0] wr_ptr_bin;
    reg [ADDR_WIDTH:0] rd_ptr_bin;
    
    // 指针 (格雷码)
    wire [ADDR_WIDTH:0] wr_ptr_gray;
    wire [ADDR_WIDTH:0] rd_ptr_gray;
    
    // 同步后的指针
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;
    
    //--------------------------------------------------------------------------
    // 二进制转格雷码
    //--------------------------------------------------------------------------
    assign wr_ptr_gray = wr_ptr_bin ^ (wr_ptr_bin >> 1);
    assign rd_ptr_gray = rd_ptr_bin ^ (rd_ptr_bin >> 1);
    
    //--------------------------------------------------------------------------
    // 写指针逻辑
    //--------------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin <= 0;
        end else if (wr_en && !full) begin
            wr_ptr_bin <= wr_ptr_bin + 1;
        end
    end
    
    // 写入存储器
    always @(posedge wr_clk) begin
        if (wr_en && !full) begin
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end
    
    //--------------------------------------------------------------------------
    // 读指针逻辑
    //--------------------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin <= 0;
        end else if (rd_en && !empty) begin
            rd_ptr_bin <= rd_ptr_bin + 1;
        end
    end
    
    // 读取存储器
    assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
    
    //--------------------------------------------------------------------------
    // 跨时钟域同步 (写指针 -> 读时钟域)
    //--------------------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= 0;
            wr_ptr_gray_sync2 <= 0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end
    
    //--------------------------------------------------------------------------
    // 跨时钟域同步 (读指针 -> 写时钟域)
    //--------------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= 0;
            rd_ptr_gray_sync2 <= 0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end
    
    //--------------------------------------------------------------------------
    // 满/空标志
    //--------------------------------------------------------------------------
    // 满: 写指针追上读指针 (格雷码比较)
    assign full = (wr_ptr_gray == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1], 
                                    rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});
    
    // 空: 读写指针相等
    assign empty = (rd_ptr_gray == wr_ptr_gray_sync2);

endmodule
