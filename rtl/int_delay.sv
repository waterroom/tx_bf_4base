`timescale 1ns/1ps

// =============================================================================
// int_delay.sv  --  Parameterized integer (full-sample) delay line (BRAM 版)
// =============================================================================
// 用 BRAM 环形缓冲实现整数个采样延迟 (深度 >128 场景)。
// 背景: 原 SRL 分段结构 (MAX_DEPTH=1024, N_SEG=33) 在 4 波束 × 8 通道 =
// 32 实例时产生 ~56K LUTRAM/SRL, place 时 pack 不收敛 (62174 SRL →
// 实际需求 268790 slices > 26700) → 布局失败。BRAM 环形缓冲每实例
// 1 个 36K BRAM (33 bit {valid,im,re} × 1024 深), 32 实例 = 32 BRAM (<3%),
// 彻底消除 LUTRAM pack 问题。
//
// 延迟语义: delay_val + 3 (读指针寄存 1 拍 + BRAM 同步读 1 拍 + 输出寄存 1 拍)。
// 硬件与行为仿真一致 (BRAM 读固定 1 拍, 无 SRL A=0 直通差异)。
// 读指针寄存: 减法单独一拍 (wr_ptr-delay 组合 + BRAM 地址同拍会紧时序)。
//
// 参数:
//   DATA_W    : I/Q 各自位宽
//   MAX_DEPTH : 最大延迟深度 (≥2; BRAM 深度取 2^ceil(log2(MAX_DEPTH)))
// =============================================================================

`ifndef INT_DELAY_SV
`define INT_DELAY_SV

module int_delay #(
    parameter int unsigned DATA_W    = 16,
    parameter int unsigned MAX_DEPTH = 64
) (
    input  logic                          clk,
    input  logic                          rst,          // 高有效
    input  logic                          valid_in,
    input  logic signed [DATA_W-1:0]     in_re,
    input  logic signed [DATA_W-1:0]     in_im,
    input  logic [$clog2(MAX_DEPTH+1)-1:0] delay_val,   // 0..MAX_DEPTH
    output logic signed [DATA_W-1:0]     out_re,
    output logic signed [DATA_W-1:0]     out_im,
    output logic                          valid_out
);

    // -------------- 位宽 --------------
    localparam int unsigned STG_W = 2 * DATA_W;              // I/Q 打包位宽 (32)
    localparam int unsigned PTR_W = $clog2(MAX_DEPTH);       // 指针位宽 (2^PTR_W ≥ MAX_DEPTH)
    localparam int unsigned DEPTH = 1 << PTR_W;              // BRAM 深度 (2 的幂)

    // -------------- BRAM 环形缓冲 {valid, im, re} = STG_W+1 = 33 bit --------------
    // 33 bit × 1024 深 = 1 个 36K BRAM (36Kb = 1024×36 模式 ?)
    (* ram_style = "block" *) logic [STG_W:0] mem [0:DEPTH-1];
    // BRAM 初始化 0 (valid 初始 0, 避免 X 传播)
    initial begin
        for (int i = 0; i < DEPTH; i++) mem[i] = '0;
    end

    logic [PTR_W-1:0] wr_ptr;

    // 写: 指针递增 (2 的幂自然回绕), 数据+valid 同址写入
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
        end else begin
            mem[wr_ptr] <= {valid_in, in_im, in_re};
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // 读指针 = wr_ptr - delay (模 2^PTR_W; delay 已钳制 ≤ MAX_DEPTH ≤ DEPTH)
    // 寄存一拍: 减法单独一拍, 避免 wr_ptr→减法→BRAM 地址 同拍长路径
    logic [PTR_W-1:0] rd_ptr_r;
    always_ff @(posedge clk) begin
        if (rst) rd_ptr_r <= '0;
        else     rd_ptr_r <= wr_ptr - delay_val[PTR_W-1:0];
    end

    // BRAM 同步读 (地址已寄存, 读延迟 1 拍)
    logic [STG_W:0] rd_data_r;
    always_ff @(posedge clk) begin
        rd_data_r <= mem[rd_ptr_r];
    end

    // 输出寄存 (延迟 +1 拍)
    always_ff @(posedge clk) begin
        if (rst) begin
            out_re    <= '0;
            out_im    <= '0;
            valid_out <= 1'b0;
        end else begin
            out_re    <= rd_data_r[DATA_W-1:0];
            out_im    <= rd_data_r[2*DATA_W-1:DATA_W];
            valid_out <= rd_data_r[STG_W];
        end
    end

endmodule : int_delay

`endif // INT_DELAY_SV
