# tx_bf_4base 设计规格 (Design Specification)

> 4 波束 × 8 阵元数字波束形成发射机（DBF + DUC），单 FPGA（ZU48DR），两片合做 16 元波束。
> 本文档描述 RTL 现状（2026-08 基线），配置/接口细节见 `da_data_gen_interface.md`。

## 1. 系统概述

- **功能**：4 个独立波束，每个波束 8 阵元（本片）的复基带信号经 TTD 延时、复数加权、分数延时滤波、8 倍内插、DDS 混频（独立 LO）、4 波束求和后输出 8 路复 IQ（2.4GHz 等效）
- **部署**：每片 ZU48DR 独立运行一个 `da_data_gen` 实例，两片合计 16 阵元 × 4 波束；报文按 16 元全局编址 + CHIP_ID 自动拆片
- **输出**：8 路 RF-DAC 数据经 AXI-Stream TDATA（每路 256bit = 8 并行样本 × 交替 {I[15:0], Q[15:0]}）

## 2. 关键参数（`rtl/tx_bf_pkg.sv`）

| 参数 | 值 | 说明 |
|------|-----|------|
| N_BEAM | 4 | 波束数 |
| N_ELEM | 8（本片）/ 16（全系统）| 阵元数 |
| INTERP | 8 | 8 倍内插（300MHz → 2.4GHz 等效）|
| DATA_W | 16 | 基带 IQ 位宽 |
| FIR_OUT_W | 18 | 内插/混频输出位宽（DBF 输出 16bit = DATA_W，内插输出 18bit）|
| DDS_PHASE_W | 32 | 相位累加位宽（分辨率 ~0.56Hz @2.4G）|
| DDS_OUT_W | 16 | DDS sin/cos 位宽 |
| MIXER_OUT_W | 18 | 混频输出位宽 |
| SUM_OUT_W | 20 | 4 波束求和位宽（18+2）|
| DAC_W | 16 | DAC 数据位宽 |
| TAPS | 16 | 分数延时 FIR 抽头数 |
| COEF_W | 16 | 系数/权重位宽 |
| MAX_DELAY | 1024 | 整数延时深度（11bit）|
| CHIP_ID | 0/1 | 片选（地址拆片）|

## 3. 数据流（300MHz 域 → 2.4GHz 等效域）

```
复基带 IQ (16bit, 300M)
  → tx_bf_core: 每通道
      int_delay (整数延时 0..1023) → frac_delay_fir (16tap 分数延时)
      → cmult_3dsp (复数权重 w_re/w_im, 相位补偿/波束扫描; 输入已截位 16bit,
  A_W×B_W = 16×16, 输出 16bit)
   输出 8 通道 16bit IQ (bf_re/bf_im)
  → interp_hb_3stage: 3 级半带 FIR IP 8 倍内插
      fir_300to600 → fir_600to1200 → fir_1200to2400 (每级 2× 等效)
      级间截位 [30:15] (半带每级增益 0.5), 输出 ×8 增益补偿
   输出 8 并行 18bit IQ (up_i/up_q)
  → dds_multi_phase_wrap: 8 相位 DDS (dds_core_tx_bf_4base IP ×8)
      phase_inc/phase_offset 配置 LO, 8 并行 cos/sin
  → cmult_8p (×8): 复数混频 (18bit×16bit → 18bit, (x+2^14)>>>15)
   输出 8 并行 18bit (mix)
  → sum_4to1: 4 波束求和 (20bit)
  → DAC 截位: sum >>> 2 + 饱和 (实测 4 波束峰值 ~2^16, 右移 2 用满动态)
   输出 8 并行 16bit (dac_i_8p/dac_q_8p)
  → TDATA 打包: 每路 256bit, 8 样本交替 {I,Q}
```

**幅度链路标度**（修复后，基带 0.5×32767、权重 1.0 时）：
`bb(±16384) → DBF ×1.0 → 内插 ×1.0（×8 补偿抵消半带 ÷8）→ 混频 → 求和(4 波束峰值 ~65536) → DAC >>>2 → ±16392 (50% 满幅)`

