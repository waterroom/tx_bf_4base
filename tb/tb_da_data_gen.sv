`timescale 1ns/1ps

// =============================================================================
// tb_da_data_gen.sv  --  da_data_gen 集成测试 (端到端)
// =============================================================================
// 报文配置 4 波束 → 基带激励 → DAC dump
// 验证: 配置链路 + 数据路径端到端 (DAC 非零)
// =============================================================================

import tx_bf_pkg::*;

module tb_da_data_gen;

    logic dac_coreclk = 0, cmd_clk = 0, async_rst_n = 0;
    logic [63:0] cmd_data = 0;
    logic        cmd_data_valid = 0;
    logic signed [DATA_W-1:0] bb_i [N_BEAM-1:0];
    logic signed [DATA_W-1:0] bb_q [N_BEAM-1:0];
    logic                     bb_valid [N_BEAM-1:0];
    logic signed [DAC_W-1:0]  dac_i_8p [N_ELEM-1:0][INTERP-1:0];
    logic signed [DAC_W-1:0]  dac_q_8p [N_ELEM-1:0][INTERP-1:0];
    logic                     dac_valid [N_ELEM-1:0];
    logic                     rst_bf_request;

    localparam real CLK_PERIOD = 3.333;  // 300MHz
    always #(CLK_PERIOD/2) dac_coreclk = ~dac_coreclk;
    always #5.0 cmd_clk = ~cmd_clk;  // 100MHz

    // DUT
    da_data_gen u_dut (
        .dac_coreclk(dac_coreclk), .async_rst_n(async_rst_n),
        .cmd_clk(cmd_clk), .cmd_data(cmd_data), .cmd_data_valid(cmd_data_valid),
        .bb_i(bb_i), .bb_q(bb_q), .bb_valid(bb_valid),
        .dac_i_8p(dac_i_8p), .dac_q_8p(dac_q_8p), .dac_valid(dac_valid),
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
    real t;
    always_ff @(posedge dac_coreclk) begin
        t <= t + CLK_PERIOD * 1e-9;
        for (int b = 0; b < N_BEAM; b++) begin
            bb_i[b] <= $sin(2*3.14159265*bb_freq[b]*t) * 1000;
            bb_q[b] <= $cos(2*3.14159265*bb_freq[b]*t) * 1000;
            bb_valid[b] <= 1;
        end
    end

    // ---------- DAC dump ----------
    integer fout;
    initial fout = $fopen("C:/workbuddy_chat/tx_bf_4base/sim_out/da_data_gen_dac.log", "w");
    logic capture_en = 0;
    always_ff @(posedge dac_coreclk) begin
        if (capture_en && dac_valid[0]) begin
            for (int p = 0; p < INTERP; p++)
                $fdisplay(fout, "%d %d", dac_i_8p[0][p], dac_q_8p[0][p]);
        end
    end

    // ---------- 主流程 ----------
    logic [63:0] content_q[$];
    initial begin
        t = 0;
        for (int b = 0; b < N_BEAM; b++) begin bb_i[b] = 0; bb_q[b] = 0; bb_valid[b] = 0; end

        // 复位
        async_rst_n = 0;
        repeat(20) @(posedge dac_coreclk);
        async_rst_n = 1;
        repeat(20) @(posedge dac_coreclk);

        // 配置: 权重 1+0j (每波束每通道) + phase_inc (每波束) + apply
        $display("=== 发送配置报文 ===");
        content_q = {};
        // 权重 (beam0..3, ch0..7, re=0x4000, im=0) —— 简化: 只配 beam0 的 ch0
        for (int b = 0; b < 1; b++)
            for (int c = 0; c < N_ELEM; c++)
                content_q.push_back({32'h6703_0000 + b*8 + c, 32'h0000_4000});
        // phase_inc (beam0 = 200MHz → phase_inc = 200e6/2.4e9 * 2^32)
        content_q.push_back({32'h6705_0000, 32'h36BA2E8B}); // ≈200MHz
        content_q.push_back({32'h6706_0000, 32'h0000_0000}); // phase_offset=0
        // delay=0 (全部)
        for (int c = 0; c < N_ELEM; c++)
            content_q.push_back({32'h6701_0000 + c, 32'h0000_0000});

        send_packet(32'h0A0C_000B, content_q);  // apply

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
