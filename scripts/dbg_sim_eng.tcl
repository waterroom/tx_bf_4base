# =============================================================================
# dbg_sim_eng.tcl — 工程仿真方式跑 tb_da_data_gen (等同 GUI 环境, 带诊断)
# =============================================================================
cd C:/workbuddy_chat/tx_bf_4base

open_project vivado_sim/vivado_sim.xpr

# 记录并切换 sim_1 的 top 到 tb_da_data_gen
set old_top [get_property top [get_filesets sim_1]]
set_property top tb_da_data_gen [get_filesets sim_1]
puts "=== top: tb_da_data_gen (was $old_top) ==="

launch_simulation -simset sim_1 -mode behavioral
run all

puts "=== SIM DONE ==="
close_sim
set_property top $old_top [get_filesets sim_1]