## 4. 配置协议（64bit 并行报文，CDC FIFO 跨时钟域）

- 帧头 `0x7E8118E7` / 帧尾 `0x8F9009F8`（`da_data_reg[2]` 组合比较，与 valid 同拍）
- **Function_id 门控（关键）**：只有 `Function_id==0x0A0C_000B`（apply）的内容字被解析；其他 Function_id 内容全部忽略（防误改）
- 提交：delay/phase 由 apply（Function_id 门控）提交，**不判帧尾状态**；FIR/weight 立即加载
- `rst_bf`：可选数据路径同步复位（8 拍滤波 → 上升沿触发 64 拍定时复位，覆盖 FIR/DDS 流水 latency；配置寄存器不复位）

### 寄存器映射（MESSAGE_CONTENT，地址码 [63:32]）

| 地址 | 内容 | 生效 |
|------|------|------|
| `0x6701_0000+beam*16+ch` | delay（[10:0]）| apply 提交 |
| `0x6702_0000+beam*16+ch` | FIR 系数：`[19:16]=tap, [15:0]=coef` | 立即加载 |
| `0x6703_0000+beam*16+ch` | 权重：`[31:16]=im, [15:0]=re` | 立即加载 |
| `0x6704_0000` | tx_bf_core 输出截位右移量（[3:0]，默认 0）| 立即生效 |
| `0x6705_0000+beam` | phase_inc（DDS 频率字）| apply 提交 |
| `0x6706_0000+beam` | phase_offset | apply 提交 |

- 地址拆片：`idx[5:4]=beam, idx[3]=片号(匹配 CHIP_ID), idx[2:0]=本片通道`
- phase（0x6705/06）不解片：两片同频率（16 元波束共用 LO）

## 5. 接口（`da_data_gen` 顶层）

| 方向 | 信号 | 说明 |
|------|------|------|
| in | dac_coreclk / rst_dac | 300MHz 数据时钟（高有效复位）|
| in | cmd_clk / rst_cmd | 配置时钟（报文输入）|
| in | cmd_data[63:0] / cmd_data_valid | 64bit 并行配置报文 |
| in | rst_bf | 两片同步复位门（可选，数据路径定时复位）|
| in | bb_i/bb_q[63:0] + bb_valid[3:0] | 4 波束复基带输入（300MHz，打包向量，.v 兼容；波束 b 在 [b*16 +: 16]）|
| out | rst_bf_request | apply 配置提交脉冲（主控感知两片完成）|
| out | s00..s32_axis_0_tdata[255:0] | 8 路 DAC 数据（AXI-Stream TDATA）|
| in | sXX_axis_0_tready | 下游就绪（当前恒 1）|

## 6. 时序特性

- **总流水延迟**：DBF 内 `delay_val + 34 拍`（int_delay 2 + FIR 24 + cmult 7 + 输出 1）；内插 + 混频 + 求和 + DAC 另有 ~30-50 拍
- **数据路径复位**：rst_bf 8 拍滤波 → 64 拍定时复位（RST_BF_WIDTH），配置寄存器（权重/FIR 系数）在复位中保留
- **valid 对齐**：frac_delay_fir 的 valid 跟随最新样本（`valid_sr[0]`），帧/突发模式正确

## 7. 资源估算（3 级半带 IP 结构）

- DSP48E2 ≈ 1,440（DBF 640 + 内插 ~1,152×… 详见 synthesis_guide）/ ZU48DR 4,272 → 🟢
- 内插由 FIR Compiler IP 实现（每级 6-10 MADDS/通道）

## 8. 验证方法

- `tb_decode_cmd_tx_bf`：6 用例（FIR/weight 加载、delay/phase 提交、Function_id 门控、拆片、0x6704）ALL PASS
- `tb_da_data_gen`：端到端 DAC dump → MATLAB 频谱（4 波束 LO 200/400/600/800MHz 精确落位）+ `tx_bf_verify.m` 幅度比对
- 判据：峰频率偏差 <1MHz；FPGA vs 模型峰幅度差 <3dB；8 阵元一致性（delay=0/weight=1 时逐样本一致）
