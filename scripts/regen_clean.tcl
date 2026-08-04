# regen_clean.tcl — .gen 已删, 全新生成 IP (xci 带 aresetn) + 更新 sim_src
open_project vivado_sim/vivado_sim.xpr
puts "=== 全新生成 IP (aresetn) ==="
generate_target all [get_ips]
foreach n {fir_300to600_87p5pass_hf fir_600to1200_87p5pass_hf fir_1200to2400_87p5pass_hf} {
    set src [file join [pwd] "vivado_sim" "vivado_sim.gen" "sources_1" "ip" $n "sim" "$n.vhd"]
    set dst [file join [pwd] "sim_src" "$n.vhd"]
    if {[file exists $src]} {
        file copy -force $src $dst
        puts "  sim_src/$n.vhd 已更新"
    } else {
        puts "  ERROR: $src 不存在"
    }
}
puts "=== 完成 ==="
