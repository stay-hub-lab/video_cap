#------------------------------------------------------------------------------
# PCIe视频采集卡 编译脚本
# 使用方法:
#   在Vivado Tcl Console中执行: source build.tcl
#------------------------------------------------------------------------------

# 获取脚本目录
set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize "$script_dir/.."]
set project_path "$project_dir/project/video_cap.xpr"

# 检查工程是否存在
if {![file exists $project_path]} {
    puts "ERROR: 工程文件不存在: $project_path"
    puts "请先运行 create_project.tcl 创建工程"
    return
}

# 打开工程
open_project $project_path

#------------------------------------------------------------------------------
# 综合
#------------------------------------------------------------------------------
puts "============================================="
puts "开始综合..."
puts "============================================="

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

# 检查综合结果
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: 综合失败!"
    return
}

# 打开综合设计查看报告
open_run synth_1
report_utilization -file "$project_dir/reports/utilization_synth.rpt"
report_timing_summary -file "$project_dir/reports/timing_synth.rpt"

puts "综合完成!"

#------------------------------------------------------------------------------
# 实现
#------------------------------------------------------------------------------
puts "============================================="
puts "开始实现..."
puts "============================================="

launch_runs impl_1 -jobs 8
wait_on_run impl_1

# 检查实现结果
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: 实现失败!"
    return
}

# 打开实现设计查看报告
open_run impl_1
report_utilization -file "$project_dir/reports/utilization_impl.rpt"
report_timing_summary -file "$project_dir/reports/timing_impl.rpt"
report_power -file "$project_dir/reports/power.rpt"

puts "实现完成!"

#------------------------------------------------------------------------------
# 生成比特流
#------------------------------------------------------------------------------
puts "============================================="
puts "生成比特流..."
puts "============================================="

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

# 复制比特流到输出目录
file mkdir "$project_dir/output"
file copy -force "$project_dir/project/video_cap.runs/impl_1/video_cap_top.bit" "$project_dir/output/"

puts "============================================="
puts "编译完成!"
puts "比特流位置: $project_dir/output/video_cap_top.bit"
puts "============================================="

# 关闭工程
close_project
