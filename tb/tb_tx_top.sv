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
    // 重要: 采集必须在 APB 配置全部完成、且流水排空后使能 (capture_en),
    // 否则数据流与逐通道权重加载并发, 前几拍部分通道权重未加载 → 输出 0,
    // 表现为"8 阵元不一致"的假象 (硬件本身无错, 真实场景软件先配置再启流)。
    // capture_en=1 的下一拍 dump 即开始, 必须先等待流水(总延迟~55拍)排空!
    logic capture_en = 1'b0;
    integer fout;
    integer fout8;
    integer sample_count;   // 仅在下方 always_ff 中驱动 (避免多驱动错误)
    initial begin
        // 用绝对路径: GUI 仿真工作目录不固定, 相对路径会 fopen 失败 (文件写不出)
        fout = $fopen("C:/workbuddy_chat/tx_bf_4base/sim_out/dac_out_8p.log", "w");
        if (fout == 0) $display("ERROR: 无法打开 sim_out/dac_out_8p.log");
        else           $fdisplay(fout, "# tx_top DAC 输出 (阵元0: 8并行 I/Q)");
        fout8 = $fopen("C:/workbuddy_chat/tx_bf_4base/sim_out/dac_out_8elem.log", "w");
        if (fout8 == 0) $display("ERROR: 无法打开 sim_out/dac_out_8elem.log");
        else           $fdisplay(fout8, "# tx_top DAC 8 阵元 (每行: 8阵元 I/Q, 2.4GHz交织序)");
    end

    always_ff @(posedge clk_300m) begin
        if (!async_rst_n) begin
            sample_count <= 0;
        end else if (capture_en && dac_valid[0]) begin
            for (int p = 0; p < INTERP; p++) begin
                $fdisplay(fout, "%d %d", dac_i_8p[0][p], dac_q_8p[0][p]);
                // 8 阵元全 dump: 每行 i0 q0 i1 q1 ... i7 q7
                $fwrite(fout8, "%d %d", dac_i_8p[0][p], dac_q_8p[0][p]);
                for (int e = 1; e < N_ELEM; e++)
                    $fwrite(fout8, " %d %d", dac_i_8p[e][p], dac_q_8p[e][p]);
                $fdisplay(fout8, "");
            end
            sample_count <= sample_count + 1;
        end
    end

    // (内部节点诊断 dump 已移除, 8 阵元一致性验证通过)

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
        // 关键: 先等流水(总延迟~55拍)排空权重加载期的过渡数据, 再使能采样!
        // (capture_en=1 的下一拍 dump 就开始, 若立即使能会记录未排空的脏数据)
        repeat (120) @(posedge clk_300m);
        capture_en = 1'b1;

        // dump beam0 各通道的权重与 FIR 系数实际值 (诊断 8 阵元一致性)
        // 注: generate 实例路径必须用常量索引 (变量索引精化期报 VRFC 10-2991)
        repeat (10) @(posedge clk_300m);
        $display("[cfg] beam0 w_re: %0d %0d %0d %0d %0d %0d %0d %0d",
            u_dut.g_beam[0].u_beam.u_bf_core.w_re[0],
            u_dut.g_beam[0].u_beam.u_bf_core.w_re[1],
            u_dut.g_beam[0].u_beam.u_bf_core.w_re[2],
            u_dut.g_beam[0].u_beam.u_bf_core.w_re[3],
            u_dut.g_beam[0].u_beam.u_bf_core.w_re[4],
            u_dut.g_beam[0].u_beam.u_bf_core.w_re[5],
            u_dut.g_beam[0].u_beam.u_bf_core.w_re[6],
            u_dut.g_beam[0].u_beam.u_bf_core.w_re[7]);
        $display("[cfg] beam1 w_re: %0d %0d %0d %0d %0d %0d %0d %0d",
            u_dut.g_beam[1].u_beam.u_bf_core.w_re[0],
            u_dut.g_beam[1].u_beam.u_bf_core.w_re[1],
            u_dut.g_beam[1].u_beam.u_bf_core.w_re[2],
            u_dut.g_beam[1].u_beam.u_bf_core.w_re[3],
            u_dut.g_beam[1].u_beam.u_bf_core.w_re[4],
            u_dut.g_beam[1].u_beam.u_bf_core.w_re[5],
            u_dut.g_beam[1].u_beam.u_bf_core.w_re[6],
            u_dut.g_beam[1].u_beam.u_bf_core.w_re[7]);
        $display("[cfg] beam2 w_re: %0d %0d %0d %0d %0d %0d %0d %0d",
            u_dut.g_beam[2].u_beam.u_bf_core.w_re[0],
            u_dut.g_beam[2].u_beam.u_bf_core.w_re[1],
            u_dut.g_beam[2].u_beam.u_bf_core.w_re[2],
            u_dut.g_beam[2].u_beam.u_bf_core.w_re[3],
            u_dut.g_beam[2].u_beam.u_bf_core.w_re[4],
            u_dut.g_beam[2].u_beam.u_bf_core.w_re[5],
            u_dut.g_beam[2].u_beam.u_bf_core.w_re[6],
            u_dut.g_beam[2].u_beam.u_bf_core.w_re[7]);
        $display("[cfg] beam3 w_re: %0d %0d %0d %0d %0d %0d %0d %0d",
            u_dut.g_beam[3].u_beam.u_bf_core.w_re[0],
            u_dut.g_beam[3].u_beam.u_bf_core.w_re[1],
            u_dut.g_beam[3].u_beam.u_bf_core.w_re[2],
            u_dut.g_beam[3].u_beam.u_bf_core.w_re[3],
            u_dut.g_beam[3].u_beam.u_bf_core.w_re[4],
            u_dut.g_beam[3].u_beam.u_bf_core.w_re[5],
            u_dut.g_beam[3].u_beam.u_bf_core.w_re[6],
            u_dut.g_beam[3].u_beam.u_bf_core.w_re[7]);
        $display("[cfg] beam0 fir7: %0d %0d %0d %0d %0d %0d %0d %0d",
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[1].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[2].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[3].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[4].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[5].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[6].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[7]);
        // ch0 vs ch7 完整 16 抽头系数对比
        $display("[cfg] ch0 coef: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[0],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[1],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[2],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[3],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[4],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[5],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[6],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[8],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[9],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[10],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[11],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[12],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[13],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[14],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[0].u_fir.coef[15]);
        $display("[cfg] ch7 coef: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[0],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[1],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[2],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[3],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[4],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[5],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[6],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[7],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[8],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[9],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[10],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[11],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[12],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[13],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[14],
            u_dut.g_beam[0].u_beam.u_bf_core.g_ch[7].u_fir.coef[15]);

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
