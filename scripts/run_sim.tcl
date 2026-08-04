# =============================================================================
# run_sim.tcl  --  Vivado XSim 行为仿真脚本 (tx_bf_4base)
# =============================================================================
# 用法 (在 tx_bf_4base 根目录):
#   vivado -mode batch -source scripts/run_sim.tcl
#   或从任意目录: vivado -mode batch -source <绝对路径>/scripts/run_sim.tcl
#
# 流程: 编译 tx_bf_pkg → 编译 TB (include 链拉入全部 RTL) → xelab → xsim
# 注: xvlog/xelab/xsim 为独立可执行文件, 需用 exec 调用
# =============================================================================

# ---------- 定位项目根目录 (脚本在 scripts/ 下) ----------
set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ".."]]
cd $proj_root
puts "=== tx_bf_4base 行为仿真 ==="
puts "项目根目录: $proj_root"

# ---------- 把 Vivado bin 加入 PATH (xvlog/xelab/xsim) ----------
set vivado_bin [file dirname [info nameofexecutable]]
set env(PATH) "$vivado_bin;$env(PATH)"
puts "Vivado bin: $vivado_bin"

# ---------- 清理旧产物 ----------
catch {exec rm -rf xsim.dir}
catch {file delete -force xvlog.log xelab.log xsim.log xsim.wdb}

# ---------- LUT 文件 (NCO 查表) ----------
set mem_file [file join $proj_root "ip" "coef" "sin_quarter.mem"]
if {![file exists $mem_file]} {
    puts "ERROR: 未找到 NCO LUT 文件: $mem_file"
    exit 1
}
puts "NCO LUT: $mem_file"

# ---------- 1. 准备 xsim.ini (IP 预编译库映射) ----------
#    FIR Compiler 加密 RTL 由 Vivado 安装目录预编译 (data/xsim/ip/fir_compiler_v7_2_18),
#    无需 xvhdl 编译加密文件; 只需 xsim.ini 提供库映射 + xelab 加 -L 链接。
puts "--- 准备 xsim.ini (IP 预编译库) ---"
set vivado_root [file normalize [file join $vivado_bin ".." ".." ".."]]
set src_ini [file join $vivado_root "data" "xsim" "xsim.ini"]
if {![file exists $src_ini]} {
    puts "ERROR: 未找到 Vivado 预编译 IP 库映射: $src_ini"; exit 1
}
file copy -force $src_ini xsim.ini
set fp [open "xsim.ini" a]; puts $fp "xil_defaultlib=xsim.dir/xil_defaultlib"; close $fp
puts "  xsim.ini 就绪 (IP 库: fir_compiler_v7_2_18/xbip_utils_v3_0_10/axi_utils_v2_0_6)"

# ---------- 2. 编译 FIR IP 顶层 VHDL 仿真模型 (明文) ----------
#    IP 生成产物在 vivado_sim.gen/sources_1/ip/<ip>/sim/
set ip_300 [file join $proj_root "vivado_sim" "vivado_sim.gen" "sources_1" "ip" "fir_300to600_87p5pass_hf"]
set ip_600 [file join $proj_root "vivado_sim" "vivado_sim.gen" "sources_1" "ip" "fir_600to1200_87p5pass_hf"]
set ip_1200 [file join $proj_root "vivado_sim" "vivado_sim.gen" "sources_1" "ip" "fir_1200to2400_87p5pass_hf"]
foreach ip [list $ip_300 $ip_600 $ip_1200] {
    if {![file exists [file join $ip sim]]} {
        puts "ERROR: 未找到 IP 生成产物: $ip (先在 Vivado 工程 Generate Output Products)"
        exit 1
    }
}
puts "--- 编译 IP 顶层 VHDL 模型 ---"
set vhdl_tops [list \
    [file join $ip_300 sim fir_300to600_87p5pass_hf.vhd] \
    [file join $ip_600 sim fir_600to1200_87p5pass_hf.vhd] \
    [file join $ip_1200 sim fir_1200to2400_87p5pass_hf.vhd]]
foreach f $vhdl_tops {
    puts "  xvhdl [file tail $f]"
    if {[catch {exec xvhdl $f} res]} {
        puts "IP 仿真模型编译失败:\n$res"; exit 1
    }
}

# ---------- 3. 编译公共包 (必须先编译) ----------
puts "--- 编译 tx_bf_pkg.sv ---"
if {[catch {exec xvlog -sv rtl/tx_bf_pkg.sv} res]} {
    puts "编译失败:\n$res"; exit 1
}

# ---------- 3. 编译全部 RTL + TB (独立文件, 无 include 链) ----------
#    -i rtl: include 搜索路径 (fdacoefs 头文件)
#    LUT 路径: dds_nco 默认 "ip/coef/sin_quarter.mem", 相对项目根目录解析
puts "--- 编译 RTL + tb_tx_top.sv (独立文件) ---"
set rtl_files [glob -nocomplain rtl/*.sv]
set rtl_files [lsearch -all -inline -not -exact $rtl_files rtl/tx_bf_pkg.sv]
if {[catch {
    exec xvlog -sv -i rtl {*}$rtl_files tb/tb_tx_top.sv
} res]} {
    puts "编译失败:\n$res"; exit 1
}

# ---------- 5. 精化 (链接 IP 预编译库) ----------
puts "--- xelab ---"
if {[catch {exec xelab -debug typical -L fir_compiler_v7_2_18 -L xbip_utils_v3_0_10 -L axi_utils_v2_0_6 tb_tx_top -s sim} res]} {
    puts "精化失败:\n$res"; exit 1
}

# ---------- 6. 运行 ----------
puts "--- xsim 运行 ---"
file mkdir sim_out
set sim_res [exec xsim sim -runall]
puts $sim_res   ;# 显示 xsim 输出 (含 TB 的 $display 调试信息)

puts "=== 仿真完成, 结果见 sim_out/dac_out_8p.log ==="
