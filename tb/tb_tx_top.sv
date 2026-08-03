// =============================================================================
// tb_tx_top.sv  --  顶层测试台
// =============================================================================
// 功能验证: 4 路基带正弦 → tx_top → 8 路 DAC 输出。
// 配置流程 (APB):
//   1) 每波束每通道加载 FIR 系数 (t=7 处冲激 0x7FFF, 直通分数延时)
//   2) 每波束每通道加载复数权重 (re=0x7FFF≈1.0, im=0)
//   3) 每波束加载 phase_inc (LO 频率: 200/900/1500/2200 MHz)
//   4) delay_val 保持 0
// 预期: 8 路 DAC 输出 4 个 LO 频率的混频信号 (非零)
//
// 注: 完整 SQNR 对比需配合 MATLAB test vector (tb_gen.m), 本 TB 验证数据流。
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
    real bb_freq [N_BEAM-1:0];
    real t = 0.0;
    initial begin
        bb_freq[0] = 10e6; bb_freq[1] = 30e6;
        bb_freq[2] = 50e6; bb_freq[3] = 70e6;
    end

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
    integer sample_count;   // 仅在下方 always_ff 中驱动 (避免多驱动错误)
    initial begin
        fout = $fopen("sim_out/dac_out_8p.log", "w");
        if (fout == 0) $display("ERROR: 无法打开 sim_out/dac_out_8p.log");
        else           $fdisplay(fout, "# tx_top DAC 输出 (阵元0: 8并行 I/Q)");
    end

    always_ff @(posedge clk_300m) begin
        if (!async_rst_n) begin
            sample_count <= 0;
        end else if (dac_valid[0]) begin
            for (int p = 0; p < INTERP; p++)
                $fdisplay(fout, "%d %d", dac_i_8p[0][p], dac_q_8p[0][p]);
            sample_count <= sample_count + 1;
        end
    end

    // (调试用的内部信号 dump 已移除, 验证完成)

    // =========================================================================
    // APB 写任务
    // =========================================================================
    task automatic apb_write(input [15:0] addr, input [31:0] data);
        @(posedge clk_300m);
        apb_psel = 1'b1; apb_penable = 1'b0; apb_pwrite = 1'b1;
        apb_paddr = addr; apb_pwdata = data;
        @(posedge clk_300m);
        apb_penable = 1'b1;
        @(posedge clk_300m);
        apb_psel = 1'b0; apb_penable = 1'b0;
        @(posedge clk_300m);
    endtask

    // 波束配置: FIR 系数 (直通) + 权重 (1+0j) + phase_inc
    task automatic cfg_beam(input int beam, input longint phase_inc);
        // 每通道: FIR 系数 t=7 处冲激 (直通, 系数 32767≈1.0)
        for (int c = 0; c < N_ELEM; c++) begin
            // pwdata = {coef_data[15:0], coef_addr[3:0], sel_ch[3:0], 8'h0}
            //   cfg_bus 解码: data=pwdata[31:16], addr=pwdata[15:12], sel=pwdata[11:8]
            apb_write(beam * 16'h40 + 16'h20, {16'h7FFF, 4'h7, c[3:0], 8'h00});
        end
        // 每通道: 复数权重 re=0x7FFF(≈1.0), im=0
        for (int c = 0; c < N_ELEM; c++) begin
            apb_write(beam * 16'h40 + 16'h08 + c[15:0], 32'h00007FFF);  // weight_re[c]
            apb_write(beam * 16'h40 + 16'h10 + c[15:0], 32'h00000000);  // weight_im[c]
        end
        // LO 频率: phase_inc (32bit)
        apb_write(beam * 16'h40 + 16'h18, phase_inc[31:0]);   // phase_inc
        apb_write(beam * 16'h40 + 16'h19, 32'h00000000);      // phase_offset
    endtask

    // 计算 phase_inc: f_LO / 2.4GHz * 2^32
    function automatic longint calc_phase_inc(input real f_lo_hz);
        calc_phase_inc = longint'(f_lo_hz / 2.4e9 * 4294967296.0);
    endfunction

    // ---------- 主流程 ----------
    initial begin
        // 初始化
        clk_300m    = 0;
        async_rst_n = 0;
        apb_psel    = 0; apb_penable = 0; apb_pwrite = 0;
        apb_paddr   = 0; apb_pwdata  = 0;
        for (int b = 0; b < N_BEAM; b++) begin
            bb_i[b] = '0; bb_q[b] = '0; bb_valid[b] = 0;
        end

        // 复位
        #(CLK_PERIOD * 10);
        async_rst_n = 1;
        #(CLK_PERIOD * 5);

        // 配置 4 个波束
        $display("=== 配置波束 0..3 (LO: 200/900/1500/2200 MHz) ===");
        cfg_beam(0, calc_phase_inc(200e6));
        cfg_beam(1, calc_phase_inc(900e6));
        cfg_beam(2, calc_phase_inc(1500e6));
        cfg_beam(3, calc_phase_inc(2200e6));
        $display("=== 配置完成, 开始采集 ===");

        // 运行
        #(CLK_PERIOD * 2000);  // 2000 拍

        $display("=== 仿真结束, 采集 %0d 个 DAC 样本 ===", sample_count);
        if (fout) $fclose(fout);
        $finish;
    end

    // 超时保护
    initial begin
        #(CLK_PERIOD * 100000);
        $display("ERROR: 仿真超时");
        $finish;
    end

endmodule : tb_tx_top
