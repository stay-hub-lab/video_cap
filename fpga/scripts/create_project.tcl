#------------------------------------------------------------------------------
# PCIe Video Capture Card - FPGA Project Creation Script
# Target Device: XC7K480TFFG1156-2
# Tool: Vivado 2024.2
# 
# Usage:
#   1. Open Vivado 2024.2
#   2. In Tcl Console:
#      cd G:/Xilinx/XC7K480T/project/video_cap/fpga/scripts
#      source create_project.tcl
#------------------------------------------------------------------------------

# Get script directory
set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize "$script_dir/.."]

# Project configuration
set project_name "video_cap"
set part_name "xc7k480tffg1156-2"

puts "============================================="
puts "PCIe Video Capture Card FPGA Project"
puts "============================================="
puts "Project Dir: $project_dir"
puts "Target Part: $part_name"
puts "============================================="

#------------------------------------------------------------------------------
# Check if project is already open
#------------------------------------------------------------------------------
set current_proj [current_project -quiet]
if {$current_proj ne ""} {
    if {[get_property NAME $current_proj] eq $project_name} {
        puts "\n>>> Project '$project_name' is already open."
        puts "    Skipping project creation, will add missing components..."
    } else {
        puts "\n>>> Another project is open: $current_proj"
        puts "    Closing it first..."
        close_project
        set current_proj ""
    }
}

#------------------------------------------------------------------------------
# Create Project (if not already open)
#------------------------------------------------------------------------------
if {$current_proj eq ""} {
    puts "\n>>> Creating Vivado project..."
    create_project $project_name "$project_dir/project" -part $part_name -force

    # Set project properties
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]
    set_property default_lib work [current_project]
}

#------------------------------------------------------------------------------
# Add HDL source files (if not already added)
#------------------------------------------------------------------------------
puts "\n>>> Checking HDL source files..."

set hdl_files [list \
    "$project_dir/src/hdl/video_cap_top.v" \
    "$project_dir/src/hdl/video_pattern_gen/video_pattern_gen.v" \
    "$project_dir/src/hdl/video_pattern_gen/timing_gen.v" \
    "$project_dir/src/hdl/video_pattern_gen/color_bar_gen.v" \
    "$project_dir/src/hdl/video_pattern_gen/vid_to_axi_stream.v" \
    "$project_dir/src/hdl/common/register_bank.v" \
]

set files_added 0
foreach f $hdl_files {
    if {[file exists $f]} {
        # Check if file is already in project
        set fname [file tail $f]
        set existing [get_files -quiet $fname]
        if {$existing eq ""} {
            add_files -norecurse $f
            puts "  Added: $fname"
            incr files_added
        } else {
            puts "  Exists: $fname"
        }
    } else {
        puts "  SKIP: File not found - [file tail $f]"
    }
}
puts "  Total new files added: $files_added"

# Set top module
set_property top video_cap_top [current_fileset]

#------------------------------------------------------------------------------
# Add constraint files (if not already added)
#------------------------------------------------------------------------------
puts "\n>>> Checking constraint files..."

set xdc_files [list \
    "$project_dir/constraints/pins.xdc" \
    "$project_dir/constraints/timing.xdc" \
]

foreach f $xdc_files {
    if {[file exists $f]} {
        set fname [file tail $f]
        set existing [get_files -quiet -of_objects [get_filesets constrs_1] $fname]
        if {$existing eq ""} {
            add_files -fileset constrs_1 -norecurse $f
            puts "  Added: $fname"
        } else {
            puts "  Exists: $fname"
        }
    } else {
        puts "  SKIP: File not found - [file tail $f]"
    }
}

#------------------------------------------------------------------------------
# Create Clock Wizard IP (if not exists)
#------------------------------------------------------------------------------
puts "\n>>> Checking Clock Wizard IP..."

if {[llength [get_ips clk_wiz_video]] == 0} {
    puts "  Creating clk_wiz_video IP..."
    
    create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_wiz_video

    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ {200.000} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {148.500} \
        CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000} \
        CONFIG.CLKOUT2_USED {true} \
        CONFIG.NUM_OUT_CLKS {2} \
        CONFIG.RESET_TYPE {ACTIVE_LOW} \
        CONFIG.RESET_PORT {resetn} \
        CONFIG.CLK_OUT1_PORT {clk_out1} \
        CONFIG.CLK_OUT2_PORT {clk_out2} \
        CONFIG.USE_LOCKED {true} \
        CONFIG.USE_RESET {true} \
        CONFIG.CLKIN1_JITTER_PS {50.0} \
    ] [get_ips clk_wiz_video]

    puts "  Generating IP outputs (please wait)..."
    generate_target all [get_ips clk_wiz_video]
    export_ip_user_files -of_objects [get_ips clk_wiz_video] -no_script -sync -force -quiet
    puts "  clk_wiz_video created successfully"
} else {
    puts "  clk_wiz_video already exists"
}

#------------------------------------------------------------------------------
# Update compile order
#------------------------------------------------------------------------------
puts "\n>>> Updating compile order..."
update_compile_order -fileset sources_1

#------------------------------------------------------------------------------
# Create output directories
#------------------------------------------------------------------------------
file mkdir "$project_dir/reports"
file mkdir "$project_dir/output"

#------------------------------------------------------------------------------
# Done
#------------------------------------------------------------------------------
puts ""
puts "============================================="
puts " Project Setup Complete!"
puts "============================================="
puts ""
puts ">>> Next Steps:"
puts "    1. Run Synthesis:"
puts "       launch_runs synth_1 -jobs 8"
puts "       wait_on_run synth_1"
puts ""
puts "    2. Run Implementation:"
puts "       launch_runs impl_1 -jobs 8"
puts "       wait_on_run impl_1"
puts ""
puts "    3. Generate Bitstream:"
puts "       launch_runs impl_1 -to_step write_bitstream -jobs 8"
puts "============================================="
