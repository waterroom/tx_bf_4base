# da_data_gen 接口文档

## 1. 概述

`da_data_gen` 是 tx_bf_4base 的顶层封装模块，通过 **64b 并行报文**配置波束参数，处理 4 波束×8 阵元的 DBF+DUC 数据路径。

**两片 ZU48DR 协同**：每片独立运行一个 `da_data_gen`（8 元 4 波束），合计 16 元。两片间无跨片信号。

## 2. 模块端口

| 方向   | 信号                               | 位宽   | 说明                                                                                                    |
| ------ | ------                             | ------ | ------                                                                                                  |
| in     | `dac_coreclk`                      | 1      | 数据路径时钟 (300MHz)                                                                                   |
| in     | `rst_dac`                          | 1      | **dac_coreclk 域**异步复位（高有效）——顶层入口，内部 reset_sync 同步一次                                |
| in     | `rst_cmd`                          | 1      | **cmd_clk 域**异步复位（高有效）——顶层入口，内部 reset_sync 同步一次                                    |
| in     | `cmd_clk`                          | 1      | 命令时钟（异步于 dac_coreclk）                                                                          |
| in     | `cmd_data`                         | 64     | 64b 并行报文                                                                                            |
| in     | `cmd_data_valid`                   | 1      | 报文有效                                                                                                |
| in     | `bb_i`                             | 4×16   | 4 波束基带 I                                                                                            |
| in     | `bb_q`                             | 4×16   | 4 波束基带 Q                                                                                            |
| in     | `bb_valid`                         | 4      | 4 波束有效                                                                                              |
| out    | `rst_bf_request`                   | 1      | apply 报文到达脉冲（DDS 频率切换请求）                                                                  |
| in     | `rst_bf`                           | 1      | 两片同步门（高有效）——外部主控给两片同时拉高，有效期间提交新 DDS 频率 + 复位数据路径                    |
| in     | `dac0_nco_0_*` / `user_sysref_dac` | —      | ILA 调试探针（透传）                                                                                    |
| in     | `sXX_axis_0_tready` ×8             | 1      | AXI-Stream TREADY（ILA 监控，透传）                                                                     |
| out    | `s00~s32_axis_0_tdata` ×8          | 256    | **DAC 输出**（AXI-Stream TDATA）：每路 8 并行样本 × 交替 {I[15:0], Q[15:0]}；映射 s00=阵元0 … s32=阵元7 |

## 3. 报文格式（64b 并行）

每拍 64bit，按状态机逐字解析：

| 序号   | 状态            | [63:32]                      | [31:0]        | 说明                      |
| ------ | ------          | ---------                    | --------      | ------                    |
| 1      | PACKET_HEAD     | `0x7E8118E7`                 | Packet_Len    | 帧头                      |
| 2      | PACKET_FUNCTION | {Dest_id[16], Device_id[16]} | Function_id   | apply 门: `0x0A0C_000B`   |
| 3      | PACKET_TIME     | Message_Time[63:32]          | [31:0]        | 时间戳（忽略）            |
| 4      | PACKET_Amount   | Serial_Num                   | Packet_Amount | 序列号（忽略）            |
| 5      | PACKET_DATA_LEN | Packet_Num                   | Data_Len      | 包号（忽略）              |
| 6      | PACKET_VERSION  | {Version, Return_Addr}       | 保留 0        | 版本（忽略）              |
| 7..N   | MESSAGE_CONTENT | 寄存器地址码                 | 寄存器数据    | 见寄存器映射              |
| N+1    | (帧尾检测)      | Checksum                     | `0x8F9009F8`  | 帧尾（在 CONTENT 内检测） |

**帧头**：`0x7E8118E7`（32bit，在 [63:32]）
**帧尾**：`0x8F9009F8`（32bit，在 [31:0]）
**apply 门**：`Function_id == 0x0A0C_000B` 时，报文内暂存的 delay/phase 在帧尾统一提交

## 4. 寄存器映射

### 两片 ZU48DR 寻址（CHIP_ID 地址拆片）

两片 FPGA 各跑独立 8 元 4 波束（合计 16 元），**寄存器按 16 元全局编址**，每片通过 `CHIP_ID` 宏（parameter）从地址码中解开属于自己的 8 元：

- **idx 位拆解**：`idx = beam × 16 + ch`（beam∈0..3, ch∈0..15, idx∈0..63），其中
  - `idx[5:4]` = beam（0..3）
  - `idx[3]` = 片号（0 → 片 0，1 → 片 1）——**拆片位**
  - `idx[2:0]` = 本片通道（0..7）
- **CHIP_ID 设置**：片 0 综合时 `CHIP_ID=0`，片 1 综合时 `CHIP_ID=1`（`da_data_gen`/`decode_cmd_tx_bf` 参数）
- **拆片规则**：`idx[3] == CHIP_ID` 的 delay/FIR/weight 条目才属于本片，写入本地通道 `ch_local = idx[2:0]`；**不匹配则忽略该条**（不影响本片当前配置）
- **DDS 频率不解片**：`0x6705`/`0x6706`（phase_inc/phase_offset，仅 beam 维）**两片解到同一频率**——16 元波束共用 DDS 频率，主控广播一份即可
- 配置方式：主控对两片**广播同一份 16 元配置**（两片各自 cmd 通道收到相同报文），每片自动抽取属于自己的 8 元
- DDS 频率切换：两片各自收到 apply 报文 → 各自拉高 `rst_bf_request` → 主控给两片同时拉高 `rst_bf` → 两片同拍提交新频率（见第 6 节）

地址码 = `da_data[63:32]`，数据 = `da_data[31:0]`。
索引：`idx = beam × 16 + ch`（beam∈0..3, ch∈0..15, idx∈0..63；片 0 用 ch∈0..7，片 1 用 ch∈8..15）

| 地址码               | idx 范围   | 字段                | data[31:0] 布局              | 动作           |
| --------             | ---------- | ------              | ----------------             | ------         |
| `0x6701_0000 + idx`  | 0..63      | delay_val[beam][ch] | [6:0]=delay (7bit)           | **apply 提交** |
| `0x6702_0000 + idx`  | 0..63      | FIR coef[beam][ch]  | [31:16]=coef, [7:4]=tap_addr | **立即加载**   |
| `0x6703_0000 + idx`  | 0..63      | weight[beam][ch]    | [31:16]=im, [15:0]=re        | **立即加载**   |
| `0x6705_0000 + beam` | 0..3       | phase_inc[beam]     | [31:0]=phase_inc             | **apply 提交** |
| `0x6706_0000 + beam` | 0..3       | phase_offset[beam]  | [31:0]=phase_offset          | **apply 提交** |

> 注：表中 `[beam][ch]` 的 `ch` 为**全局通道号**（0..15）；本片内部实际使用 `ch_local = ch[2:0]`。

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
