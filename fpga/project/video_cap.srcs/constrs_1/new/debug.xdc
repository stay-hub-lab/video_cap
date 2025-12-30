



connect_debug_port u_ila_0/clk [get_nets [list u_xdma_0/inst/xdma_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/CLK_USERCLK2]]

connect_debug_port u_ila_0/clk [get_nets [list u_xdma_0/inst/xdma_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/PIPE_USERCLK2]]
connect_debug_port dbg_hub/clk [get_nets u_ila_2_gt_cpllpdrefclk]




connect_debug_port u_ila_0/probe0 [get_nets [list {c2h_data_reg1[0]} {c2h_data_reg1[1]} {c2h_data_reg1[2]} {c2h_data_reg1[3]} {c2h_data_reg1[4]} {c2h_data_reg1[5]} {c2h_data_reg1[6]} {c2h_data_reg1[7]} {c2h_data_reg1[8]} {c2h_data_reg1[9]} {c2h_data_reg1[10]} {c2h_data_reg1[11]} {c2h_data_reg1[12]} {c2h_data_reg1[13]} {c2h_data_reg1[14]} {c2h_data_reg1[15]} {c2h_data_reg1[16]} {c2h_data_reg1[17]} {c2h_data_reg1[18]} {c2h_data_reg1[19]} {c2h_data_reg1[20]} {c2h_data_reg1[21]} {c2h_data_reg1[22]} {c2h_data_reg1[23]} {c2h_data_reg1[24]} {c2h_data_reg1[25]} {c2h_data_reg1[26]} {c2h_data_reg1[27]} {c2h_data_reg1[28]} {c2h_data_reg1[29]} {c2h_data_reg1[30]} {c2h_data_reg1[31]} {c2h_data_reg1[32]} {c2h_data_reg1[33]} {c2h_data_reg1[34]} {c2h_data_reg1[35]} {c2h_data_reg1[36]} {c2h_data_reg1[37]} {c2h_data_reg1[38]} {c2h_data_reg1[39]} {c2h_data_reg1[40]} {c2h_data_reg1[41]} {c2h_data_reg1[42]} {c2h_data_reg1[43]} {c2h_data_reg1[44]} {c2h_data_reg1[45]} {c2h_data_reg1[46]} {c2h_data_reg1[47]} {c2h_data_reg1[48]} {c2h_data_reg1[49]} {c2h_data_reg1[50]} {c2h_data_reg1[51]} {c2h_data_reg1[52]} {c2h_data_reg1[53]} {c2h_data_reg1[54]} {c2h_data_reg1[55]} {c2h_data_reg1[56]} {c2h_data_reg1[57]} {c2h_data_reg1[58]} {c2h_data_reg1[59]} {c2h_data_reg1[60]} {c2h_data_reg1[61]} {c2h_data_reg1[62]} {c2h_data_reg1[63]} {c2h_data_reg1[64]} {c2h_data_reg1[65]} {c2h_data_reg1[66]} {c2h_data_reg1[67]} {c2h_data_reg1[68]} {c2h_data_reg1[69]} {c2h_data_reg1[70]} {c2h_data_reg1[71]} {c2h_data_reg1[72]} {c2h_data_reg1[73]} {c2h_data_reg1[74]} {c2h_data_reg1[75]} {c2h_data_reg1[76]} {c2h_data_reg1[77]} {c2h_data_reg1[78]} {c2h_data_reg1[79]} {c2h_data_reg1[80]} {c2h_data_reg1[81]} {c2h_data_reg1[82]} {c2h_data_reg1[83]} {c2h_data_reg1[84]} {c2h_data_reg1[85]} {c2h_data_reg1[86]} {c2h_data_reg1[87]} {c2h_data_reg1[88]} {c2h_data_reg1[89]} {c2h_data_reg1[90]} {c2h_data_reg1[91]} {c2h_data_reg1[92]} {c2h_data_reg1[93]} {c2h_data_reg1[94]} {c2h_data_reg1[95]} {c2h_data_reg1[96]} {c2h_data_reg1[97]} {c2h_data_reg1[98]} {c2h_data_reg1[99]} {c2h_data_reg1[100]} {c2h_data_reg1[101]} {c2h_data_reg1[102]} {c2h_data_reg1[103]} {c2h_data_reg1[104]} {c2h_data_reg1[105]} {c2h_data_reg1[106]} {c2h_data_reg1[107]} {c2h_data_reg1[108]} {c2h_data_reg1[109]} {c2h_data_reg1[110]} {c2h_data_reg1[111]} {c2h_data_reg1[112]} {c2h_data_reg1[113]} {c2h_data_reg1[114]} {c2h_data_reg1[115]} {c2h_data_reg1[116]} {c2h_data_reg1[117]} {c2h_data_reg1[118]} {c2h_data_reg1[119]} {c2h_data_reg1[120]} {c2h_data_reg1[121]} {c2h_data_reg1[122]} {c2h_data_reg1[123]} {c2h_data_reg1[124]} {c2h_data_reg1[125]} {c2h_data_reg1[126]} {c2h_data_reg1[127]}]]
connect_debug_port u_ila_0/probe11 [get_nets [list c2h_last_reg]]
connect_debug_port u_ila_0/probe12 [get_nets [list c2h_last_reg1]]
connect_debug_port u_ila_0/probe13 [get_nets [list c2h_valid_reg]]
connect_debug_port u_ila_0/probe14 [get_nets [list c2h_valid_reg1]]

