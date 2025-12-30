#------------------------------------------------------------------------------
# PCIe视频采集卡 时序约束文件
# 目标器件: XC7K480TFFG1156-2
#
# 开发阶段: Phase 1 - 彩条生成器验证
#------------------------------------------------------------------------------

#==============================================================================
# 时钟定义
#==============================================================================

# 系统时钟 200MHz
create_clock -period 5.000 -name sys_clk_200m [get_ports sys_clk_200m]

# 视频像素时钟 148.5MHz (由PLL生成，Vivado会自动约束派生时钟)

#==============================================================================
# 虚假路径
#==============================================================================

# 复位按钮 - 异步输入
set_false_path -from [get_ports sys_rst_n]

#==============================================================================
# Clock groups (asynchronous)
#==============================================================================
# Video pixel clock (clk_wiz_video) and XDMA user clock (userclk2) are truly
# asynchronous; CDC is handled via Xilinx IP and explicit synchronizers.
set_clock_groups -asynchronous \
    -group [get_clocks clk_out1_clk_wiz_video] \
    -group [get_clocks userclk2]

#==============================================================================
# 输入/输出延迟
#==============================================================================

# LED输出 - 非关键路径
set_false_path -to [get_ports {led[*]}]

#==============================================================================
# Phase 2 时添加以下约束
#==============================================================================

# # PCIe参考时钟 100MHz
# create_clock -period 10.000 -name pcie_refclk [get_ports sys_clk_p]
#
# # 异步时钟组
# set_clock_groups -name async_clks -asynchronous #     -group [get_clocks sys_clk_200m] #     -group [get_clocks pcie_refclk]

set_property BITSTREAM.GENERAL.COMPRESS true [current_design]

