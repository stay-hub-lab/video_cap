#------------------------------------------------------------------------------
# PCIe Video Capture Card - PCIe Constraints
# Target Device: XC7K480TFFG1156-2
# Phase 2: XDMA Stream Mode
#------------------------------------------------------------------------------

#==============================================================================
# PCIe Reference Clock (100MHz)
# 重要: IBUFDS_GTE2位置必须与参考时钟引脚匹配!
# J8/J7 对应 IBUFDS_GTE2_X0Y9
#==============================================================================

# IBUFDS_GTE2 位置约束 - 必须设置!
set_property LOC IBUFDS_GTE2_X0Y9 [get_cells refclk_ibuf]

# 只需要设置P端引脚，N端会自动推导
set_property PACKAGE_PIN J8 [get_ports sys_clk_p]

#==============================================================================
# PCIe Reset
#==============================================================================

set_property PACKAGE_PIN R28 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS18 [get_ports sys_rst_n]
set_property PULLTYPE PULLUP [get_ports sys_rst_n]

#==============================================================================
# PCIe TX Differential Pairs (x8)
# 注意: 只需要设置txp引脚，txn会自动推导
# 注意: GT位置约束由IP内部处理，不需要在这里设置
#==============================================================================

set_property PACKAGE_PIN F2 [get_ports {pci_exp_txp[0]}]
set_property PACKAGE_PIN H2 [get_ports {pci_exp_txp[1]}]
set_property PACKAGE_PIN K2 [get_ports {pci_exp_txp[2]}]
set_property PACKAGE_PIN M2 [get_ports {pci_exp_txp[3]}]
set_property PACKAGE_PIN N4 [get_ports {pci_exp_txp[4]}]
set_property PACKAGE_PIN P2 [get_ports {pci_exp_txp[5]}]
set_property PACKAGE_PIN T2 [get_ports {pci_exp_txp[6]}]
set_property PACKAGE_PIN U4 [get_ports {pci_exp_txp[7]}]


#==============================================================================
# System Clock (200MHz for Video)
#==============================================================================

set_property PACKAGE_PIN AA28 [get_ports sys_clk_200m]
set_property IOSTANDARD LVCMOS18 [get_ports sys_clk_200m]

#==============================================================================
# LED Indicators
#==============================================================================

set_property PACKAGE_PIN M30 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[0]}]

set_property PACKAGE_PIN N30 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[1]}]

set_property PACKAGE_PIN P30 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[2]}]

#==============================================================================
# Clock Definitions
#==============================================================================

# PCIe reference clock 100MHz
create_clock -period 10.000 -name pcie_refclk [get_ports sys_clk_p]

# System clock 200MHz
create_clock -period 5.000 -name sys_clk_200m [get_ports sys_clk_200m]

#==============================================================================
# Async Clock Groups - Critical for CDC timing closure
# This tells Vivado not to analyze timing between these clock domains
#==============================================================================

set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks -of_objects [get_ports sys_clk_p]] -group [get_clocks -include_generated_clocks -of_objects [get_ports sys_clk_200m]]

#==============================================================================
# False Paths - Reset Signals (async resets, don't time)
#==============================================================================

# External PCIe reset
set_false_path -from [get_ports sys_rst_n]

# Soft reset from register bank (crosses clock domain)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *soft_reset*}]

# Control signals that cross clock domains (handled by CDC synchronizers)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *ctrl_enable*}] -to   [get_cells -hierarchical -filter {NAME =~ *cdc_sync*sync_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *ctrl_test_mode*}] -to   [get_cells -hierarchical -filter {NAME =~ *cdc_sync*sync_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *ctrl_soft_reset*}] -to   [get_cells -hierarchical -filter {NAME =~ *cdc_sync*sync_reg*}]

# Register bank register outputs to video domain
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *register_bank*reg_*}] -to [get_clocks -include_generated_clocks -of_objects [get_ports sys_clk_200m]]

#==============================================================================
# False Paths - LED outputs (slow, non-critical)
#==============================================================================

set_false_path -to [get_ports {led[*]}]

#==============================================================================
# False Paths - Async FIFO CDC synchronizers
# The async FIFO uses gray code pointers with double-flop synchronizers
# These are properly designed for CDC and don't need STA
#==============================================================================

set_false_path -from [get_cells -hierarchical -filter {NAME =~ *async_fifo*wr_ptr*}] -to   [get_cells -hierarchical -filter {NAME =~ *async_fifo*wr_ptr_gray_sync*}]

set_false_path -from [get_cells -hierarchical -filter {NAME =~ *async_fifo*rd_ptr*}] -to   [get_cells -hierarchical -filter {NAME =~ *async_fifo*rd_ptr_gray_sync*}]

#==============================================================================
# False Paths - Status signals (monitored, not critical timing)
#==============================================================================

set_false_path -from [get_cells -hierarchical -filter {NAME =~ *user_lnk_up*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *vid_pixel_clk_locked*}]

