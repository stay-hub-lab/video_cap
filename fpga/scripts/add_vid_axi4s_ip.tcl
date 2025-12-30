#------------------------------------------------------------------------------
# Add Video In to AXI4-Stream IP
# Usage: source add_vid_axi4s_ip.tcl
#------------------------------------------------------------------------------

puts ">>> Creating Video In to AXI4-Stream IP..."

# Check if IP already exists
if {[llength [get_ips v_vid_in_axi4s_0]] > 0} {
    puts "  IP already exists"
} else {
    # Create IP
    create_ip -name v_vid_in_axi4s -vendor xilinx.com -library ip -version 5.0 -module_name v_vid_in_axi4s_0
    
    # Configure for 1080p, 24-bit RGB
    set_property -dict [list \
        CONFIG.C_PIXELS_PER_CLOCK {1} \
        CONFIG.C_M_AXIS_VIDEO_DATA_WIDTH {8} \
        CONFIG.C_HAS_ASYNC_CLK {1} \
        CONFIG.C_ADDR_WIDTH {12} \
        CONFIG.C_NATIVE_COMPONENT_WIDTH {24} \
    ] [get_ips v_vid_in_axi4s_0]
    
    # Generate IP
    puts "  Generating IP outputs..."
    generate_target all [get_ips v_vid_in_axi4s_0]
    export_ip_user_files -of_objects [get_ips v_vid_in_axi4s_0] -no_script -sync -force -quiet
}

puts "  Done!"
update_compile_order -fileset sources_1
