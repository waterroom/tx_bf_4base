# regenerate_ip.tcl — 重新生成 IP 产物 (恢复被删的 .gen) + 更新 sim_src
open_project vivado_sim/vivado_sim.xpr
puts "=== 重新生成 IP 产物 ==="
generate_target all [get_ips]
foreach n {fir_300to600_87p5pass_hf fir_600to1200_87p5pass_hf fir_1200to2400_87p5pass_hf} {
    file copy -force \
        [file join [pwd] "vivado_sim" "vivado_sim.gen" "sources_1" "ip" $n "sim" "$n.vhd"] \
        [file join [pwd] "sim_src" "$n.vhd"]
    puts "  sim_src/$n.vhd 已更新"
}
puts "=== 完成 ==="
