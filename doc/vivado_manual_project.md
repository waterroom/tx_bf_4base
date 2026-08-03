# Vivado 手动建工程仿真指南 (tx_bf_4base)

本文档指导在 Vivado 2022.1 GUI 中手动建立工程并运行行为仿真（查看波形/交互调试）。
命令行一键仿真见 `doc/fpga_sim_guide.md` 或 `scripts/run_all.bat`。

## 1. 工程源文件清单

建工程时需要添加的**设计源文件**（`rtl/` 全部 15 个）：

| 文件 | 说明 |
|------|------|
| tx_bf_pkg.sv | **必须第一个编译**（参数/类型包，被其他模块 import）|
| reset_sync.sv | 复位同步器 |
| cfg_bus.sv | APB 配置分发 |
| tx_top.sv | **顶层**（include 链拉入 beam_duc 等，其余文件随它自动加入）|
| beam_duc.sv / interp_fir_8x_wrap.sv / dds_nco.sv / dds_mixer_wrap.sv | 波束处理链 |
| cmult_8p.sv / cmult_3dsp.sv / add_tree_4.sv / sum_4to1.sv | 混频/求和 |
| tx_bf_core.sv / int_delay.sv / frac_delay_fir.sv | DBF（参考仓库复用）|
| fdacoefs_fir_300Mto2400M_88Mpass.h | 内插 FIR 系数头文件 |

**仿真源**：`tb/tb_tx_top.sv`（testbench，top 设为它）

**约束**（可选，综合用）：`constraints/tx_top.xdc`

**数据文件**：`ip/coef/sin_quarter.mem`（NCO LUT，仿真必需，见第 3 节路径设置）

## 2. GUI 建工程步骤

1. 打开 Vivado 2022.1 → **Create Project** → 工程名 `tx_bf_4base_prj`
   - **建议放独立目录**（如 `C:\workbuddy_chat\tx_bf_4base\vivado_prj\`），不要用项目根，避免污染源码目录
2. Project Type: **RTL Project**（"Do not specify sources at this time" 可不勾）
3. **Add Sources**：添加 `rtl/*.sv`（15 个全部）+ `tb/tb_tx_top.sv`
   - `tb_tx_top.sv` 属性设为 **Simulation Sources**（Sources 窗口右键 → Add Sources → Simulation）
4. **Add Constraints**：`constraints/tx_top.xdc`（可跳过，仿真不需要）
5. **Part**：选择目标器件 ZU48DR（如 `xczu48dr-ffvg1517-2-e`）
6. Finish

## 3. 两个关键设置（缺一不可）

### 3.1 NCO LUT 文件路径（否则 `$readmemh` 失败）

`dds_nco.sv` 默认从相对路径 `ip/coef/sin_quarter.mem` 读 LUT，但 **Vivado 仿真的工作目录是工程 sim 目录**（`<prj>.sim/sim_1/behav/xsim/`），相对路径找不到。

**设置方法**：Project Settings → **Simulation** → **Verilog Options** → 添加编译选项：
```
-d SIN_QUARTER_MEM="C:/workbuddy_chat/tx_bf_4base/ip/coef/sin_quarter.mem"
```
（`dds_nco.sv` 已支持 `ifndef SIN_QUARTER_MEM` 宏覆盖，无需改代码）

### 3.2 仿真输出位置（知道波形/dump 去哪了）

TB 用相对路径写输出：`sim_out/dac_out_8p.log`、`sim_out/dac_out_8elem.log`。
仿真后它们生成在**工程 sim 工作目录**：
```
<工程目录>/tx_bf_4base_prj.sim/sim_1/behav/xsim/sim_out/
```
（或在 Sources 窗口找到 `tb_tx_top` → 看 xsim 日志中的当前目录）

## 4. 运行仿真

1. Flow Navigator → **Run Simulation** → **Run Behavioral Simulation**
2. 确认 Simulation top 为 `tb_tx_top`（自动）
3. 等待仿真跑完（TB 运行 ~2000 拍 ≈ 6.7us，几十秒内完成）
4. 波形窗口观察：
   - `dac_i_8p[0][0..7]` / `dac_q_8p[0][0..7]`（阵元0 的 8 并行 I/Q，**非零即通**）
   - `dac_valid[0]`（valid 脉冲）
   - 或 `bb_i[0]` 输入正弦
5. 仿真结束自动输出 4 波束频谱验证数据到 `sim_out/`（可用 MATLAB `tx_bf_verify` 分析）

## 5. 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `$readmemh` 找不到文件 | LUT 相对路径 | 设置第 3.1 节宏（绝对路径）|
| 编译报错找不到包 | tx_bf_pkg 未先编译 | 确保 15 个 rtl 文件都在工程中（Vivado 自动按依赖编译）|
| 输出全零 | 权重/FIR 系数未加载 | 检查 TB APB 配置流程（仿真日志应有 "配置完成"）|
| 仿真极慢 | 信号太多 | 只在波形窗口加需要的信号（默认全部会慢）|
| 想缩短仿真 | TB 里 `#(CLK_PERIOD*2000)` | 改小（如 500），注意 valid 建立需 >150 拍 |

## 6. 与命令行仿真的关系

- 命令行 `scripts/run_sim.tcl` 是**同一套 RTL/TB** 的无工程仿真（已验证）
- GUI 工程是交互调试方式，两者结果应一致（同一 RTL）
- 想验证 GUI 结果正确性：仿真后把 `sim_out/dac_out_8elem.log` 拷回项目根 `sim_out/`，跑
  ```matlab
  addpath(genpath('matlab')); tx_bf_verify
  ```
  应与命令行仿真结果一致（4 波束 210/930/-850/-130 MHz + 8 阵元一致）
