% =============================================================================
% tx_bf_verify.m  --  验证 FPGA 仿真输出 vs 模型参考 (tx_bf_4base)
% =============================================================================
% 用法 (参考仓库模式: 一个 model + 一个 verify):
%   tx_bf_verify          % 全量验证 (GUI 下自动绘图)
%   tx_bf_verify(0)       % 仅文本报告 (无图形桌面/batch 模式)
%   前置: 先跑 Vivado 仿真 (scripts/run_sim.tcl 或 run_all.bat),
%         生成 sim_out/dac_out_8elem.log (FPGA 8 阵元输出)
%
% 验证内容:
%   1) FPGA 8 阵元频谱: 每阵元 4 波束峰 (210/930/-850/-130 MHz) 频率/幅度
%   2) 8 阵元一致性: 本 TB 配置 (delay=0, weight=1) 下应逐样本一致
%   3) 模型对比: 同配置跑 tx_bf_duc_model (浮点黄金参考), 对比峰频率
%
% 判据 (全部通过 = PASS):
%   - 每阵元 4 波束峰频率与预期偏差 < 1 MHz
%   - 8 阵元最大逐样本差 < 1 (LSD)
%   - FPGA 峰频率与模型一致 (偏差 < 1 MHz)
% =============================================================================

function tx_bf_verify(do_plot)
    if nargin < 1, do_plot = usejava('desktop'); end

    mdir = fileparts(mfilename('fullpath'));
    addpath(fullfile(mdir, 'utils'));

    % 仓库根目录 = matlab/ 的上一级 (可从任意工作目录运行)
    repoRoot = fileparts(mdir);
    logFile  = fullfile(repoRoot, 'sim_out', 'dac_out_8elem.log');

    % ---- 1. 读 FPGA 仿真输出 (8 阵元 × 2.4GHz 交织序列) ----
    fid = fopen(logFile, 'r');
    if fid < 0
        error('找不到 FPGA 仿真输出: %s\n请先运行 scripts/run_sim.tcl (或 run_all.bat) 生成仿真结果', logFile);
    end
    fgetl(fid);                                   % 跳过标题
    raw = textscan(fid, repmat('%d ', 1, 16));    % i0 q0 i1 q1 ... i7 q7
    fclose(fid);

    NE = 8;
    N  = numel(raw{1});
    I  = zeros(N, NE);  Q = zeros(N, NE);
    for e = 1:NE
        I(:,e) = double(raw{2*e-1});
        Q(:,e) = double(raw{2*e});
    end
    Fs = 2.4e9;                                   % 2.4 GHz (8 并行等效)
    f  = ((0:N-1) - N/2) / N * Fs;
    fprintf('=== tx_bf_4base FPGA 仿真验证 ===\n');
    fprintf('样本数/阵元: %d (2.4GHz 域), 文件: %s\n', N, logFile);

    % ---- 2. 频谱峰验证 (8 阵元 × 4 波束) ----
    f_LO = [200, 900, 1500, 2200] * 1e6;          % 4 波束 LO
    f_bb = [10, 30, 50, 70] * 1e6;                % 4 路基带
    f_exp = f_LO + f_bb;                          % 预期峰 (LO+基带)
    f_exp(f_exp > Fs/2) = f_exp(f_exp > Fs/2) - Fs;   % >1.2GHz 混叠到负频
    f_exp = sort(f_exp);                          % [-850 -130 210 930] MHz

    win = hann(N);
    peak_db = zeros(NE, 4);  peak_f = zeros(NE, 4);
    fprintf('\n--- [1/3] 8 阵元频谱峰 ---\n');
    for e = 1:NE
        sig = complex(I(:,e), Q(:,e));
        sig = sig - mean(sig);
        S   = abs(fftshift(fft(sig .* win)));
        for k = 1:4
            mask  = abs(f - f_exp(k)) < 50e6;
            f_m   = f(mask);  S_m = S(mask);
            [pk, idx] = max(S_m);
            peak_f(e,k)  = f_m(idx);
            peak_db(e,k) = 20*log10(pk/(N/2) + eps);
        end
        fprintf('  阵元%d: ', e-1);
        fprintf(' %.0fMHz(%.1fdB) %.0fMHz(%.1fdB) %.0fMHz(%.1fdB) %.0fMHz(%.1fdB)\n', ...
            peak_f(e,1)/1e6, peak_db(e,1), peak_f(e,2)/1e6, peak_db(e,2), ...
            peak_f(e,3)/1e6, peak_db(e,3), peak_f(e,4)/1e6, peak_db(e,4));
    end
    freq_err = max(abs(peak_f - repmat(f_exp, NE, 1)), [], 'all') / 1e6;
    fprintf('  峰频率最大偏差: %.2f MHz (判据 <1MHz)\n', freq_err);

    % ---- 3. 8 阵元一致性 (delay=0/weight=1 下应逐样本一致) ----
    fprintf('\n--- [2/3] 8 阵元一致性 ---\n');
    ref = complex(I(:,1), Q(:,1));
    max_diff = zeros(NE-1, 1);
    for e = 2:NE
        max_diff(e-1) = max(abs(complex(I(:,e), Q(:,e)) - ref));
    end
    fprintf('  阵元0 vs 1..7 最大逐样本差: %s\n', num2str(max_diff', '%.3f '));
    cons_err = max(max_diff);
    fprintf('  一致性最大差: %.3f (判据 <1)\n', cons_err);

    % ---- 4. 模型对比 (同配置浮点参考) ----
    fprintf('\n--- [3/3] 模型对比 (tx_bf_duc_model 同配置) ---\n');
    cfg = make_default_cfg();
    cfg.int_d   = zeros(cfg.N_BEAM, cfg.N_ELEM);   % 与 TB 一致: 无 TTD
    cfg.frac_d  = zeros(cfg.N_BEAM, cfg.N_ELEM);
    cfg.weight  = ones(cfg.N_BEAM, cfg.N_ELEM);
    N_model     = min(1024, floor(N / 8));          % 模型基带样本数 (FFT 分辨率够)
    [dac, ~]    = tx_bf_duc_model(N_model, cfg);
    sig_m = dac.i(1, :) + 1j * dac.q(1, :);        % 阵元0
    sig_m = sig_m - mean(sig_m);
    Nm    = numel(sig_m);
    S_m   = abs(fftshift(fft(sig_m .* hann(Nm).')));
    f_m   = ((0:Nm-1) - Nm/2) / Nm * Fs;
    fprintf('  模型参考 (阵元0, N=%d 基带样本):\n', N_model);
    model_f = zeros(1, 4);
    for k = 1:4
        mask  = abs(f_m - f_exp(k)) < 50e6;
        f_mm  = f_m(mask);  S_mm = S_m(mask);
        [pk, idx] = max(S_mm);
        model_f(k) = f_mm(idx);
        fprintf('    波束%d 峰 %.0f MHz (%.1f dB)\n', k, model_f(k)/1e6, ...
            20*log10(pk/(Nm/2) + eps));
    end
    model_err = max(abs(model_f - f_exp), [], 'all') / 1e6;
    fprintf('  模型峰频率偏差: %.2f MHz\n', model_err);
    fpga_vs_model = max(abs(peak_f(1,:) - model_f), [], 'all') / 1e6;
    fprintf('  FPGA vs 模型峰频率差: %.2f MHz (判据 <1MHz)\n', fpga_vs_model);

    % ---- 5. 汇总 PASS/FAIL ----
    fprintf('\n=== 验证结论 ===\n');
    pass = (freq_err < 1) && (cons_err < 1) && (fpga_vs_model < 1);
    if pass
        fprintf('  PASS ✅  FPGA 8 阵元输出全部正确 (4 波束 4 频率, 与模型一致)\n');
    else
        fprintf('  FAIL ❌  见上方超标项\n');
    end

    % ---- 6. 频谱图 (可选: 显示 + 保存 PNG) ----
    if do_plot
        fig = figure('Name', 'tx_bf_verify: FPGA 8 阵元频谱', 'Position', [100 100 960 420]);
        hold on;
        for e = 1:NE
            sig = complex(I(:,e), Q(:,e));
            S   = abs(fftshift(fft((sig - mean(sig)) .* win)));
            plot(f/1e6, 20*log10(S/(N/2) + eps), 'LineWidth', 0.5);
        end
        for k = 1:4
            xline(f_exp(k)/1e6, 'r--', sprintf('%.0fMHz', f_exp(k)/1e6));
        end
        grid on;
        xlabel('频率 (MHz)'); ylabel('幅度 (dB)');
        title('FPGA 仿真 8 阵元 DAC 频谱 (4 波束)');
        xlim([-1200 1200]); ylim([-120 10]);
        legend(arrayfun(@(e) sprintf('阵元%d', e), 0:7, 'uni', 0), 'Location', 'best');
        % 保存 PNG (rpt/), 命令行模式也能出图
        outDir = fullfile(fileparts(mfilename('fullpath')), '..', 'rpt');
        if ~exist(outDir, 'dir'), mkdir(outDir); end
        saveas(fig, fullfile(outDir, 'tx_bf_verify_spectrum.png'));
        fprintf('  频谱图已保存: %s\n', fullfile(outDir, 'tx_bf_verify_spectrum.png'));
    end
end
