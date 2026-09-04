`timescale 1ns/1ps

// =============================================================================
// tb_da_data_gen.sv  --  da_data_gen 集成测试 (端到端)
// =============================================================================
// 报文配置 4 波束 → 基带激励 → DAC dump
// 验证: 配置链路 + 数据路径端到端 (DAC 非零)
// =============================================================================

import tx_bf_pkg::*;

module tb_da_data_gen;

    logic dac_coreclk = 0, cmd_clk = 0;
    logic rst_dac = 1, rst_cmd = 1;   // 分时钟域异步复位 (高有效, 内部各自同步)
    logic rst_bf = 0;              // 两片同步门 (高有效, 模拟主控拉高)
    logic dac0_nco_0_nco_update_busy = 0;
    logic [47:0] dac0_nco_0_converter0_nco_freq = 0;
    logic dac0_nco_0_nco_update_request = 0;
    logic user_sysref_dac = 0;
    logic [63:0] cmd_data = 0;
    logic        cmd_data_valid = 0;
    // 基带打包向量 (.v 兼容): 波束 b 在 [b*DATA_W +: DATA_W]
    logic signed [N_BEAM*DATA_W-1:0] bb_i;
    logic signed [N_BEAM*DATA_W-1:0] bb_q;
    logic [N_BEAM-1:0]               bb_valid;
    logic                     rst_bf_request;
    logic [INTERP*32-1:0]     s00_axis_0_tdata;

    localparam real CLK_PERIOD = 3.333;  // 300MHz
    always #(CLK_PERIOD/2) dac_coreclk = ~dac_coreclk;
    always #5.0 cmd_clk = ~cmd_clk;  // 100MHz

    // DUT
    da_data_gen u_dut (
        .dac_coreclk(dac_coreclk), .rst_dac(rst_dac), .rst_cmd(rst_cmd), .rst_bf(rst_bf),
        .dac0_nco_0_nco_update_busy(dac0_nco_0_nco_update_busy),
        .dac0_nco_0_converter0_nco_freq(dac0_nco_0_converter0_nco_freq),
        .dac0_nco_0_nco_update_request(dac0_nco_0_nco_update_request),
        .user_sysref_dac(user_sysref_dac),
        .s00_axis_0_tready(1'b1), .s02_axis_0_tready(1'b1),
        .s10_axis_0_tready(1'b1), .s12_axis_0_tready(1'b1),
        .s20_axis_0_tready(1'b1), .s22_axis_0_tready(1'b1),
        .s30_axis_0_tready(1'b1), .s32_axis_0_tready(1'b1),
        .cmd_clk(cmd_clk), .cmd_data(cmd_data), .cmd_data_valid(cmd_data_valid),
        .bb_i(bb_i), .bb_q(bb_q), .bb_valid(bb_valid),
        .s00_axis_0_tdata(s00_axis_0_tdata),
        .rst_bf_request(rst_bf_request)
    );

    // ---------- 报文生成器 (同 tb_decode) ----------
    task automatic send_packet(input [31:0] function_id, input logic [63:0] content_q[$]);
        logic [63:0] pkt[$];
        int i;
        pkt.push_back({32'h7E8118E7, 32'h0000_0040});
        pkt.push_back({16'h0001, 16'h0001, function_id});
        pkt.push_back(64'h0);
        pkt.push_back({32'h0000_0001, 32'h0000_0001});
        pkt.push_back({32'h0000_0001, 32'h0000_0040});
        pkt.push_back({16'h0001, 16'h0000, 32'h0});
        for (i = 0; i < content_q.size(); i++) pkt.push_back(content_q[i]);
        pkt.push_back({32'h0000_0000, 32'h8F9009F8});
        for (i = 0; i < pkt.size(); i++) begin
            @(posedge cmd_clk);
            cmd_data <= pkt[i]; cmd_data_valid <= 1;
        end
        @(posedge cmd_clk); cmd_data_valid <= 0;
    endtask

    // ---------- 基带激励: 4 波束不同频率正弦 ----------
    localparam real bb_freq[4] = '{10e6, 30e6, 50e6, 70e6};
    real t;  // 唯一驱动源: 下方 always_ff (含复位初始化)
    always_ff @(posedge dac_coreclk) begin
        if (rst_dac) begin
            t <= 0;
            for (int b = 0; b < N_BEAM; b++) begin
                bb_i[b*DATA_W +: DATA_W] <= '0;
                bb_q[b*DATA_W +: DATA_W] <= '0;
                bb_valid[b] <= 0;
            end
        end else begin
            t <= t + CLK_PERIOD * 1e-9;
            for (int b = 0; b < N_BEAM; b++) begin
                // 与 tb_tx_top 一致的激励写法: 显式 integer + signed, 幅度 0.5*32767
                bb_i[b*DATA_W +: DATA_W] <= $signed(integer'(0.5 * 32767.0 * $cos(2.0 * 3.14159265 * bb_freq[b] * t)));
                bb_q[b*DATA_W +: DATA_W] <= $signed(integer'(0.5 * 32767.0 * $sin(2.0 * 3.14159265 * bb_freq[b] * t)));
                bb_valid[b] <= 1;
            end
        end
    end

    // ---------- DAC dump ----------
    integer fout;
    initial fout = $fopen("C:/workbuddy_chat/tx_bf_4base/sim_out/da_data_gen_dac.log", "w");
    logic capture_en = 0;
    always_ff @(posedge dac_coreclk) begin
        if (capture_en) begin
            // 从 AXI-Stream TDATA (s00=阵元0) 解包: 每 16bit 交替 {I,Q}
            // tdata[16*2p]=I[p], tdata[16*2p+1]=Q[p]
            for (int p = 0; p < INTERP; p++) begin
                int i_val, q_val;
                i_val = $signed(s00_axis_0_tdata[16*(2*p) +: 16]);
                q_val = $signed(s00_axis_0_tdata[16*(2*p+1) +: 16]);
                $fdisplay(fout, "%d %d", i_val, q_val);
            end
        end
    end

    // ---------- 主流程 ----------
    logic [63:0] content_q[$];
    initial begin
        for (int b = 0; b < N_BEAM; b++) begin
            bb_i[b*DATA_W +: DATA_W] = '0;
            bb_q[b*DATA_W +: DATA_W] = '0;
            bb_valid[b] = 0;
        end

        // 复位
        rst_dac = 1; rst_cmd = 1;   // 复位 (高有效)
        repeat(20) @(posedge dac_coreclk);
        rst_dac = 0; rst_cmd = 0;   // 释放
        // 等待 decode 内 xpm_fifo_async 复位释放 (否则第一个报文前几字丢失)
        repeat(500) @(posedge dac_coreclk);

        // 配置: FIR 直通 + 权重 1+0j + phase_inc + delay + apply
        $display("=== 发送配置报文 ===");
        content_q = {};
        // FIR 分数延时直通系数: 每通道中心抽头 tap=7, coef=16384(1.0)
        // data 格式: {12'b0, tap[3:0], coef[15:0]} → tap=7, coef=0x7FFF → 0x0007_7FFF
        for (int b = 0; b < N_BEAM; b++)
            for (int c = 0; c < N_ELEM; c++)
                content_q.push_back({32'h6702_0000 + b*16 + c, 32'h0007_7FFF});
        // 权重 (beam0..3, ch0..7, re=0x4000, im=0)
        for (int b = 0; b < N_BEAM; b++)
            for (int c = 0; c < N_ELEM; c++)
                content_q.push_back({32'h6703_0000 + b*16 + c, 32'h0000_7FFF});
        // phase_inc (beam0..3 = 200/400/600/800MHz → phase_inc = f/2.4e9 * 2^32)
        content_q.push_back({32'h6705_0000, 32'h15555555}); // beam0 ≈200MHz
        content_q.push_back({32'h6705_0001, 32'h2AAAAAAB}); // beam1 ≈400MHz
        content_q.push_back({32'h6705_0002, 32'h40000000}); // beam2 ≈600MHz
        content_q.push_back({32'h6705_0003, 32'h55555555}); // beam3 ≈800MHz
        // phase_offset=0 (全部)
        // delay=0 (全部)
        for (int b = 0; b < N_BEAM; b++)
            for (int c = 0; c < N_ELEM; c++)
                content_q.push_back({32'h6701_0000 + b*16 + c, 32'h0000_0000});

        send_packet(32'hDABF_000B, content_q);  // apply (delay/phase 帧尾即提交 + rst_bf_request)

        // 模拟主控: 拉高 rst_bf (≥8 拍滤波) → 数据路径同步复位 (流水清零)
        // 注: 配置提交不再依赖 rst_bf (apply 帧尾即提交), rst_bf 仅复位数据路径
        repeat(50) @(posedge dac_coreclk);   // 等 apply 报文处理完
        rst_bf = 1;
        repeat(20) @(posedge dac_coreclk);   // >8 拍滤波通过 → rst_tx 复位数据路径
        rst_bf = 0;

        // 等待配置生效 + 流水排空
        repeat(200) @(posedge dac_coreclk);
        $display("=== 开始采集 DAC 输出 ===");
        capture_en = 1;

        // 采集 2000 拍
        repeat(2000) @(posedge dac_coreclk);
        capture_en = 0;
        $fclose(fout);

        $display("=== 完成: DAC dump → sim_out/da_data_gen_dac.log ===");
        $finish;
    end

    initial begin
        #500000;
        $display("ERROR: 仿真超时");
        $finish;
    end

endmodule : tb_da_data_gen
