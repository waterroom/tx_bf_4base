# =============================================================================
# synth.tcl  --  命令行综合 (tx_bf_4base) 验证时序与资源
# =============================================================================
# 用法 (项目根): vivado -mode batch -source scripts/synth.tcl
# 输出: rpt/timing_summary.rpt, rpt/timing_setup.rpt (违例路径),
#       rpt/utilization.rpt, rpt/utilization_hier.rpt (分模块资源)
# 注意: -part 需与目标器件一致 (默认 xczu48dr-ffvg1517-2-e, 按需修改)
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize [file join $script_dir ".."]]
cd $proj_root
file mkdir rpt

puts "=== tx_bf_4base 综合 (300MHz, ZU48DR) ==="

# pkg 必须先读 (参数/类型被其他文件 import); glob 字母序会把 pkg 放后面
set all [glob -nocomplain rtl/*.sv]
set ordered [list]
foreach f $all {
    if {[string match *tx_bf_pkg* $f]} { set ordered [linsert $ordered 0 $f] } else { lappend ordered $f }
}
puts "读入顺序: $ordered"
read_verilog -sv $ordered
read_xdc constraints/tx_top.xdc

synth_design -top tx_top -part xczu48dr-ffvg1517-2-e

# ---------- 时序报告 ----------
report_timing_summary -file rpt/timing_summary.rpt
report_timing -max_paths 20 -setup -file rpt/timing_setup.rpt
puts "时序报告: rpt/timing_summary.rpt + rpt/timing_setup.rpt"

# ---------- 资源报告 ----------
report_utilization -file rpt/utilization.rpt
report_utilization -hierarchical -file rpt/utilization_hier.rpt
puts "资源报告: rpt/utilization.rpt + rpt/utilization_hier.rpt"

puts "=== 综合完成 ==="
exit
