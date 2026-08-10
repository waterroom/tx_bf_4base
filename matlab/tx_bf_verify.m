% =============================================================================
% tx_bf_verify.m  --  验证 FPGA 仿真输出 vs 模型参考 (tx_bf_4base)
% =============================================================================
% 用法:
%   tx_bf_verify            % 全量验证 (GUI 下自动绘图)
%   tx_bf_verify(0)         % 仅文本报告 (batch 模式)
% 前置: 先跑 Vivado 仿真 tb_da_data_gen, 生成
%       sim_out/da_data_gen_dac.log (单通道 I/Q, 2 列)
%       (兼容旧格式 sim_out/dac_out_8elem.log, 16 列 8 阵元)
%
% 验证内容 (针对当前 TB 配置: 4 波束 LO 200/400/600/800MHz,
%   基带 10/30/50/70MHz, 权重 1.0, delay=0):
%   1) 频谱峰: 4 波束混频峰 (LO±基带) 频率/幅度
%   2) 幅度比对: FPGA 各波束峰相对幅度 vs 模型 (tx_bf_duc_model)
%      判据: 峰频率偏差 <1MHz; 相对幅度差 <3dB
%
% 判据 (全部通过 = PASS):
%   - 峰频率与预期偏差 < 1 MHz
%   - FPGA vs 模型峰相对幅度差 < 3 dB (消除全局标度差)
% =============================================================================

