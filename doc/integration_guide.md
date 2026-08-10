# 集成指南：tx_bf_4base 的 da_data_gen 模块集成到其他工程

> 目标：把 4 波束 × 8 阵元 DBF + DUC 发射机（`da_data_gen`）集成到任意 Vivado 工程。
> 源工程：`C:\workbuddy_chat\tx_bf_4base`（vivado_sim 工程已验证）。

## 1. 需要的文件

### 1.1 RTL 源文件（15 个，`rtl/` 目录，GBK 编码）

| 文件 | 说明 |
|------|------|
| `tx_bf_pkg.sv` | 参数包（**必须最先编译**）：N_BEAM/N_ELEM/位宽/CHIP_ID |
| `da_data_gen.sv` | **顶层模块**（集成入口）|
| `tx_top.sv` | 4 beam_duc + 8 sum_4to1 + DAC 截位 |
| `beam_duc.sv` | 单波束：DBF → 内插 → DDS 混频 |
| `tx_bf_core.sv` | 8 通道 DBF（整数延时 + 分数延时 + 复数权重）|
| `int_delay.sv` | 整数延时（TTD）|
| `frac_delay_fir.sv` | 分数延时 FIR（16 tap 动态系数）|
| `cmult_3dsp.sv` | 复数权重乘法（3 DSP 实现）|
| `interp_hb_3stage.sv` | 3 级半带 8× 内插（含 ×8 增益补偿）|
| `dds_multi_phase_wrap.sv` | 8 相位 DDS 合成器（例化 dds IP ×8）|
| `cmult_8p.sv` | 8 并行复数混频 |
| `sum_4to1.sv` / `add_tree_4.sv` | 4 波束求和（2 级加法树）|
| `decode_cmd_tx_bf.sv` | 配置报文解码器（CDC FIFO + FSM）|
| `reset_sync.sv` | 复位同步器 |

> 不需要：`tx_top_apb.sv`/`cfg_bus.sv`（APB 配置路径，报文配置用不到）；
> `dds_nco.sv`/`interp_fir_8x_wrap.sv`/`dds_mixer_wrap.sv`（死代码）。

### 1.2 IP 依赖（4 个，均在源工程 `vivado_sim.srcs/sources_1/ip/`）

| IP | 用途 | 复制源 |
|----|------|--------|
| `fir_300to600_87p5pass_hf` | 半带内插级 1 | `vivado_sim.srcs/sources_1/ip/fir_300to600_87p5pass_hf/` |
| `fir_600to1200_87p5pass_hf` | 半带内插级 2 | 同上目录 |
| `fir_1200to2400_87p5pass_hf` | 半带内插级 3 | 同上目录 |
| `dds_core_tx_bf_4base` | DDS（8 相位）| 同上目录（IP 名已含工程后缀）|

- **XPM**：`xpm_fifo_async`（decode 用）——Vivado 内置，无需额外 IP
- **器件匹配**：目标工程器件需与源一致（ZU48DR / 同系列），否则需重新生成 IP
- 复制 IP 后需在目标工程 **Generate Output Products**

### 1.3 仿真文件（可选）

- `tb/tb_da_data_gen.sv`：端到端参考 TB（报文配置 + DAC dump）
- `sim_src/*.vhd`：3 个半带 FIR 的明文行为模型（综合不需要，行为仿真需要）

## 2. 集成步骤（方式 A：源文件 + IP，推荐）

### 2.1 添加 RTL 源

Vivado → Sources → Add Sources → Add Directories：
```
复制 rtl/ 下 1.1 表格中的 15 个文件（或直接 Add rtl 目录后排除死代码）
```
**编译顺序**：`tx_bf_pkg.sv` 必须最先（勾选 Compile Order / 或在工程里设为第一）。

### 2.2 添加 IP

```tcl
# 复制 4 个 IP 目录到目标工程 sources_1/ip/ 后，或在目标工程重新生成
add_files [glob <目标工程>/sources_1/ip/*/*.xci]
generate_target all [get_ips]
```

### 2.3 例化 da_data_gen

