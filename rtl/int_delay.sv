`timescale 1ns/1ps

// =============================================================================
// int_delay.sv  --  Parameterized integer (full-sample) delay line
// =============================================================================
// 用移位寄存器实现整数个采样延迟。延迟值通过 delay_val 端口按通道配置，
// 最大深度由参数 MAX_DEPTH 决定。复数 I/Q 一同移位（共用一条延迟线）。
//
// 特点：
//   - 0 个 DSP（纯移位寄存器 + 多路选择）
//   - 支持 valid 流水（valid 一同移位，保持帧对齐）
//   - delay_val 实时可变，建议与数据同步更新
//   - 复用为单通道：N=1 时退化为单根延迟线
//   - 输出延时为delay_val+2
// 参数：
//   DATA_W    : I/Q 各自位宽
//   MAX_DEPTH : 最大延迟深度（采样周期数），默认 64
// =============================================================================

`ifndef INT_DELAY_SV
`define INT_DELAY_SV

module int_delay #(
    parameter int unsigned DATA_W    = 16,
    parameter int unsigned MAX_DEPTH  = 64
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

    // 移位寄存器：宽 2*DATA_W，深 MAX_DEPTH+1（含当前拍）
    localparam int unsigned STG_W = 2 * DATA_W;
    localparam int unsigned SEL_W = $clog2(MAX_DEPTH+1);

    logic [STG_W-1:0] shift_mem [0:MAX_DEPTH];
    logic             valid_mem [0:MAX_DEPTH];

    // 写入：当前输入始终进入 shift_mem[0]（I/Q 打包为 {im, re}）
    // 注意：移位寄存器不复位，综合器可推断为 SRL（移位寄存器）或 BRAM，节省 FF 资源
    always_ff @(posedge clk) begin
        shift_mem[0] <= {in_im, in_re};
        valid_mem[0] <= valid_in;
        for (int i = 1; i <= MAX_DEPTH; i++) begin
            shift_mem[i] <= shift_mem[i-1];
            valid_mem[i] <= valid_mem[i-1];
        end
    end

    // 选择输出：按 delay_val 从对应的延迟抽头读出（寄存输出，时序友好）
logic [SEL_W-1:0] sel_r;
always_ff @(posedge clk) begin
    sel_r <= (delay_val > MAX_DEPTH) ? MAX_DEPTH[SEL_W-1:0] : delay_val[SEL_W-1:0];
end
always_ff @(posedge clk) begin
    if (rst) begin
        out_re    <= '0;
        out_im    <= '0;
        valid_out <= 1'b0;
    end else begin
        out_re    <= shift_mem[sel_r][DATA_W-1:0];
        out_im    <= shift_mem[sel_r][2*DATA_W-1:DATA_W];
        valid_out <= valid_mem[sel_r];
    end
end

endmodule : int_delay

`endif // INT_DELAY_SV