create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list u_xdma_0/inst/xdma_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_clock_int.pipe_clock_i/CLK_USERCLK2]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 4 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {usr_irq_ack[0]} {usr_irq_ack[1]} {usr_irq_ack[2]} {usr_irq_ack[3]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 129 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {c2h_bram_fifo_dout[0]} {c2h_bram_fifo_dout[1]} {c2h_bram_fifo_dout[2]} {c2h_bram_fifo_dout[3]} {c2h_bram_fifo_dout[4]} {c2h_bram_fifo_dout[5]} {c2h_bram_fifo_dout[6]} {c2h_bram_fifo_dout[7]} {c2h_bram_fifo_dout[8]} {c2h_bram_fifo_dout[9]} {c2h_bram_fifo_dout[10]} {c2h_bram_fifo_dout[11]} {c2h_bram_fifo_dout[12]} {c2h_bram_fifo_dout[13]} {c2h_bram_fifo_dout[14]} {c2h_bram_fifo_dout[15]} {c2h_bram_fifo_dout[16]} {c2h_bram_fifo_dout[17]} {c2h_bram_fifo_dout[18]} {c2h_bram_fifo_dout[19]} {c2h_bram_fifo_dout[20]} {c2h_bram_fifo_dout[21]} {c2h_bram_fifo_dout[22]} {c2h_bram_fifo_dout[23]} {c2h_bram_fifo_dout[24]} {c2h_bram_fifo_dout[25]} {c2h_bram_fifo_dout[26]} {c2h_bram_fifo_dout[27]} {c2h_bram_fifo_dout[28]} {c2h_bram_fifo_dout[29]} {c2h_bram_fifo_dout[30]} {c2h_bram_fifo_dout[31]} {c2h_bram_fifo_dout[32]} {c2h_bram_fifo_dout[33]} {c2h_bram_fifo_dout[34]} {c2h_bram_fifo_dout[35]} {c2h_bram_fifo_dout[36]} {c2h_bram_fifo_dout[37]} {c2h_bram_fifo_dout[38]} {c2h_bram_fifo_dout[39]} {c2h_bram_fifo_dout[40]} {c2h_bram_fifo_dout[41]} {c2h_bram_fifo_dout[42]} {c2h_bram_fifo_dout[43]} {c2h_bram_fifo_dout[44]} {c2h_bram_fifo_dout[45]} {c2h_bram_fifo_dout[46]} {c2h_bram_fifo_dout[47]} {c2h_bram_fifo_dout[48]} {c2h_bram_fifo_dout[49]} {c2h_bram_fifo_dout[50]} {c2h_bram_fifo_dout[51]} {c2h_bram_fifo_dout[52]} {c2h_bram_fifo_dout[53]} {c2h_bram_fifo_dout[54]} {c2h_bram_fifo_dout[55]} {c2h_bram_fifo_dout[56]} {c2h_bram_fifo_dout[57]} {c2h_bram_fifo_dout[58]} {c2h_bram_fifo_dout[59]} {c2h_bram_fifo_dout[60]} {c2h_bram_fifo_dout[61]} {c2h_bram_fifo_dout[62]} {c2h_bram_fifo_dout[63]} {c2h_bram_fifo_dout[64]} {c2h_bram_fifo_dout[65]} {c2h_bram_fifo_dout[66]} {c2h_bram_fifo_dout[67]} {c2h_bram_fifo_dout[68]} {c2h_bram_fifo_dout[69]} {c2h_bram_fifo_dout[70]} {c2h_bram_fifo_dout[71]} {c2h_bram_fifo_dout[72]} {c2h_bram_fifo_dout[73]} {c2h_bram_fifo_dout[74]} {c2h_bram_fifo_dout[75]} {c2h_bram_fifo_dout[76]} {c2h_bram_fifo_dout[77]} {c2h_bram_fifo_dout[78]} {c2h_bram_fifo_dout[79]} {c2h_bram_fifo_dout[80]} {c2h_bram_fifo_dout[81]} {c2h_bram_fifo_dout[82]} {c2h_bram_fifo_dout[83]} {c2h_bram_fifo_dout[84]} {c2h_bram_fifo_dout[85]} {c2h_bram_fifo_dout[86]} {c2h_bram_fifo_dout[87]} {c2h_bram_fifo_dout[88]} {c2h_bram_fifo_dout[89]} {c2h_bram_fifo_dout[90]} {c2h_bram_fifo_dout[91]} {c2h_bram_fifo_dout[92]} {c2h_bram_fifo_dout[93]} {c2h_bram_fifo_dout[94]} {c2h_bram_fifo_dout[95]} {c2h_bram_fifo_dout[96]} {c2h_bram_fifo_dout[97]} {c2h_bram_fifo_dout[98]} {c2h_bram_fifo_dout[99]} {c2h_bram_fifo_dout[100]} {c2h_bram_fifo_dout[101]} {c2h_bram_fifo_dout[102]} {c2h_bram_fifo_dout[103]} {c2h_bram_fifo_dout[104]} {c2h_bram_fifo_dout[105]} {c2h_bram_fifo_dout[106]} {c2h_bram_fifo_dout[107]} {c2h_bram_fifo_dout[108]} {c2h_bram_fifo_dout[109]} {c2h_bram_fifo_dout[110]} {c2h_bram_fifo_dout[111]} {c2h_bram_fifo_dout[112]} {c2h_bram_fifo_dout[113]} {c2h_bram_fifo_dout[114]} {c2h_bram_fifo_dout[115]} {c2h_bram_fifo_dout[116]} {c2h_bram_fifo_dout[117]} {c2h_bram_fifo_dout[118]} {c2h_bram_fifo_dout[119]} {c2h_bram_fifo_dout[120]} {c2h_bram_fifo_dout[121]} {c2h_bram_fifo_dout[122]} {c2h_bram_fifo_dout[123]} {c2h_bram_fifo_dout[124]} {c2h_bram_fifo_dout[125]} {c2h_bram_fifo_dout[126]} {c2h_bram_fifo_dout[127]} {c2h_bram_fifo_dout[128]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 11 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {line_cnt[0]} {line_cnt[1]} {line_cnt[2]} {line_cnt[3]} {line_cnt[4]} {line_cnt[5]} {line_cnt[6]} {line_cnt[7]} {line_cnt[8]} {line_cnt[9]} {line_cnt[10]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 2 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list {pixel_cnt[0]} {pixel_cnt[1]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 24 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list {axis_vid_tdata[0]} {axis_vid_tdata[1]} {axis_vid_tdata[2]} {axis_vid_tdata[3]} {axis_vid_tdata[4]} {axis_vid_tdata[5]} {axis_vid_tdata[6]} {axis_vid_tdata[7]} {axis_vid_tdata[8]} {axis_vid_tdata[9]} {axis_vid_tdata[10]} {axis_vid_tdata[11]} {axis_vid_tdata[12]} {axis_vid_tdata[13]} {axis_vid_tdata[14]} {axis_vid_tdata[15]} {axis_vid_tdata[16]} {axis_vid_tdata[17]} {axis_vid_tdata[18]} {axis_vid_tdata[19]} {axis_vid_tdata[20]} {axis_vid_tdata[21]} {axis_vid_tdata[22]} {axis_vid_tdata[23]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 4 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list {usr_irq_req[0]} {usr_irq_req[1]} {usr_irq_req[2]} {usr_irq_req[3]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe6]
set_property port_width 1 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list axis_vid_tlast]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe7]
set_property port_width 1 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list axis_vid_tready]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe8]
set_property port_width 1 [get_debug_ports u_ila_0/probe8]
connect_debug_port u_ila_0/probe8 [get_nets [list axis_vid_tready_normal]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe9]
set_property port_width 1 [get_debug_ports u_ila_0/probe9]
connect_debug_port u_ila_0/probe9 [get_nets [list axis_vid_tuser]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe10]
set_property port_width 1 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list axis_vid_tvalid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe11]
set_property port_width 1 [get_debug_ports u_ila_0/probe11]
connect_debug_port u_ila_0/probe11 [get_nets [list c2h_bram_fifo_empty]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe12]
set_property port_width 1 [get_debug_ports u_ila_0/probe12]
connect_debug_port u_ila_0/probe12 [get_nets [list c2h_bram_fifo_full]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe13]
set_property port_width 1 [get_debug_ports u_ila_0/probe13]
connect_debug_port u_ila_0/probe13 [get_nets [list capture_armed]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe14]
set_property port_width 1 [get_debug_ports u_ila_0/probe14]
connect_debug_port u_ila_0/probe14 [get_nets [list ctrl_enable]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe15]
set_property port_width 1 [get_debug_ports u_ila_0/probe15]
connect_debug_port u_ila_0/probe15 [get_nets [list ctrl_soft_reset]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe16]
set_property port_width 1 [get_debug_ports u_ila_0/probe16]
connect_debug_port u_ila_0/probe16 [get_nets [list ctrl_test_mode]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe17]
set_property port_width 1 [get_debug_ports u_ila_0/probe17]
connect_debug_port u_ila_0/probe17 [get_nets [list custom_sof_dbg]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe18]
set_property port_width 1 [get_debug_ports u_ila_0/probe18]
connect_debug_port u_ila_0/probe18 [get_nets [list first_frame_seen]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe19]
set_property port_width 1 [get_debug_ports u_ila_0/probe19]
connect_debug_port u_ila_0/probe19 [get_nets [list frame_active]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe20]
set_property port_width 1 [get_debug_ports u_ila_0/probe20]
connect_debug_port u_ila_0/probe20 [get_nets [list frame_data_valid]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe21]
set_property port_width 1 [get_debug_ports u_ila_0/probe21]
connect_debug_port u_ila_0/probe21 [get_nets [list frame_in_progress]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe22]
set_property port_width 1 [get_debug_ports u_ila_0/probe22]
connect_debug_port u_ila_0/probe22 [get_nets [list frame_start_pulse]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe23]
set_property port_width 1 [get_debug_ports u_ila_0/probe23]
connect_debug_port u_ila_0/probe23 [get_nets [list out_path_idle]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe24]
set_property port_width 1 [get_debug_ports u_ila_0/probe24]
connect_debug_port u_ila_0/probe24 [get_nets [list pcie_rst_n]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe25]
set_property port_width 1 [get_debug_ports u_ila_0/probe25]
connect_debug_port u_ila_0/probe25 [get_nets [list s_axis_c2h_tlast_0]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe26]
set_property port_width 1 [get_debug_ports u_ila_0/probe26]
connect_debug_port u_ila_0/probe26 [get_nets [list s_axis_c2h_tready_0]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe27]
set_property port_width 1 [get_debug_ports u_ila_0/probe27]
connect_debug_port u_ila_0/probe27 [get_nets [list s_axis_c2h_tvalid_0]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe28]
set_property port_width 1 [get_debug_ports u_ila_0/probe28]
connect_debug_port u_ila_0/probe28 [get_nets [list sof_detected]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe29]
set_property port_width 1 [get_debug_ports u_ila_0/probe29]
connect_debug_port u_ila_0/probe29 [get_nets [list sof_event]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe30]
set_property port_width 1 [get_debug_ports u_ila_0/probe30]
connect_debug_port u_ila_0/probe30 [get_nets [list sof_pending]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe31]
set_property port_width 1 [get_debug_ports u_ila_0/probe31]
connect_debug_port u_ila_0/probe31 [get_nets [list sof_wait_axis]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe32]
set_property port_width 1 [get_debug_ports u_ila_0/probe32]
connect_debug_port u_ila_0/probe32 [get_nets [list sts_fifo_overflow]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe33]
set_property port_width 1 [get_debug_ports u_ila_0/probe33]
connect_debug_port u_ila_0/probe33 [get_nets [list sts_idle]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe34]
set_property port_width 1 [get_debug_ports u_ila_0/probe34]
connect_debug_port u_ila_0/probe34 [get_nets [list user_lnk_up]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe35]
set_property port_width 1 [get_debug_ports u_ila_0/probe35]
connect_debug_port u_ila_0/probe35 [get_nets [list vid_fifo_error_sticky]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe36]
set_property port_width 1 [get_debug_ports u_ila_0/probe36]
connect_debug_port u_ila_0/probe36 [get_nets [list vid_fifo_overflow_axi]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe37]
set_property port_width 1 [get_debug_ports u_ila_0/probe37]
connect_debug_port u_ila_0/probe37 [get_nets [list vid_fifo_underflow]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe38]
set_property port_width 1 [get_debug_ports u_ila_0/probe38]
connect_debug_port u_ila_0/probe38 [get_nets [list vid_fifo_underflow_axi]]
create_debug_core u_ila_1 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_1]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_1]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_1]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_1]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_1]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_1]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_1]
set_property port_width 1 [get_debug_ports u_ila_1/clk]
connect_debug_port u_ila_1/clk [get_nets [list u_clk_wiz_video/inst/clk_out1]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe0]
set_property port_width 24 [get_debug_ports u_ila_1/probe0]
connect_debug_port u_ila_1/probe0 [get_nets [list {vid_data[0]} {vid_data[1]} {vid_data[2]} {vid_data[3]} {vid_data[4]} {vid_data[5]} {vid_data[6]} {vid_data[7]} {vid_data[8]} {vid_data[9]} {vid_data[10]} {vid_data[11]} {vid_data[12]} {vid_data[13]} {vid_data[14]} {vid_data[15]} {vid_data[16]} {vid_data[17]} {vid_data[18]} {vid_data[19]} {vid_data[20]} {vid_data[21]} {vid_data[22]} {vid_data[23]}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe1]
set_property port_width 1 [get_debug_ports u_ila_1/probe1]
connect_debug_port u_ila_1/probe1 [get_nets [list sof_flag_vid]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe2]
set_property port_width 1 [get_debug_ports u_ila_1/probe2]
connect_debug_port u_ila_1/probe2 [get_nets [list sof_pulse_vid]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe3]
set_property port_width 1 [get_debug_ports u_ila_1/probe3]
connect_debug_port u_ila_1/probe3 [get_nets [list vid_de]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe4]
set_property port_width 1 [get_debug_ports u_ila_1/probe4]
connect_debug_port u_ila_1/probe4 [get_nets [list vid_field]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe5]
set_property port_width 1 [get_debug_ports u_ila_1/probe5]
connect_debug_port u_ila_1/probe5 [get_nets [list vid_fifo_overflow]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe6]
set_property port_width 1 [get_debug_ports u_ila_1/probe6]
connect_debug_port u_ila_1/probe6 [get_nets [list vid_hsync]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe7]
set_property port_width 1 [get_debug_ports u_ila_1/probe7]
connect_debug_port u_ila_1/probe7 [get_nets [list vid_vsync]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe8]
set_property port_width 1 [get_debug_ports u_ila_1/probe8]
connect_debug_port u_ila_1/probe8 [get_nets [list wait_for_de]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets vid_pixel_clk]