function tx_bf_verify(do_plot)
    if nargin < 1, do_plot = usejava('desktop'); end

    mdir = fileparts(mfilename('fullpath'));
    repoRoot = fileparts(mdir);

    % ---- 1. 读 FPGA 仿真输出 (自动检测格式) ----
    % 当前 TB: sim_out/da_data_gen_dac.log (2 列 I/Q, 单通道 2.4GHz 等效)
    % 旧 TB:   sim_out/dac_out_8elem.log   (16 列, 8 阵元 i/q 交织)
    logCur = fullfile(repoRoot, 'sim_out', 'da_data_gen_dac.log');
    logOld = fullfile(repoRoot, 'sim_out', 'dac_out_8elem.log');
    if exist(logCur, 'file')
        logFile = logCur; NE = 1;
        % textscan 容忍行不齐/截断 (只取完整 I/Q 行)
        fid = fopen(logFile, 'r');
        if fid < 0, error('无法打开 %s', logFile); end
        raw = textscan(fid, '%f %f', 'CollectOutput', true);
        fclose(fid);
        raw = raw{1};
        if isempty(raw), error('dump 无完整数据行: %s (仿真可能未跑完)', logFile); end
        fprintf('  注: 完整行 %d 条%s\n', size(raw,1), ...
            iif(size(raw,1) < 16000, ' (文件可能截断, 建议重跑完整仿真)', ''));
        I = raw(:,1); Q = raw(:,2);
    elseif exist(logOld, 'file')
        logFile = logOld; NE = 8;
        fid = fopen(logFile, 'r'); fgetl(fid);     % 跳过标题
        raw = textscan(fid, repmat('%d ', 1, 16));
        fclose(fid);
        N = numel(raw{1}); I = zeros(N, NE); Q = zeros(N, NE);
        for e = 1:NE
            I(:,e) = double(raw{2*e-1}); Q(:,e) = double(raw{2*e});
        end
    else
        error('找不到仿真输出: %s 或 %s\n请先跑 tb_da_data_gen 仿真', logCur, logOld);
    end
    N = numel(I(:,1));
    Fs = 2.4e9;                                    % 2.4 GHz (8 并行等效)
    f  = ((0:N-1) - N/2) / N * Fs;
    fprintf('=== tx_bf_4base FPGA 仿真验证 ===\n');
    fprintf('样本数/阵元: %d (2.4GHz 域), 文件: %s\n', N, logFile);

    % ---- 2. 频谱峰验证 (4 波束 LO + 基带) ----
    f_LO = [200, 400, 600, 800] * 1e6;             % 4 波束 LO (当前 TB 配置)
    f_bb = [10, 30, 50, 70] * 1e6;                 % 4 路基带
    f_exp = f_LO + f_bb;                           % 混频上边带 (LO+基带)
    f_exp(f_exp > Fs/2) = f_exp(f_exp > Fs/2) - Fs;% >1.2GHz 混叠

    win = hann(N);
    peak_db = zeros(NE, 4);  peak_f = zeros(NE, 4);
    fprintf('\n--- [1/3] 频谱峰 (LO+基带) ---\n');
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
        fprintf('  阵元%d: %s\n', e-1, ...
            sprintf(' %.0fMHz(%.1fdB)', reshape([peak_f(e,:)/1e6; peak_db(e,:)], 1, [])));
    end
    freq_err = max(abs(peak_f - repmat(f_exp, NE, 1)), [], 'all') / 1e6;
    fprintf('  峰频率最大偏差: %.2f MHz (判据 <1MHz)\n', freq_err);

    % ---- 3. 8 阵元一致性 (旧格式多阵元时; 单通道跳过) ----
    fprintf('\n--- [2/3] 8 阵元一致性 ---\n');
    if NE > 1
        ref = complex(I(:,1), Q(:,1));
        max_diff = zeros(NE-1, 1);
        for e = 2:NE
            max_diff(e-1) = max(abs(complex(I(:,e), Q(:,e)) - ref));
        end
        cons_err = max(max_diff);
        fprintf('  一致性最大差: %.3f (判据 <1)\n', cons_err);
    else
        cons_err = 0;
        fprintf('  (单通道 dump, 跳过一致性检查)\n');
    end

    % ---- 4. 模型对比: 频率 + 相对幅度 ----
    fprintf('\n--- [3/3] 模型对比 (tx_bf_duc_model 同配置) ---\n');
    cfg = make_default_cfg();
    cfg.int_d   = zeros(cfg.N_BEAM, cfg.N_ELEM);   % 与 TB 一致: 无 TTD
    cfg.frac_d  = zeros(cfg.N_BEAM, cfg.N_ELEM);
    cfg.weight  = ones(cfg.N_BEAM, cfg.N_ELEM);
    N_model     = min(2048, floor(N / 8));          % 模型基带样本数
    [dac, ~]    = tx_bf_duc_model(N_model, cfg);
    sig_m = dac.i(1, :) + 1j * dac.q(1, :);        % 阵元0
    sig_m = sig_m - mean(sig_m);
    Nm    = numel(sig_m);
    S_m   = abs(fftshift(fft(sig_m .* hann(Nm).')));
    f_m   = ((0:Nm-1) - Nm/2) / Nm * Fs;
    model_db = zeros(1, 4);  model_f = zeros(1, 4);
    for k = 1:4
        mask  = abs(f_m - f_exp(k)) < 50e6;
        f_mm  = f_m(mask);  S_mm = S_m(mask);
        [pk, idx] = max(S_mm);
        model_f(k)  = f_mm(idx);
        model_db(k) = 20*log10(pk/(Nm/2) + eps);
    end
    model_err = max(abs(model_f - f_exp), [], 'all') / 1e6;
    fprintf('  模型峰频率偏差: %.2f MHz\n', model_err);
    fpga_vs_model_f = max(abs(peak_f(1,:) - model_f), [], 'all') / 1e6;
    fprintf('  FPGA vs 模型峰频率差: %.2f MHz (判据 <1MHz)\n', fpga_vs_model_f);

    % 幅度比对: 相对幅度 (各波束峰相对自身最大峰, 消除全局标度差)
    fprintf('  相对幅度 (dB, 相对最大峰):\n');
    rel_fpga = peak_db(1,:) - max(peak_db(1,:));
    rel_mod  = model_db   - max(model_db);
    amp_diff = abs(rel_fpga - rel_mod);
    for k = 1:4
        fprintf('    波束%d: FPGA %+.1f / 模型 %+.1f / 差 %.1f dB %s\n', k, ...
            rel_fpga(k), rel_mod(k), amp_diff(k), ...
            iif(amp_diff(k) < 3, 'OK', '⚠️ 超差'));
    end
    amp_err = max(amp_diff);
    fprintf('  峰相对幅度最大差: %.2f dB (判据 <3dB)\n', amp_err);

    % ---- 5. 汇总 PASS/FAIL ----
    fprintf('\n=== 验证结论 ===\n');
    pass = (freq_err < 1) && (cons_err < 1) && (fpga_vs_model_f < 1) && (amp_err < 3);
    if pass
        fprintf('  PASS ✅  4 波束峰频率精确 + 相对幅度与模型一致\n');
    else
        fprintf('  FAIL ❌  见上方超标项\n');
    end

    % ---- 6. 频谱图 (可选) ----
    if do_plot
        fig = figure('Name', 'tx_bf_verify: FPGA DAC 频谱', 'Position', [100 100 960 420]);
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
        title(sprintf('FPGA DAC 频谱 (4 波束 LO %d/%d/%d/%d MHz)', ...
            f_LO(1)/1e6, f_LO(2)/1e6, f_LO(3)/1e6, f_LO(4)/1e6));
        xlim([0 1200]); ylim([-120 10]);
        outDir = fullfile(repoRoot, 'rpt');
        if ~exist(outDir, 'dir'), mkdir(outDir); end
        saveas(fig, fullfile(outDir, 'tx_bf_verify_spectrum.png'));
        fprintf('  频谱图已保存: %s\n', fullfile(outDir, 'tx_bf_verify_spectrum.png'));
    end
end

% 三元辅助 (MATLAB R2016a- 兼容)
function r = iif(c, a, b)
    if c, r = a; else, r = b; end
end
