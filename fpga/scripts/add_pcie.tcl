#------------------------------------------------------------------------------
# PCIe Video Capture Card - Phase 2: Add XDMA (Stream Mode)
# Target Device: XC7K480TFFG1156-2
#
# Usage:
#   In Vivado Tcl Console:
#   cd G:/Xilinx/XC7K480T/project/video_cap/fpga/scripts
#   source add_pcie.tcl
#------------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize "$script_dir/.."]
set project_path "$project_dir/project/video_cap.xpr"

if {![file exists $project_path]} {
    puts "ERROR: Project not found. Run create_project.tcl first."
    return
}

puts "============================================="
puts "Phase 2: Adding XDMA (Stream Mode)"
puts "============================================="

set current_proj [current_project -quiet]
if {$current_proj eq ""} {
    open_project $project_path
}

#------------------------------------------------------------------------------
# Remove existing XDMA if present
#------------------------------------------------------------------------------
puts "\n>>> Checking for existing XDMA IP..."

if {[llength [get_ips xdma_0]] > 0} {
    puts "  XDMA IP exists. Removing..."
    export_ip_user_files -of_objects [get_ips xdma_0] -no_script -reset -force -quiet
    remove_files [get_files -of_objects [get_ips xdma_0]]
    file delete -force "$project_dir/project/video_cap.srcs/sources_1/ip/xdma_0"
} else {
    puts "  No existing XDMA IP found."
}

#------------------------------------------------------------------------------
# Create XDMA IP (Stream Mode, 128-bit for Gen2 x8)
#------------------------------------------------------------------------------
puts "\n>>> Creating XDMA IP (Stream Mode)..."

create_ip -name xdma -vendor xilinx.com -library ip -version 4.1 -module_name xdma_0

# Configure XDMA - Note: 7-Series Gen2 x8 requires 128-bit data width
set_property -dict [list \
    CONFIG.mode_selection {Advanced} \
    CONFIG.pcie_blk_locn {X0Y0} \
    CONFIG.pl_link_cap_max_link_width {X8} \
    CONFIG.pl_link_cap_max_link_speed {2.5_GT/s} \
    CONFIG.ref_clk_freq {100_MHz} \
    CONFIG.axi_data_width {128_bit} \
    CONFIG.axilite_master_en {true} \
    CONFIG.axilite_master_size {1} \
    CONFIG.axilite_master_scale {Megabytes} \
    CONFIG.xdma_axi_intf_mm {AXI_Stream} \
    CONFIG.xdma_rnum_chnl {1} \
    CONFIG.xdma_wnum_chnl {1} \
    CONFIG.xdma_num_usr_irq {4} \
    CONFIG.pf0_device_id {7028} \
    CONFIG.pf0_subsystem_vendor_id {10EE} \
    CONFIG.pf0_subsystem_id {0007} \
    CONFIG.vendor_id {10EE} \
    CONFIG.pf0_msi_enabled {true} \
    CONFIG.pf0_msix_enabled {false} \
    CONFIG.cfg_mgmt_if {false} \
    CONFIG.pf0_bar0_enabled {true} \
    CONFIG.pf0_bar0_type {Memory} \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {1} \
] [get_ips xdma_0]

puts "  XDMA IP configured successfully"
puts "  Generating IP outputs (this may take several minutes)..."

generate_target all [get_ips xdma_0]
export_ip_user_files -of_objects [get_ips xdma_0] -no_script -sync -force -quiet

puts "  XDMA IP generation complete"

#------------------------------------------------------------------------------
# Add Phase 2 source files
#------------------------------------------------------------------------------
puts "\n>>> Adding Phase 2 source files..."

set phase2_file "$project_dir/src/hdl/video_cap_top_pcie.v"
if {[file exists $phase2_file]} {
    set existing [get_files -quiet "video_cap_top_pcie.v"]
    if {$existing eq ""} {
        add_files -norecurse $phase2_file
        puts "  Added: video_cap_top_pcie.v"
    } else {
        puts "  Exists: video_cap_top_pcie.v"
    }
}

#------------------------------------------------------------------------------
# Enable PCIe constraints, disable Phase 1 constraints
#------------------------------------------------------------------------------
puts "\n>>> Updating constraint files..."

# Disable Phase 1 pins.xdc
set pins_xdc [get_files -quiet "pins.xdc"]
if {$pins_xdc ne ""} {
    set_property is_enabled false $pins_xdc
    puts "  Disabled: pins.xdc"
}

# Enable pcie.xdc
set pcie_xdc_file "$project_dir/constraints/pcie.xdc"
if {[file exists $pcie_xdc_file]} {
    set existing [get_files -quiet -of_objects [get_filesets constrs_1] "pcie.xdc"]
    if {$existing eq ""} {
        add_files -fileset constrs_1 -norecurse $pcie_xdc_file
        puts "  Added: pcie.xdc"
    } else {
        set_property is_enabled true $existing
        puts "  Enabled: pcie.xdc"
    }
}

#------------------------------------------------------------------------------
# Update top module
#------------------------------------------------------------------------------
puts "\n>>> Setting top module to video_cap_top_pcie..."
set_property top video_cap_top_pcie [current_fileset]

#------------------------------------------------------------------------------
# Update compile order
#------------------------------------------------------------------------------
puts "\n>>> Updating compile order..."
update_compile_order -fileset sources_1

#------------------------------------------------------------------------------
# Done
#------------------------------------------------------------------------------
puts ""
puts "============================================="
puts " Phase 2: XDMA Added Successfully!"
puts "============================================="
puts ""
puts ">>> Configuration:"
puts "    - PCIe: Gen2 x8 (5.0 GT/s)"
puts "    - Data Width: 128-bit"
puts "    - Mode: AXI-Stream"
puts "    - C2H Channels: 1 (video to host)"
puts "    - H2C Channels: 1 (host to card)"
puts "    - User IRQs: 4"
puts ""
puts ">>> Next Steps:"
puts "    1. Run Synthesis:"
puts "       reset_run synth_1"
puts "       launch_runs synth_1 -jobs 8"
puts "       wait_on_run synth_1"
puts ""
puts "    2. Check for port mismatch errors"
puts "       (XDMA port names may differ)"
puts ""
puts "    3. Run Implementation and generate bitstream"
puts "============================================="
