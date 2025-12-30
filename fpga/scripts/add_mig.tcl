#------------------------------------------------------------------------------
# PCIe视频采集卡 - Phase 3: 添加DDR3 (MIG) 支持
# 目标器件: XC7K480TFFG1156-2
#
# 前置条件:
#   1. Phase 2 完成 (XDMA已集成)
#
# 使用方法:
#   在Vivado Tcl Console中执行:
#   source add_mig.tcl
#
# 注意:
#   MIG IP需要根据实际硬件配置DDR3参数
#   本脚本仅创建基本框架，需手动在GUI中完成配置
#------------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize "$script_dir/.."]
set project_path "$project_dir/project/video_cap.xpr"

# 检查工程是否存在
if {![file exists $project_path]} {
    puts "ERROR: 工程不存在，请先运行 create_project.tcl"
    return
}

puts "============================================="
puts "Phase 3: 添加DDR3 (MIG) 支持"
puts "============================================="

# 打开工程
open_project $project_path

#------------------------------------------------------------------------------
# MIG配置说明
#------------------------------------------------------------------------------
puts ""
puts ">>> MIG IP需要手动配置"
puts ""
puts "MIG配置步骤:"
puts "  1. 在IP Catalog中搜索 'MIG'"
puts "  2. 选择 'Memory Interface Generator'"
puts "  3. 配置参数 (参考XC7K480T_MicroBlaze_Test):"
puts "     - Memory Part: 根据实际硬件选择"
puts "     - Data Width: 64-bit 或 128-bit"
puts "     - Clock Period: 根据DDR3规格"
puts ""
puts "  4. 在 'Memory Options' 页面:"
puts "     - 选择 AXI4 接口"
puts "     - 设置 Data Width"
puts ""
puts "  5. 在 'FPGA Options' 页面:"
puts "     - 选择正确的Bank和管脚"
puts ""
puts ">>> 参考工程:"
puts "    G:/Xilinx/XC7K480T/project/video_cap/XC7K480T_MicroBlaze_Test"
puts "    查看其中的MIG配置: microblaze_mig_7series_0_0"
puts ""

#------------------------------------------------------------------------------
# 查看参考工程的MIG配置
#------------------------------------------------------------------------------
puts ">>> 尝试读取参考工程的MIG配置..."

set ref_mig_xci "$project_dir/../XC7K480T_MicroBlaze_Test/XC7K480T_MicroBlaze_Test.srcs/sources_1/bd/microblaze/ip/microblaze_mig_7series_0_0/microblaze_mig_7series_0_0.xci"

if {[file exists $ref_mig_xci]} {
    puts "  参考MIG配置文件存在: $ref_mig_xci"
    puts "  建议: 在IP Catalog中创建MIG时参考此配置"
} else {
    puts "  参考MIG配置文件未找到"
}

puts ""
puts "============================================="
puts "请手动在Vivado GUI中配置MIG IP"
puts "============================================="
