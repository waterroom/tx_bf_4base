# tx_bf_4base —— 宽带 TX 数字波束形成 + DUC 发射机

4 波束 × 16 阵元（2 片 FPGA，每片 8 阵元）宽带 TX 数字波束形成发射模块。
目标器件 Xilinx Zynq UltraScale+ RFSoC **ZU48DR**（片内 RF-DAC，复数 I/Q 输出）。

## 架构（单 FPGA）

```
BB1..4(300MHz复IQ) → [8通道DBF@300MHz] → [8×内插FIR→8并行] → [DDS+复数混频@2.4GHz并行域] → [8×(4路复数求和)] → 8路复数DAC(2.4Gs/s)
```

- 4 个波束各自独立：DBF → 8 倍上采样 → 复数上变频（LO 按波束，8 阵元共享）
- 8 个阵元各自求 4 波束之和 → 8 路 RF-DAC（复数 I/Q）
- 主时钟 300MHz；2.4GHz 通过每拍 8 并行采样等效实现
- 射频 200MHz～2.2GHz 可配（上变频必须在 2.4GHz 并行域）
- LO 频率分辨率 Hz 级（DDS 32bit 相位，0.56Hz 步进）

## 关键约束

- 除 tb 外所有源文件用可综合、时序友好 SystemVerilog
- FIR/DDS 用 Xilinx IP 核；FIFO/RAM 用 XPM 宏
- 所有复位同步释放、高有效；注释用中文
- 8 倍内插滤波器系数：`rtl/fdacoefs_fir_300Mto2400M_88Mpass.h`（48 抽头 Type2 线性相位 88MHz 通带）

## 目录结构

```
tx_bf_4base/
├── rtl/        # SystemVerilog 源（可综合）
├── tb/         # 仿真测试台
├── ip/         # Xilinx IP（.xci + 系数 .coe）
├── matlab/     # MATLAB 参考模型与验证脚本
├── constraints/# 时序/引脚约束 .xdc
├── scripts/    # 构建与仿真脚本
├── sim_out/    # 仿真输出（git 忽略）
└── doc/        # 设计文档
```

## 实现顺序

1. MATLAB 全链路模型 + 测试向量
2. 复用参考仓库 `waterroom/tx_bf` 的 4 个 DBF 模块（N_CH=8）
3. 叶子模块（reset_sync / cmult_3dsp_stream / cmult_8p / add_tree_4 / tx_bf_pkg）
4. 生成 FIR/DDS IP + 系数 .coe
5. IP 包装层 + 中层模块（beam_duc / sum_4to1 / cfg_bus）
6. 顶层 tx_top + 约束
7. TB 对比验证（SQNR > 50dB）

## 参考

- 参考仓库：https://github.com/waterroom/tx_bf （16 通道单波束 TTD DBF 核，300MHz）
- 详细设计方案：`doc/design_spec.md`

## License

MIT
