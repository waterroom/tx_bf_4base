# =============================================================================
# run_sim.tcl  --  Vivado XSim 仿真脚本
# =============================================================================
# 用法: vivado -mode batch -source run_sim.tcl -tclargs [tb_name]
#   tb_name: tb_tx_top (默认) 或 tb_tx_bf_core
# =============================================================================

set tb_name "tb_tx_top"
if {$argc > 0} { set tb_name [lindex $argv 0] }

# ---------- 编译源文件 ----------
set proj_dir "xsim.dir"
file mkdir $proj_dir

# RTL 源 (含参考仓库复用模块)
set rtl_files [glob -nocomplain rtl/*.sv]

# TB 源
set tb_file "tb/${tb_name}.sv"

# ---------- XSim 流程 ----------
# 1. 编译
foreach f $rtl_files {
    xvlog -sv -L xpm $f
}
xvlog -sv -L xpm $tb_file

# 2. 精化
xelab -L xpm -L unisims_ver -L secureip -debug typical $tb_name -s sim

# 3. 运行
file mkdir sim_out
xsim sim -tclbatch {
    run all
    exit
}

puts "=== 仿真完成, 结果在 sim_out/ ==="
