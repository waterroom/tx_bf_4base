# =============================================================================
# run_sim_da_gen.tcl — da_data_gen 混合语言行为仿真 (Vivado 会话内手动 xsim)
# =============================================================================
# 基于 run_sim_vivado.tcl 改造: 加 dds_core IP (dds_compiler_v6_0_22) + glbl
# 用法: vivado -mode batch -source scripts/run_sim_da_gen.tcl
# 输出: sim_out/da_data_gen_dac.log (绝对路径, TB 内 fopen)
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ".."]]
cd $proj_root

# 仿真工作目录
set xsim_dir [file join $proj_root "vivado_sim" "vivado_sim.sim" "sim_1" "behav" "xsim"]
file mkdir $xsim_dir
cd $xsim_dir

# ---------- 1. xsim.ini: 全库映射 (fir + dds + 依赖) ----------
puts "=== 准备 xsim.ini ==="
set ini_fp [open "xsim.ini" w]
puts $ini_fp "xil_defaultlib=xsim.dir/xil_defaultlib"
puts $ini_fp "fir_compiler_v7_2_18=$env(RDI_DATADIR)/xsim/ip/fir_compiler_v7_2_18"
puts $ini_fp "xbip_utils_v3_0_10=$env(RDI_DATADIR)/xsim/ip/xbip_utils_v3_0_10"
puts $ini_fp "axi_utils_v2_0_6=$env(RDI_DATADIR)/xsim/ip/axi_utils_v2_0_6"
puts $ini_fp "dds_compiler_v6_0_22=$env(RDI_DATADIR)/xsim/ip/dds_compiler_v6_0_22"
puts $ini_fp "xbip_pipe_v3_0_6=$env(RDI_DATADIR)/xsim/ip/xbip_pipe_v3_0_6"
puts $ini_fp "xbip_bram18k_v3_0=$env(RDI_DATADIR)/xsim/ip/xbip_bram18k_v3_0_6"
puts $ini_fp "mult_gen_v12_0=$env(RDI_DATADIR)/xsim/ip/mult_gen_v12_0_18"
puts $ini_fp "xbip_dsp48_wrapper_v3_0=$env(RDI_DATADIR)/xsim/ip/xbip_dsp48_wrapper_v3_0_4"
puts $ini_fp "xbip_dsp48_addsub_v3_0=$env(RDI_DATADIR)/xsim/ip/xbip_dsp48_addsub_v3_0_6"
puts $ini_fp "xbip_dsp48_multadd_v3_0=$env(RDI_DATADIR)/xsim/ip/xbip_dsp48_multadd_v3_0_6"
puts $ini_fp "xpm=$env(RDI_DATADIR)/xsim/ip/xpm"
close $ini_fp

# 清理旧产物
catch {exec rm -rf xsim.dir}
catch {file delete -force xvlog.log xelab.log xsim.log xsim.wdb}

# ---------- 2. xvhdl: FIR IP 顶层 + dds_core 顶层 (明文) ----------
puts "=== xvhdl IP 顶层 ==="
foreach n {fir_300to600_87p5pass_hf.vhd fir_600to1200_87p5pass_hf.vhd fir_1200to2400_87p5pass_hf.vhd} {
    if {[catch {exec xvhdl [file join $proj_root "sim_src" $n]} res]} { puts "VHDL 失败:\n$res"; exit 1 }
}
if {[catch {exec xvhdl [file join $proj_root "vivado_sim" "vivado_sim.srcs" "sources_1" "ip" "dds_core_tx_bf_4base" "sim" "dds_core_tx_bf_4base.vhd"]} res]} { puts "dds_core_tx_bf_4base VHDL 失败:\n$res"; exit 1 }

# ---------- 3. xvlog: pkg + RTL + tb_da_data_gen + glbl ----------
puts "=== xvlog SV ==="
set glbl [file join $env(RDI_DATADIR) "verilog" "src" "glbl.v"]
if {[catch {exec xvlog -sv [file join $proj_root "rtl" "tx_bf_pkg.sv"]} res]} { puts "pkg 失败:\n$res"; exit 1 }
set rtl_files [glob -nocomplain [file join $proj_root "rtl" "*.sv"]]
# 排除 pkg (先单独编译): glob 返回正斜杠路径, file join 是反斜杠,
# 用 string match 按文件名排除, 避免 lsearch -exact 失效
set rtl_files [lsearch -all -inline $rtl_files {*}]   ;# 规范化列表
set rtl_files [lsearch -all -inline -not -regexp $rtl_files {tx_bf_pkg\.sv$}]
if {[catch {exec xvlog -sv -i [file join $proj_root "rtl"] {*}$rtl_files [file join $proj_root "tb" "tb_da_data_gen.sv"]} res]} { puts "RTL/TB 失败:\n$res"; exit 1 }
if {[catch {exec xvlog $glbl} res]} { puts "glbl 失败:\n$res"; exit 1 }

# ---------- 4. xelab (全库 + glbl) ----------
puts "=== xelab ==="
if {[catch {exec xelab -debug typical \
    -L xpm -L fir_compiler_v7_2_18 -L xbip_utils_v3_0_10 -L axi_utils_v2_0_6 \
    -L dds_compiler_v6_0_22 -L xbip_pipe_v3_0_6 -L xbip_bram18k_v3_0 \
    -L mult_gen_v12_0 -L xbip_dsp48_wrapper_v3_0 -L xbip_dsp48_addsub_v3_0 \
    -L xbip_dsp48_multadd_v3_0 tb_da_data_gen glbl -s tb_dg} res]} {
    puts "精化失败:\n$res"; exit 1
}

# ---------- 5. 运行 ----------
puts "=== xsim 运行 ==="
file mkdir [file join $proj_root "sim_out"]
set sim_res [exec xsim tb_dg -runall]
puts $sim_res

puts "=== 仿真完成 ==="
