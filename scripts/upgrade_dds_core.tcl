# upgrade_dds_core.tcl — 升级 dds_core IP 到当前器件并生成
open_project vivado_sim/vivado_sim.xpr
puts "=== upgrade_ip dds_core (器件 fsvg-2-i -> ffvg-2-e) ==="
upgrade_ip [get_ips dds_core]
puts "=== generate_target ==="
generate_target all [get_ips dds_core]
puts "=== 验证产物 ==="
set ipdir [file join [pwd] "vivado_sim" "vivado_sim.gen" "sources_1" "ip" "dds_core"]
puts "  sim 目录: [file exists [file join $ipdir sim]]"
puts "  synth 目录: [file exists [file join $ipdir synth]]"
puts "=== 完成 ==="
