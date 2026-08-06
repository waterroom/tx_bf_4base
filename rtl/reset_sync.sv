`timescale 1ns/1ps

// =============================================================================
// reset_sync.sv  --  复位同步器 (标准写法: 纯同步, 无异步敏感列表)
// =============================================================================
// 参考 Xilinx UG949 (UltraFast Design Methodology): 如需复位, 推荐同步复位。
//   同步复位优势: 可直接映射更多器件资源 (DSP48/BRAM 寄存器仅支持同步复位)、
//   不影响通用逻辑最高频率、避免异步复位破坏 BRAM/LUTRAM/SRL 内容。
// 本模块:
//   - 完全同步逻辑 (两级 FF 同步器), 无 always_ff 异步敏感列表
//   - async_rst_n (外部异步源, 低有效) 采样 → 高有效内部 rst_meta → 两级同步
//   - 复位释放经 2 级 FF 同步到 clk (消除释放沿亚稳态, UG949 要求)
//   - rst_meta/rst_r 初始 1 (上电即复位态; 配置结束 GSR 后为已知态)
//     —— 避免仿真初始 rst=X 传播到下游同步复位 FF (VHDL IP X 索引 add_1)
// 时序: async_rst_n 拉低 → 下一拍 rst_meta=1 → 再下一拍 rst=1 (复位生效)
//        async_rst_n 拉高 → 2 拍后 rst=0 (同步释放)
// 备选: 如需异步置位快速性, 可用 Xilinx 原语 xpm_cdc_async_rst (UG974),
//       该原语内部仍为"异步置位+同步释放", 但由官方验证实现。
//
// 端口:
//   clk          : 目标时钟
//   async_rst_n  : 外部异步复位 (低有效, 宽脉冲)
//   rst          : 高有效同步复位 (喂给子模块)
// =============================================================================

`ifndef RESET_SYNC_SV
`define RESET_SYNC_SV

module reset_sync (
    input  logic clk,
    input  logic async_rst_n,   // 外部异步复位 (低有效)
    output logic rst            // 高有效同步复位
);

    // ---------- 两级 FF 同步器 (纯同步, 无异步敏感列表) ----------
    // 初始 1: 上电/配置后即复位态, 仿真不 X
    logic rst_meta = 1'b1;
    logic rst_r    = 1'b1;
    always_ff @(posedge clk) begin
        rst_meta <= ~async_rst_n;   // 低有效输入 → 高有效内部
        rst_r    <= rst_meta;       // 第 2 级, 消除亚稳态
    end
    assign rst = rst_r;

endmodule : reset_sync

`endif // RESET_SYNC_SV
