# regen_ip_aresetn.tcl — 重置并重新生成 IP (aresetn 启用) + 更新 sim_src
open_project vivado_sim/vivado_sim.xpr
puts "=== 重置 IP 产物 (强制重新生成, aresetn 生效) ==="
reset_target all [get_ips]
puts "=== 重新生成 IP ==="
generate_target all [get_ips]
# 复制新 sim 模型 (自带 aresetn 端口) 到 sim_src
foreach n {fir_300to600_87p5pass_hf fir_600to1200_87p5pass_hf fir_1200to2400_87p5pass_hf} {
    set src [file join [pwd] "vivado_sim" "vivado_sim.gen" "sources_1" "ip" $n "sim" "$n.vhd"]
    set dst [file join [pwd] "sim_src" "$n.vhd"]
    file copy -force $src $dst
    puts "  sim_src/$n.vhd 已更新"
}
puts "=== 完成 ==="
