# =============================================================================
# run_sim.tcl  --  Vivado XSim 行为仿真脚本 (tx_bf_4base)
# =============================================================================
# 用法 (在 tx_bf_4base 根目录):
#   vivado -mode batch -source scripts/run_sim.tcl
#   或从任意目录: vivado -mode batch -source <绝对路径>/scripts/run_sim.tcl
#
# 流程: 编译 tx_bf_pkg → 编译 TB (include 链拉入全部 RTL) → xelab → xsim
# =============================================================================

# ---------- 定位项目根目录 (脚本在 scripts/ 下) ----------
set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ".."]]
cd $proj_root
puts "=== tx_bf_4base 行为仿真 ==="
puts "项目根目录: $proj_root"

# ---------- 清理旧产物 ----------
catch {file delete -force xsim.dir}
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
if {[catch {xvlog -sv rtl/tx_bf_pkg.sv} res]} {
    puts "编译失败: $res"; exit 1
}

# ---------- 2. 编译 TB (include 链拉入全部 RTL) ----------
#    -i rtl: include 搜索路径 (tx_top.sv 的 include 子模块都在 rtl/)
#    -d SIN_QUARTER_MEM="绝对路径": 覆盖 dds_nco 的 LUT 文件默认路径
puts "--- 编译 tb_tx_top.sv (含全部 RTL) ---"
if {[catch {
    xvlog -sv -i rtl -d SIN_QUARTER_MEM="\"$mem_file\"" tb/tb_tx_top.sv
} res]} {
    puts "编译失败: $res"; exit 1
}

# ---------- 3. 精化 ----------
puts "--- xelab ---"
if {[catch {xelab -debug typical tb_tx_top -s sim} res]} {
    puts "精化失败: $res"; exit 1
}

# ---------- 4. 运行 ----------
puts "--- xsim 运行 ---"
file mkdir sim_out
xsim sim -runall

puts "=== 仿真完成, 结果见 sim_out/dac_out_8p.log ==="
