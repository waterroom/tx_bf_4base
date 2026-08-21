# =====================================================================
# import_tx_bf_4base.tcl - tx_bf_4base 4 波束 DBF 发射机 导入/更新脚本
#
# 用法：打开目标 Vivado 工程（如 ZU48_F1/F2_V100_4P8G_sync_260729）后，
#       在 Tcl Console 执行一次：
#   source C:/workbuddy_chat/tx_bf_4base/scripts/import_tx_bf_4base.tcl
#
# 功能（幂等，可重复执行）：
#   1. 删除工程内旧的 tx_bf 源文件（17 个 rtl .sv）
#   2. 删除旧 TB（tb_da_data_gen.sv / tb_decode_cmd_tx_bf.sv / tb_tx_top.sv）
#   3. 删除旧 IP（3 个半带 FIR + dds_core_tx_bf_4base + vio_dac）
#   4. 重新导入 rtl/*.sv（复制进工程 srcs/imports/tx_bf_4base）
#   5. 重新导入 TB（仅仿真，不参与综合）
#   6. 重新导入 IP（复制 xci 进工程并 generate）
#
# 说明：
#   - 源文件复制进工程（srcs/imports/），.xpr 记录工程内路径，
#     工程移动/原目录删除不受影响；tx_bf_4base 更新后重跑本脚本即同步
#   - tx_bf_pkg.sv 为 SV package（参数包），Vivado 自动按依赖编译，
#     无需手动设置编译顺序
#   - IP 需器件匹配（ZU48DR 系列）；目标工程器件不同需重新生成
# =====================================================================

set bf_src  "C:/workbuddy_chat/tx_bf_4base/rtl"
set bf_tb   "C:/workbuddy_chat/tx_bf_4base/tb"
set bf_ip   "C:/workbuddy_chat/tx_bf_4base/vivado_sim/vivado_sim.srcs/sources_1/ip"
set bf_rtl_pat {*tx_bf_pkg.sv *da_data_gen.sv *tx_top.sv *beam_duc.sv *tx_bf_core.sv *frac_delay_fir.sv *int_delay.sv *interp_hb_3stage.sv *cmult_3dsp.sv *cmult_8p.sv *sum_4to1.sv *add_tree_4.sv *reset_sync.sv *decode_cmd_tx_bf.sv *dds_multi_phase_wrap.sv *cfg_bus.sv *tx_top_apb.sv}
set bf_tb_pat {*tb_da_data_gen.sv *tb_decode_cmd_tx_bf.sv *tb_tx_top.sv}
set bf_ip_names {fir_300to600_87p5pass_hf fir_600to1200_87p5pass_hf fir_1200to2400_87p5pass_hf dds_core_tx_bf_4base vio_dac}

set proj_dir   [get_property DIRECTORY [current_project]]
set proj_name  [get_property NAME [current_project]]
set import_dir [file join $proj_dir "${proj_name}.srcs" "sources_1" "imports" "tx_bf_4base"]
file mkdir $import_dir

# ---------------------------------------------------------------
# 1. 删除旧 tx_bf 源文件（按文件名匹配）
# ---------------------------------------------------------------
set old_src [get_files -quiet $bf_rtl_pat]
if {[llength $old_src] > 0} {
    remove_files $old_src
    puts "删除旧源文件: [llength $old_src] 个"
} else {
    puts "无旧源文件需删除"
}

# ---------------------------------------------------------------
# 2. 删除旧 TB
# ---------------------------------------------------------------
set old_tb [get_files -quiet $bf_tb_pat]
if {[llength $old_tb] > 0} {
    remove_files $old_tb
    puts "删除旧 TB: [llength $old_tb] 个"
} else {
    puts "无旧 TB 需删除"
}

# ---------------------------------------------------------------
# 3. 删除旧 IP（5 个：3 半带 FIR + DDS + VIO）
# ---------------------------------------------------------------
foreach ipn $bf_ip_names {
    set old_ip [get_files -quiet -all *${ipn}.xci]
    if {[llength $old_ip] > 0} {
        remove_files $old_ip
        puts "删除旧 IP: $ipn"
    }
}

# ---------------------------------------------------------------
# 4. 重新导入 RTL 源文件（复制进工程，不依赖原路径）
# ---------------------------------------------------------------
set files [glob -nocomplain $bf_src/*.sv]
if {[llength $files] > 0} {
    add_files -norecurse -force -copy_to $import_dir $files
    puts "导入源文件 [llength $files] 个（复制到 $import_dir）"
} else {
    puts "警告: $bf_src 下无 .sv 文件"
}

# ---------------------------------------------------------------
# 5. 重新导入 TB（仅仿真，不参与综合）
# ---------------------------------------------------------------
set tbs [glob -nocomplain $bf_tb/*.sv]
if {[llength $tbs] > 0} {
    add_files -norecurse -force -copy_to $import_dir $tbs
    foreach tb $bf_tb_pat {
        set_property USED_IN_SYNTHESIS false [get_files -quiet $tb]
    }
    puts "导入 TB [llength $tbs] 个（仅仿真，复制到 $import_dir）"
}

# ---------------------------------------------------------------
# 6. 重新导入 IP（复制 xci 进工程并生成）
# ---------------------------------------------------------------
set xcis [glob -nocomplain $bf_ip/*/*.xci]
if {[llength $xcis] > 0} {
    add_files -norecurse -force -copy_to $import_dir $xcis
    puts "导入 IP [llength $xcis] 个（复制 xci 到 $import_dir）"
    set new_ips [get_ips]
    if {[llength $new_ips] > 0} {
        generate_target all $new_ips
        puts "IP 生成完成: [llength $new_ips] 个"
    }
} else {
    puts "警告: $bf_ip 下无 .xci 文件"
}

puts ""
puts "=== tx_bf_4base 导入完成 ==="
puts "  源文件: [llength $files] 个 rtl"
puts "  TB:     [llength $tbs] 个（仅仿真）"
puts "  IP:     [llength $xcis] 个（fir_300/600/1200 + dds_core + vio_dac）"
puts "  提示: 仿真 Top 设为 tb_da_data_gen 后可 Run Simulation"
