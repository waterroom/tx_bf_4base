# export_sim.tcl — 导出独立 xsim 仿真脚本 (含 IP 编译)
open_project vivado_sim/vivado_sim.xpr
set simset [get_filesets sim_1]
set_property top tb_tx_top $simset
set_property top_lib xil_defaultlib $simset
export_simulation -simulator xsim -directory C:/workbuddy_chat/tx_bf_4base/sim_export
puts "=== export_simulation 完成 ==="
