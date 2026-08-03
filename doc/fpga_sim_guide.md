# FPGA 仿真与验证指南 (tx_bf_4base)

本文档说明如何用 Vivado 2022.1 跑行为仿真，并用 MATLAB 验证 4 波束 × 4 频率的正确性。

## 1. 环境

| 工具 | 版本 | 路径 |
|------|------|------|
| Vivado | 2022.1 | `C:\Xilinx\Vivado\2022.1\bin\vivado.bat` |
| MATLAB | R2021a | `C:\Program Files\Polyspace\R2021a\bin\matlab.exe` |
| 项目根 | - | `C:\workbuddy_chat\tx_bf_4base` |

## 2. 一键流程（推荐）

在项目根目录运行（或直接双击）：

```bat
scripts\run_all.bat
```

内部依次执行：

```
[1/2] vivado -mode batch -source scripts/run_sim.tcl
      → 编译 tx_bf_pkg.sv → 编译 TB(include 链拉入全部 RTL) → xelab → xsim
      → 输出 sim_out/dac_out_8p.log  (8 并行 I/Q, 2.4GHz 等效, 阵元0)
[2/2] matlab -batch tx_bf_verify
      → 复数 FFT 频谱, 检查 4 个波束峰
```

**判据（通过 = 4 峰正确）**：

| 波束 | 预期频率 | 说明 |
|------|---------|------|
| 1 | +210 MHz | LO 200MHz + 基带 10MHz |
| 2 | +930 MHz | LO 900MHz + 基带 30MHz |
| 3 | **-850 MHz** | LO 1500MHz+50MHz, >1.2GHz 混叠到负频 (正常) |
| 4 | **-130 MHz** | LO 2200MHz+70MHz, 混叠 (正常) |

偏差 <1MHz、峰高 >40dB、峰比噪声底高 ~50dB 即通过。

## 3. 手动流程（分步）

### 3.1 命令行

```bash
# 仿真
cd C:\workbuddy_chat\tx_bf_4base
"C:\Xilinx\Vivado\2022.1\bin\vivado.bat" -mode batch -source scripts/run_sim.tcl

# 验证 (PowerShell, 勿在 git-bash 沙箱直接跑, 见 FAQ-1)
& "C:\Program Files\Polyspace\R2021a\bin\matlab.exe" -batch "addpath(genpath('matlab')); tx_bf_verify"
```

### 3.2 Vivado GUI（可选，适合看波形）

1. 打开 Vivado → `Create Project` → 空工程
2. Add Sources: `rtl/*.sv`（15 个全部）、`tb/tb_tx_top.sv`
3. 工程设置: `tx_top` 为 top（仿真 top 选 `tb_tx_top`）
4. Simulation Settings → `-i rtl`（include 路径）+ 勾选 `sin_quarter.mem` 所在目录
5. 左侧 Flow Navigator → **Run Behavioral Simulation**
6. 波形窗口观察 `dac_i_8p[0][*]` / `dac_q_8p[0][*]`（非零即通）

> 注意：GUI 工程方式需把 `C:\workbuddy_chat\tx_bf_4base\ip\coef` 加入 LUT 搜索路径，
> 否则 `$readmemh` 找不到 `sin_quarter.mem`。

### 3.3 想改测试配置？

TB 参数集中在 `tb/tb_tx_top.sv` 头部：

```systemverilog
bb_freq[0..3] = 10/30/50/70 MHz   // 4 路基带频率
APB 配置: FIR 系数(t=7 冲激) / 权重(re=0x7FFF) / phase_inc(LO 200/900/1500/2200MHz)
delay_val = 0                      // 本 TB 不做延时, 验证数据流
```

## 4. 进阶验证（未实现，后续可按需做）

| 项目 | 说明 | 现状 |
|------|------|------|
| **逐样本 SQNR 对比** | MATLAB 生成 test vector（.hex）→ TB 读入 → FPGA 输出与模型逐样本对比，要求 SQNR>50dB | 需写 `tb_gen.m` + TB 读 hex + `compare_fpga.m`（计划中） |
| **FPGA 级方向图** | dump 全部 8 阵元输出 → 验证波束指向 | TB 现只 dump 阵元0，需扩展 |
| **非零延时/权重** | 配置不同 delay_val/weight，验证 TTD 与幅度加权 | 需扩展 TB APB 配置 |

## 5. 常见问题（FAQ）

### 5.1 MATLAB 闪退 / Access Violation（最常见）
- 症状：任何 `matlab -batch` 连 `disp('OK')` 都崩（exit 139 / 0xc0000005）
- 根因：git-bash 沙箱 CPU 亲和性受限 → MATLAB R2021a Intel OpenMP 启动期
  `getNumProcessors` 崩溃。**与脚本/内存无关**（数据仅几百 KB）。
- 解决：用 `run_all.bat` / PowerShell / MATLAB GUI 跑；或直接双击 `scripts\run_analyze.bat`
- 若 GUI 里**绘图窗口**闪退（而非启动崩）：先执行 `opengl software` 再画图

### 5.2 仿真输出全零
- 原因：权重/FIR 系数未加载（复位后为 0，乘法输出恒 0）
- 解决：确认 TB APB 配置流程执行（FIR 系数、权重、phase_inc 三部分缺一不可）

### 5.3 找不到 sin_quarter.mem
- `dds_nco.sv` 用相对路径 `ip/coef/sin_quarter.mem` 加载 LUT
- 仿真必须从**项目根目录**启动（run_sim.tcl 已自动 cd 到项目根）

### 5.4 编译/精化报错
- 先编译 `tx_bf_pkg.sv`（含参数/类型，被 TB import）——run_sim.tcl 已处理顺序
- 参考仓库 4 个文件无 `timescale` 的已补齐；若自行加文件，注意加 `\`timescale 1ns/1ps`

### 5.5 分析频率"不对"的常见误区
- FFT 频轴必须用 `f = ((0:N-1)-N/2)/N*Fs`（`fftshift(ramp)-Fs/2` 会错移 Fs/2）
- 复数信号必须 `I + 1j*Q` 重构再 FFT（只看实数 I 会看到 ±f 对称谱，误判翻转）
- 1500/2200MHz > 1.2GHz 奈奎斯特 → 混叠到 -850/-130MHz 是正常现象，不是 bug

## 6. 一句话流程回顾

```
run_all.bat
  └─ vivado batch 仿真  ─→  sim_out/dac_out_8p.log
  └─ matlab 频谱分析    ─→  4 波束峰 @ 210/930/-850/-130 MHz (±1MHz)
```
