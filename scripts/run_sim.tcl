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

# ---------- 1. 编译公共包 (必须先编译) ----------
puts "--- 编译 tx_bf_pkg.sv ---"
if {[catch {exec xvlog -sv rtl/tx_bf_pkg.sv} res]} {
    puts "编译失败:\n$res"; exit 1
}

# ---------- 2. 编译 TB (include 链拉入全部 RTL) ----------
#    -i rtl: include 搜索路径
#    LUT 路径: dds_nco 默认 "ip/coef/sin_quarter.mem", 相对项目根目录解析
#    (xsim 通过 exec 继承本脚本 cd 到的 proj_root 作为工作目录)
puts "--- 编译 tb_tx_top.sv (include 链拉入全部 RTL) ---"
if {[catch {
    exec xvlog -sv -i rtl tb/tb_tx_top.sv
} res]} {
    puts "编译失败:\n$res"; exit 1
}

# ---------- 3. 精化 ----------
puts "--- xelab ---"
if {[catch {exec xelab -debug typical tb_tx_top -s sim} res]} {
    puts "精化失败:\n$res"; exit 1
}

# ---------- 4. 运行 ----------
puts "--- xsim 运行 ---"
file mkdir sim_out
set sim_res [exec xsim sim -runall]
puts $sim_res   ;# 显示 xsim 输出 (含 TB 的 $display 调试信息)

puts "=== 仿真完成, 结果见 sim_out/dac_out_8p.log ==="
