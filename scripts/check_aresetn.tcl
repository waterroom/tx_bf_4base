# check_aresetn.tcl — 检查 IP 的 aresetn 状态
open_project vivado_sim/vivado_sim.xpr
foreach ip [get_ips] {
    puts "[get_property name $ip]: C_HAS_ARESETn = [get_property C_HAS_ARESETn $ip]"
}
