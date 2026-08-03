// =============================================================================
// reset_sync.sv  --  同步释放复位同步器 (高有效)
// =============================================================================
// 异步置位 + 同步释放: 外部 async_rst_n 低有效时立即拉高 rst (异步路径),
// 释放时 rst 经 2 级 FF 同步到 clk 后才拉低。
// 全模块共用此单一 rst, 避免多处异步复位树。
//
// 端口:
//   clk          : 主时钟 300MHz
//   async_rst_n  : 外部异步复位 (按键/上电), 低有效
//   rst          : 同步释放高有效复位 (喂给所有子模块)
// =============================================================================

`ifndef RESET_SYNC_SV
`define RESET_SYNC_SV

module reset_sync (
    input  logic clk,
    input  logic async_rst_n,   // 低有效异步复位
    output logic rst            // 高有效同步释放复位
);

    // 第 1 级: 异步置位 + 同步释放 (复位时立刻拉高, 释放时同步拉低)
    logic rst_meta;
    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n)
            rst_meta <= 1'b1;     // 异步置位: 复位期间 rst 立即为高
        else
            rst_meta <= 1'b0;     // 同步释放: async_rst_n 拉高后, 经 clk 同步拉低
    end

    // 第 2 级: 同步去亚稳态, 保证 rst 释放沿严格对齐 clk
    always_ff @(posedge clk) begin
        rst <= rst_meta;
    end

endmodule : reset_sync

`endif // RESET_SYNC_SV
