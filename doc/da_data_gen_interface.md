# da_data_gen 接口文档

## 1. 概述

`da_data_gen` 是 tx_bf_4base 的顶层封装模块，通过 **64b 并行报文**配置波束参数，处理 4 波束×8 阵元的 DBF+DUC 数据路径。

**两片 ZU48DR 协同**：每片独立运行一个 `da_data_gen`（8 元 4 波束），合计 16 元。两片间无跨片信号。

## 2. 模块端口

| 方向 | 信号 | 位宽 | 说明 |
|------|------|------|------|
| in | `dac_coreclk` | 1 | 数据路径时钟 (300MHz) |
| in | `async_rst_n` | 1 | 外部异步复位（低有效）——**顶层入口**，模块内部按时钟域（dac/cmd）各同步一次，之后所有子模块均为同步高有效复位 |
| in | `cmd_clk` | 1 | 命令时钟（异步于 dac_coreclk）|
| in | `cmd_data` | 64 | 64b 并行报文 |
| in | `cmd_data_valid` | 1 | 报文有效 |
| in | `bb_i` | 4×16 | 4 波束基带 I |
| in | `bb_q` | 4×16 | 4 波束基带 Q |
| in | `bb_valid` | 4 | 4 波束有效 |
| out | `dac_i_8p` | 8×8×16 | 8 阵元×8 并行 I |
| out | `dac_q_8p` | 8×8×16 | 8 阵元×8 并行 Q |
| out | `dac_valid` | 8 | 8 阵元有效 |
| out | `rst_bf_request` | 1 | apply 报文到达脉冲 |

## 3. 报文格式（64b 并行）

每拍 64bit，按状态机逐字解析：

| 序号 | 状态 | [63:32] | [31:0] | 说明 |
|------|------|---------|--------|------|
| 1 | PACKET_HEAD | `0x7E8118E7` | Packet_Len | 帧头 |
| 2 | PACKET_FUNCTION | {Dest_id[16], Device_id[16]} | Function_id | apply 门: `0x0A0C_000B` |
| 3 | PACKET_TIME | Message_Time[63:32] | [31:0] | 时间戳（忽略）|
| 4 | PACKET_Amount | Serial_Num | Packet_Amount | 序列号（忽略）|
| 5 | PACKET_DATA_LEN | Packet_Num | Data_Len | 包号（忽略）|
| 6 | PACKET_VERSION | {Version, Return_Addr} | 保留 0 | 版本（忽略）|
| 7..N | MESSAGE_CONTENT | 寄存器地址码 | 寄存器数据 | 见寄存器映射 |
| N+1 | (帧尾检测) | Checksum | `0x8F9009F8` | 帧尾（在 CONTENT 内检测）|

**帧头**：`0x7E8118E7`（32bit，在 [63:32]）
**帧尾**：`0x8F9009F8`（32bit，在 [31:0]）
**apply 门**：`Function_id == 0x0A0C_000B` 时，报文内暂存的 delay/phase 在帧尾统一提交

## 4. 寄存器映射

地址码 = `da_data[63:32]`，数据 = `da_data[31:0]`。
索引：`idx = beam × 8 + ch`（beam∈0..3, ch∈0..7, idx∈0..31）

| 地址码 | idx 范围 | 字段 | data[31:0] 布局 | 动作 |
|--------|----------|------|----------------|------|
| `0x6701_0000 + idx` | 0..31 | delay_val[beam][ch] | [6:0]=delay (7bit) | **apply 提交** |
| `0x6702_0000 + idx` | 0..31 | FIR coef[beam][ch] | [31:16]=coef, [7:4]=tap_addr | **立即加载** |
| `0x6703_0000 + idx` | 0..31 | weight[beam][ch] | [31:16]=im, [15:0]=re | **立即加载** |
| `0x6705_0000 + beam` | 0..3 | phase_inc[beam] | [31:0]=phase_inc | **apply 提交** |
| `0x6706_0000 + beam` | 0..3 | phase_offset[beam] | [31:0]=phase_offset | **apply 提交** |

### 动作说明

- **立即加载**：FIR 系数和复数权重在报文命中地址码的当拍立即输出 load 脉冲，直接写入 tx_bf_core
- **apply 提交**：延时和 DDS 频率/相位先暂存，在报文 Function_id=0x0A0C_000B 且帧尾到达时统一提交（保证运行时更新原子性）

### 参数计算

- **phase_inc**（DDS 频率字）：`phase_inc = f_LO / 2.4e9 × 2^32`（每样本相位增量，2.4GHz 等效采样率）
- **delay_val**：整数延时（0..64 采样周期）
- **FIR 系数**：16bit 有符号，TAPS=16 个抽头
- **复数权重**：16bit 有符号 re/im

## 5. 配置流程示例

### 配置波束 0 的全部参数

```
1) FIR 系数 (每通道 16 tap, 立即加载):
   for ch 0..7:
     for tap 0..15:
       报文: addr = 0x6702_0000 + 0*8 + ch
              data = {coef[15:0], 12'b0, tap[3:0]}   // [31:16]=coef, [7:4]=tap

2) 复数权重 (每通道, 立即加载):
   for ch 0..7:
     报文: addr = 0x6703_0000 + 0*8 + ch
            data = {im[15:0], re[15:0]}

3) 延时 (暂存, apply 提交):
   for ch 0..7:
     报文: addr = 0x6701_0000 + 0*8 + ch
            data = {25'b0, delay[6:0]}

4) DDS (暂存, apply 提交):
   报文: addr = 0x6705_0000 + 0, data = phase_inc[31:0]
   报文: addr = 0x6706_0000 + 0, data = phase_offset[31:0]

5) 以上全部放在一个报文的 MESSAGE_CONTENT 段,
   报文头 Function_id = 0x0A0C_000B → 帧尾时统一提交 delay/phase
```

### 报文结构示例（配置 beam0 的 delay[0]=10）

```
拍1: 0x7E8118E7_00000040    (帧头 + Packet_Len)
拍2: 0x00010001_0A0C000B    (Dest/Device + Function_id=apply)
拍3: 0x00000000_00000000    (Time)
拍4: 0x00000001_00000001    (Serial/Amount)
拍5: 0x00000001_00000040    (PktNum/DataLen)
拍6: 0x00010000_00000000    (Version/RetAddr)
拍7: 0x67010000_0000000A    (delay[0][0]=10)
...
拍N: 0xXXXXXXXX_8F9009F8    (Checksum + 帧尾)
```

## 6. 两片 ZU48DR 使用说明

- 每片 ZU48DR 独立运行一个 `da_data_gen` 实例
- 每片处理 8 阵元 × 4 波束，输出 8 路 DAC
- 配置报文各自独立发送（两片的 cmd_data 可以相同或不同）
- 两片合计 16 阵元 × 4 波束
- 无需片间同步信号（数据路径各自独立）
