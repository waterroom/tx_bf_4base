# diag_dds.tcl — 详细诊断 dds_core IP 状态
open_project vivado_sim/vivado_sim.xpr
puts "=== IP 列表 ==="
foreach ip [get_ips] { puts "  [get_property name $ip]" }
puts "=== dds_core 状态 ==="
set ip [get_ips dds_core]
puts "  IPStatus: [get_property IPStatus $ip]"
puts "  part: [get_property part $ip]"
puts "=== upgrade ==="
upgrade_ip $ip
puts "  upgrade 后 IPStatus: [get_property IPStatus $ip]"
puts "=== generate ==="
generate_target all $ip
puts "=== 产物检查 ==="
foreach t {synth sim instantiation_template bd} {
    set d [file join [pwd] "vivado_sim" "vivado_sim.gen" "sources_1" "ip" "dds_core" $t]
    puts "  $t: [file exists $d]"
}
puts "=== 完成 ==="
