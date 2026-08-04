# =============================================================================
# run_sim_vivado.tcl — FIR IP 混合语言行为仿真 (手动 xsim 流程, 在 Vivado 会话内)
# =============================================================================
# 背景:
#   - 命令行独立 xelab 无法精化 Xilinx 加密 IP 库 (file 'filepointer' is not open)
#   - launch_simulation 的 compile 生成不包含 sim_1 的 VHDL (Vivado 2022.1 行为)
#   → 在 Vivado batch 会话内手动执行 xvhdl/xvlog/xelab/xsim,
#     RDI_DATADIR 由 Vivado 设置, 加密库可正常精化。
#
# 用法: vivado -mode batch -source scripts/run_sim_vivado.tcl
# 输出: vivado_sim/vivado_sim.sim/sim_1/behav/xsim/sim_out/*.log
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ".."]]
cd $proj_root

puts "=== 打开 vivado_sim 工程 ==="
open_project [file join $proj_root "vivado_sim" "vivado_sim.xpr"]

# 仿真工作目录 (工程 sim 输出位置)
set xsim_dir [file join $proj_root "vivado_sim" "vivado_sim.sim" "sim_1" "behav" "xsim"]
file mkdir $xsim_dir
cd $xsim_dir

# ---------- 1. xsim.ini: 库映射 (IP 预编译库; RDI_DATADIR 由 Vivado 环境提供) ----------
puts "=== 准备 xsim.ini (RDI_DATADIR=$env(RDI_DATADIR)) ==="
set ini_fp [open "xsim.ini" w]
puts $ini_fp "xil_defaultlib=xsim.dir/xil_defaultlib"
puts $ini_fp "fir_compiler_v7_2_18=$env(RDI_DATADIR)/xsim/ip/fir_compiler_v7_2_18"
puts $ini_fp "xbip_utils_v3_0_10=$env(RDI_DATADIR)/xsim/ip/xbip_utils_v3_0_10"
puts $ini_fp "axi_utils_v2_0_6=$env(RDI_DATADIR)/xsim/ip/axi_utils_v2_0_6"
close $ini_fp

# 清理旧产物
catch {exec rm -rf xsim.dir}
catch {file delete -force xvlog.log xelab.log xsim.log xsim.wdb}

# ---------- 2. 编译 FIR IP 顶层 VHDL (明文, 复制自 .gen/sim) ----------
puts "=== 编译 IP 顶层 VHDL ==="
foreach n {fir_300to600_87p5pass_hf.vhd fir_600to1200_87p5pass_hf.vhd fir_1200to2400_87p5pass_hf.vhd} {
    puts "  xvhdl $n"
    if {[catch {exec xvhdl [file join $proj_root "sim_src" $n]} res]} {
        puts "VHDL 编译失败:\n$res"; exit 1
    }
}

# ---------- 3. 编译 SV (pkg + 全部 RTL 独立文件 + TB, 无 include 链) ----------
#    同时恢复 sources_1 RTL 的 used_in_simulation=true (GUI 层次正常显示子模块)
puts "=== 编译 SystemVerilog ==="
foreach f [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == "SystemVerilog"}] {
    set_property used_in_simulation true $f
}
set lut_mem [file join $proj_root "ip" "coef" "sin_quarter.mem"]
if {[catch {exec xvlog -sv [file join $proj_root "rtl" "tx_bf_pkg.sv"]} res]} { puts "pkg 编译失败:\n$res"; exit 1 }
set rtl_files [glob -nocomplain [file join $proj_root "rtl" "*.sv"]]
set rtl_files [lsearch -all -inline -not -exact $rtl_files [file join $proj_root "rtl" "tx_bf_pkg.sv"]]
if {[catch {exec xvlog -sv -i [file join $proj_root "rtl"] -d SIN_QUARTER_MEM="$lut_mem" {*}$rtl_files [file join $proj_root "tb" "tb_tx_top.sv"]} res]} { puts "RTL/TB 编译失败:\n$res"; exit 1 }

# ---------- 4. 精化 (链接 IP 预编译库) ----------
puts "=== xelab (链接 IP 预编译库) ==="
if {[catch {exec xelab -debug typical -L fir_compiler_v7_2_18 -L xbip_utils_v3_0_10 -L axi_utils_v2_0_6 tb_tx_top -s sim} res]} {
    puts "精化失败:\n$res"; exit 1
}

# ---------- 5. 运行 ----------
puts "=== xsim 运行 ==="
file mkdir sim_out
set sim_res [exec xsim sim -runall]
puts $sim_res

puts "=== 仿真完成, 结果见 $xsim_dir/sim_out/ (拷回项目根 sim_out/ 供 MATLAB 验证) ==="
