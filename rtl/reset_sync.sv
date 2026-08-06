`timescale 1ns/1ps

// =============================================================================
// reset_sync.sv  --  复位同步器 (高有效输入/输出)
// =============================================================================
// 全高有效复位语义: 输入 arst (高有效异步复位) → 输出 rst (高有效同步复位)。
// 例外: Xilinx IP 核 (DDS/FIR 的 aresetn) 为 AXI 惯例低有效, 在 wrapper 内
//       ~rst 转换, 不影响本模块高有效语义。
// 参考 Xilinx UG949: 推荐同步复位 (可映射更多资源, DSP48/BRAM 仅支持同步)。
// 实现: 两级 FF 同步器 (无异步敏感列表), 复位释放同步。
//   rst_meta/rst_r 初始 1 (上电即复位态; 仿真不 X, 防 VHDL IP X 索引 add_1)
// 时序: arst=1 → 下一拍 rst_meta=1 → 再下一拍 rst=1 (同步复位生效)
//        arst=0 → 2 拍后 rst=0 (同步释放)
// =============================================================================

`ifndef RESET_SYNC_SV
`define RESET_SYNC_SV

module reset_sync (
    input  logic clk,
    input  logic arst,      // 高有效异步复位输入 (外部若低有效, 顶层入口取反)
    output logic rst        // 高有效同步复位
);

    // ---------- 两级 FF 同步器 (纯同步, 无异步敏感列表) ----------
    // 初始 1: 上电/配置后即复位态, 仿真不 X
    logic rst_meta = 1'b1;
    logic rst_r    = 1'b1;
    always_ff @(posedge clk) begin
        rst_meta <= arst;       // 高有效输入
        rst_r    <= rst_meta;   // 第 2 级, 消除亚稳态
    end
    assign rst = rst_r;

endmodule : reset_sync

`endif // RESET_SYNC_SV