```systemverilog
da_data_gen #(
    .CHIP_ID  (0)          // 片号: 片0 用通道 0..7, 片1 用通道 8..15
) u_da_data_gen (
    // ---- 时钟/复位 ----
    .dac_coreclk (clk_300m),   .rst_dac   (rst_300m),   // 300MHz 数据时钟
    .cmd_clk     (clk_cfg),    .rst_cmd   (rst_cfg),    // 配置时钟
    // ---- 配置报文 (64bit 并行) ----
    .cmd_data       (cfg_data),    .cmd_data_valid (cfg_valid),
    // ---- 4 波束复基带输入 (300MHz, 打包向量 .v 兼容) ----
    // 波束 b 的 16bit IQ 在 [b*16 +: 16], valid 位 b
    .bb_i     (bb_i_vec),      // [63:0] = {b3, b2, b1, b0}
    .bb_q     (bb_q_vec),
    .bb_valid (bb_valid_vec),  // [3:0]
    // ---- 两片同步 (可选) ----
    .rst_bf        (1'b0),        // 不用可接地
    .rst_bf_request(),            // apply 配置完成脉冲 (可悬空)
    // ---- ILA 探针 (调试用, 可接常数) ----
    .dac0_nco_0_nco_update_busy(1'b0),
    .dac0_nco_0_converter0_nco_freq(48'd0),
    .dac0_nco_0_nco_update_request(1'b0),
    .user_sysref_dac(1'b0),
    // ---- 8 路 DAC 输出 (AXI-Stream TDATA, 256bit = 8 并行样本) ----
    .s00_axis_0_tready(1'b1),   .s00_axis_0_tdata(s00_tdata),
    .s02_axis_0_tready(1'b1),   .s02_axis_0_tdata(s02_tdata),
    .s10_axis_0_tready(1'b1),   .s10_axis_0_tdata(s10_tdata),
    .s12_axis_0_tready(1'b1),   .s12_axis_0_tdata(s12_tdata),
    .s20_axis_0_tready(1'b1),   .s20_axis_0_tdata(s20_tdata),
    .s22_axis_0_tready(1'b1),   .s22_axis_0_tdata(s22_tdata),
    .s30_axis_0_tready(1'b1),   .s30_axis_0_tdata(s30_tdata),
    .s32_axis_0_tready(1'b1),   .s32_axis_0_tdata(s32_tdata)
);
```

**TDATA 解包**（每路 256bit）：`tdata[16*2p]=I[p], tdata[16*(2p+1)]=Q[p]`（p=0..7，p0 最早样本）

### 2.4 配置流程（上电后，报文协议）

```systemverilog
// 帧头: {32'h7E8118E7, 32'h0000_0040}
// Function_id: {16'h0001, 16'h0001, 32'h0A0C_000B}
// 帧尾: {32'h0000_0000, 32'h8F9009F8}
// 内容字: {32'h670X_XXXX, data}  仅 apply (0x0A0C_000B) 的内容字被解析
```

寄存器见 `doc/da_data_gen_interface.md`（delay/phase 由 apply 提交，FIR/weight 立即加载，0x6704 DBF 截位）。**建议配置顺序**：FIR 系数 → 权重 → phase → delay → apply。

### 2.5 约束

```tcl
create_clock -period 3.333 [get_ports dac_coreclk]   # 300MHz
create_clock -period 10.0  [get_ports cmd_clk]       # 配置时钟 (可慢)
# 两时钟为异步域 (CDC FIFO 处理), set_clock_groups -asynchronous
```

## 3. 集成方式 B：打包成 IP（封装 da_data_gen）

```tcl
# Vivado GUI: Tools → Create and Package New IP → Package current design
#   选顶层 da_data_gen, Vivado 自动收集全部子模块 + IP 依赖
# 产出: <name>.zip (或 ip/ 目录) → 目标工程 Tools → Settings → IP →
#       Repository → Add 该目录 → IP Catalog 里 Add da_data_gen
```
优点：目标工程只看到 `da_data_gen` 一个 IP；子模块/IP 依赖自动封装。

## 4. 常见问题

| 问题 | 处理 |
|------|------|
| `tx_bf_pkg` 找不到 | 编译顺序：pkg 必须最先 |
| FIR/DDS IP 报"器件不匹配" | 目标工程器件与源不一致 → 在 IP 里重新 Configure/Generate |
| 综合报死代码 $readmemh | 确认未添加 `dds_nco.sv`/`interp_fir_8x_wrap.sv` |
| 中文注释乱码 | rtl 文件是 **GBK** 编码（Vivado IDE 默认 GBK），保持原样 |
| DAC 输出全 0 | 检查配置报文是否发完（Function_id 门控）、rst_bf 复位窗口、TDATA 解包 |
| 两片同步 | CHIP_ID 0/1 + 主控同时发 apply（或 rst_bf 同步复位数据路径）|

## 5. 验证

- 行为仿真：`tb/tb_da_data_gen.sv` + `sim_src/*.vhd` 模型 → `matlab/tx_bf_verify.m`（频率 + 幅度比对）
- 判据：4 波束 LO 峰频率偏差 <1MHz；FPGA vs 模型相对幅度差 <3dB
