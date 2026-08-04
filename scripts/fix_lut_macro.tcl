# fix_lut_macro.tcl — GUI 仿真 LUT 宏改为无引号 (配合 readmemh 内加引号)
open_project vivado_sim/vivado_sim.xpr
set simset [get_filesets sim_1]
set_property -dict [list xsim.compile.xvlog.more_options {-d SIN_QUARTER_MEM=C:/workbuddy_chat/tx_bf_4base/ip/coef/sin_quarter.mem}] $simset
puts "more_options = [get_property xsim.compile.xvlog.more_options $simset]"
puts "=== 完成 ==="
