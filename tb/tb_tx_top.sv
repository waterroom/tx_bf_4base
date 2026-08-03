// =============================================================================
// tb_tx_top.sv  --  顶层测试台
// =============================================================================
// 功能验证: 4 路基带正弦 → tx_top → 8 路 DAC 输出, 检查数据流连通性。
// 配置: 4 波束不同 LO 频率, delay_val=0, weight=1+0j (简化验证)。
//
// 注: 完整 SQNR 对比需配合 MATLAB 生成的 test vector (tb_gen.m)。
//     本 TB 为基础数据流验证。
// =============================================================================

`timescale 1ns/1ps

`include "tx_top.sv"
import tx_bf_pkg::*;

module tb_tx_top;

    // ---------- 时钟与复位 ----------
    logic clk_300m;
    logic async_rst_n;
    localparam real CLK_PERIOD = 3.333;  // 300MHz

    always #(CLK_PERIOD/2.0) clk_300m = ~clk_300m;

    // ---------- DUT 信号 ----------
    logic signed [DATA_W-1:0] bb_i [N_BEAM-1:0];
    logic signed [DATA_W-1:0] bb_q [N_BEAM-1:0];
    logic                     bb_valid [N_BEAM-1:0];
    logic                     apb_psel, apb_penable, apb_pwrite;
    logic [15:0]              apb_paddr;
    logic [31:0]              apb_pwdata;
    logic                     apb_pready;
    logic [31:0]              apb_prdata;
    logic                     apb_pslverr;
    logic signed [DAC_W-1:0]  dac_i_8p [N_ELEM-1:0][INTERP-1:0];
    logic signed [DAC_W-1:0]  dac_q_8p [N_ELEM-1:0][INTERP-1:0];
    logic                     dac_valid [N_ELEM-1:0];

    // ---------- DUT 例化 ----------
    tx_top u_dut (
        .clk_300m    (clk_300m),
        .async_rst_n (async_rst_n),
        .bb_i        (bb_i),
        .bb_q        (bb_q),
        .bb_valid    (bb_valid),
        .apb_psel    (apb_psel),
        .apb_penable (apb_penable),
        .apb_pwrite  (apb_pwrite),
        .apb_paddr   (apb_paddr),
        .apb_pwdata  (apb_pwdata),
        .apb_pready  (apb_pready),
        .apb_prdata  (apb_prdata),
        .apb_pslverr (apb_pslverr),
        .dac_i_8p    (dac_i_8p),
        .dac_q_8p    (dac_q_8p),
        .dac_valid   (dac_valid)
    );

    // ---------- 基带正弦激励 (4 路不同频率) ----------
    // 10/30/50/70 MHz 单音, 16bit 有符号, 幅度 0.5
    real bb_freq [N_BEAM-1:0];
    initial begin
        bb_freq[0] = 10e6; bb_freq[1] = 30e6;
        bb_freq[2] = 50e6; bb_freq[3] = 70e6;
    end

    real t;
    always_ff @(posedge clk_300m) begin
        if (!async_rst_n) begin
            for (int b = 0; b < N_BEAM; b++) begin
                bb_i[b] <= '0;
                bb_q[b] <= '0;
                bb_valid[b] <= 1'b0;
            end
        end else begin
            t = t + CLK_PERIOD * 1e-9;  // 时间步进 (秒)
            for (int b = 0; b < N_BEAM; b++) begin
                bb_i[b] <= $signed(integer'(0.5 * 32767.0 * $cos(2.0 * 3.14159265 * bb_freq[b] * t)));
                bb_q[b] <= $signed(integer'(0.5 * 32767.0 * $sin(2.0 * 3.14159265 * bb_freq[b] * t)));
                bb_valid[b] <= 1'b1;
            end
        end
    end

    // ---------- 输出采样 ----------
    integer fout;
    integer sample_count;
    initial begin
        fout = $fopen("sim_out/dac_out_8p.log", "w");
        if (fout == 0) $display("ERROR: 无法打开输出文件");
        $fdisplay(fout, "# tx_top DAC 输出 (8 阵元 × 8 并行 复数 I/Q)");
    end

    always_ff @(posedge clk_300m) begin
        if (dac_valid[0]) begin
            for (int p = 0; p < INTERP; p++)
                $fdisplay(fout, "%d %d", dac_i_8p[0][p], dac_q_8p[0][p]);
            sample_count = sample_count + 1;
        end
    end

    // ---------- 主流程 ----------
    initial begin
        // 初始化
        clk_300m    = 0;
        async_rst_n = 0;
        t           = 0.0;
        sample_count = 0;
        apb_psel    = 0; apb_penable = 0; apb_pwrite = 0;
        apb_paddr   = 0; apb_pwdata  = 0;
        for (int b = 0; b < N_BEAM; b++) begin
            bb_i[b] = '0; bb_q[b] = '0; bb_valid[b] = 0;
        end

        // 复位
        #(CLK_PERIOD * 10);
        async_rst_n = 1;
        #(CLK_PERIOD * 5);

        // 运行
        $display("=== 仿真开始: 4 波束 4 频率, 采集 DAC 输出 ===");
        #(CLK_PERIOD * 2000);  // 2000 拍

        $display("=== 仿真结束, 采集 %0d 个 DAC 样本 ===", sample_count);
        $fclose(fout);
        $finish;
    end

    // 超时保护
    initial begin
        #(CLK_PERIOD * 100000);
        $display("ERROR: 仿真超时");
        $finish;
    end

endmodule : tb_tx_top
