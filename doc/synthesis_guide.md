# Vivado 综合验证时序与资源指南 (tx_bf_4base)

在 GUI 工程中通过**综合 (Synthesis)** 验证 300MHz 时序收敛与 ZU48DR 资源占用。

## 1. 综合前准备（缺一不可）

| 项 | 操作 | 说明 |
|----|------|------|
| 器件 | Project Settings → Part 选 ZU48DR | 如 `xczu48dr-ffvg1517-2-e` |
| 顶层 | Sources 窗口右键 `tx_top` → **Set as Top** | 综合 top 必须是 tx_top（**不是** tb_tx_top）|
| TB 位置 | `tb_tx_top.sv` 必须放 **Simulation Sources** | 否则综合会把 TB 当设计 |
| **约束** | Sources → Add Sources → **Add Constraints** → 选 `constraints/tx_top.xdc` | **关键！不加约束时序报告无效** |

> 约束文件已含：`create_clock -period 3.333`（300MHz）、配置口 false_path、
> 8 并行总线 set_bus_skew/set_max_delay。直接添加即可。

## 2. 运行综合

1. Flow Navigator → **Run Synthesis** → 默认设置 → OK
2. 等待完成（全设计综合约几分钟～二十分钟，视机器）
3. 弹窗选 **Open Synthesized Design**

## 3. 验证时序（判据：WNS ≥ 0）

Open Synthesized Design 后：

1. Flow Navigator → **Report Timing Summary**（或菜单 Report → Timing → Summary）
2. 关注 **WNS（Worst Negative Slack）**：
   - **WNS ≥ 0** → 300MHz 时序收敛 ✅（留余量更好：>0.1ns）
   - **WNS < 0** → 有违例路径，看下方"关键路径分析"
3. 检查时钟是否真的 300MHz 生效：
   - Timing Summary 顶部应有 `clk_300m` 时钟，周期 3.333ns
   - 若显示 "No timing constraints" → 约束没加成功

### 关键路径分析（若 WNS < 0）

1. Report Timing Summary → **Setup** 标签 → 找 WNS 最差路径
2. 看路径的 **起点/终点 cell 名**，判断落在哪个模块：
   - `u_fir_*` / `u_mix*` → 内插 FIR 或混频
   - `u_nco*` / `phase_*` → DDS NCO
   - `u_intd*` / `shift_mem*` → int_delay
   - `u_bf_core*` / `u_cmult*` → DBF 复数乘法
3. 双击路径看组合逻辑深度（Path 表里 Logic Levels 列）

**本项目已知边界路径**（若违例优先查这些）：
- dds_nco 相位累加器 `phase_acc + phase_inc*8`（常数乘 + 32bit 加）
- interp_fir Stage C（已拆两级，应无问题）
- int_delay SRL 分段读（已用参考仓库新版，应无问题）

## 4. 验证资源（判据：DSP ≤ 4272）

1. Flow Navigator（Open Synthesized Design）→ **Report Utilization**
2. 或菜单 Report → Utilization → 全选 → OK
3. 关注 4 项 vs ZU48DR 容量：

| 资源 | 估算 | ZU48DR 容量 | 状态 |
|------|------|------------|------|
| **DSP48E2** | **~4,450** | 4,272 | 🔴 **可能超限**（内插 FIR 占 3,072）|
| LUT | ~85K | 425,280 | 🟢 20% |
| FF | ~40K | 850,560 | 🟢 5% |
| BRAM | 少量 | 1,080 (36Kb) | 🟢 |

若 DSP 超限：Report Utilization 展开看哪个模块（基本是 `interp_fir_8x_wrap` 的 8ch×8ph×6tap），
量产需换 Xilinx FIR Compiler IP（`scripts/build_ip.tcl`，DSP 可降至 ~24-48/IP）。

## 5. 常用综合优化选项（若时序/资源不达标）

Project Settings → Synthesis → More Options 或 -directive：
- `-directive Explore`：综合器探索更优实现（耗时更长）
- `-directive RuntimeOptimized`：最快
- `-flatten_hierarchy none`：保留层次，便于定位
- 勾选 **Global Optimization / Retiming**：自动重定时

## 6. 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 时序报告 "No timing constraints" | 约束没加 | Add Constraints 选 tx_top.xdc，重新综合 |
| 报错 `get_ports clk_300m` 找不到 | 综合 top 不是 tx_top | Set as Top 设 tx_top |
| 综合把 TB 当设计 | tb_tx_top.sv 在 Design Sources | 移到 Simulation Sources |
| DSP 超限 | 手写内插 FIR | 换 FIR IP（见第 4 节）|
| 综合很慢 | 设计大 | -directive RuntimeOptimized / 增加 jobs |
| WNS 微负 | 边界路径 | 先看关键路径模块，或 -directive Explore 重试 |

## 7. 命令行方式（可选，无 GUI）

```tcl
# synth.tcl (在 tx_bf_4base 根目录)
read_verilog -sv [glob rtl/*.sv]
read_xdc constraints/tx_top.xdc
synth_design -top tx_top -part xczu48dr-ffvg1517-2-e
report_timing_summary -file rpt/timing.rpt
report_utilization -file rpt/utilization.rpt
exit
```
运行：`vivado -mode batch -source synth.tcl`
（注意：`-part` 需与工程器件一致；若引脚约束未填，综合不受影响）
