% VERIFY_MODEL_FIGS 用图形验证 tx_bf_duc_model 输出正确性
%   - 图1: DAC 输出频谱 (阵元0, 复数 I+jQ, 正确频轴), 标注 4 个波束预期峰
%   - 图2: DAC 时域 I/Q 波形 (4 波束叠加)
%   - 图3: 8 并行相位输出视图
%   - 打印: 每个波束实测峰频率 vs 预期 (LO+基带), 这才是正确性证据
%
% 用法: verify_model_figs  (在 MATLAB 或 -batch 下均可, 无桌面时自动保存 PNG)
% 输出: matlab/figs/model_spectrum.png / model_waveform.png / model_8p.png
function verify_model_figs()
    mdir = fileparts(mfilename('fullpath'));
    addpath(fullfile(mdir, 'utils'));
    figdir = fullfile(mdir, 'figs');
    if ~exist(figdir, 'dir'), mkdir(figdir); end

    N = 1024;                       % 基带样本数
    [dac, info] = tx_bf_duc_model(N);
    cfg = info.cfg;
    Fs  = info.Fs_high;             % 2.4 GHz
    L   = cfg.INTERP;               % 8
    Nh  = N * L;                    % 2.4 GHz 域点数 = 8192

    % ============ 图1: DAC 输出频谱 (阵元0) ============
    sig = dac.i(1,:) + 1j*dac.q(1,:);
    sig = sig - mean(sig);
    win = hann(Nh).';
    S   = fftshift(fft(sig .* win));
    f   = ((0:Nh-1) - Nh/2) / Nh * Fs;      % 正确频轴: DC 在中间
    mag = abs(S) / (Nh/2);

    % 预期峰: 每个波束在 LO+基带; >Fs/2 的混叠到负频率 (2.4GHz 复采样, 奈奎斯特 ±1.2GHz)
    f_exp   = cfg.f_LO + cfg.bb_freq;                       % [210 930 1550 2270] MHz
    f_plot  = mod(f_exp + Fs/2, Fs) - Fs/2;                 % 混叠后显示位置
    f_alias = f_exp;  f_alias(f_alias > Fs/2) = f_alias(f_alias > Fs/2) - Fs;

    h1 = figure('Visible','off','Position',[100 100 980 430]);
    plot(f/1e6, 20*log10(mag+eps), 'b', 'LineWidth', 0.8); hold on;
    col = lines(length(f_exp));
    for k = 1:length(f_exp)
        xline(f_plot(k)/1e6, '--', sprintf('beam%d %.0fMHz', k, f_alias(k)/1e6), ...
            'Color', col(k,:), 'LabelOrientation','horizontal', 'FontSize', 8);
    end
    grid on;
    xlabel('Frequency (MHz)'); ylabel('Magnitude (dB)');
    title(sprintf('DAC output spectrum, element 0 (Fs=2.4GHz, %d-pt FFT, Hann)', Nh));
    xlim([-1200 1200]); ylim([-120 10]);
    print(h1, fullfile(figdir,'model_spectrum.png'), '-dpng', '-r150');
    close(h1);

    % ============ 图2: 时域波形 (阵元0, 前 400 点) ============
    h2 = figure('Visible','off','Position',[100 100 980 430]);
    n = 1:400;
    plot(n, dac.i(1,n), 'b', n, dac.q(1,n), 'r', 'LineWidth', 0.7);
    grid on;
    legend('I','Q','Location','best');
    xlabel('Sample @ 2.4GHz'); ylabel('Amplitude');
    title('DAC time-domain I/Q, element 0 (4 beams summed, first 400 samples)');
    print(h2, fullfile(figdir,'model_waveform.png'), '-dpng', '-r150');
    close(h2);

    % ============ 图3: 8 并行相位输出 ============
    h3 = figure('Visible','off','Position',[100 100 980 430]);
    for p = 1:8
        subplot(2,4,p);
        plot(dac.i_8p(1,:,p), 'b', 'LineWidth', 0.6); grid on;
        title(sprintf('phase %d', p-1)); xlim([0 200]);
        if p == 1 || p == 5, ylabel('I'); end
    end
    sgtitle('8 parallel I outputs, element 0 (first 200 cycles)');
    print(h3, fullfile(figdir,'model_8p.png'), '-dpng', '-r150');
    close(h3);

    % ============ 数值证据: 逐波束实测峰 vs 预期 ============
    fprintf('=== 波束峰验证 (阵元0, 搜索窗口 ±50MHz) ===\n');
    for k = 1:length(f_exp)
        mask  = abs(f - f_alias(k)) < 50e6;
        [pk, idx] = max(mag(mask));
        fpk = f(mask);
        fpk = fpk(idx);
        fprintf('  beam%d: 预期 %7.1f MHz | 实测 %7.1f MHz | %.1f dB | 偏差 %.1f MHz\n', ...
            k, f_alias(k)/1e6, fpk/1e6, 20*log10(pk+eps), (fpk-f_alias(k))/1e6);
    end

    % 8 并行 vs 串行: 仅表示一致性 (同一份数据两种摆布, 不是正确性证明)
    dac_i_flat = reshape(permute(dac.i_8p,[1,3,2]), 8, []);
    err = max(abs(dac.i(:) - dac_i_flat(:)));
    fprintf('8-parallel reshape consistency err: %.3e (两种摆布一致, 正确性以频谱/波形图为准)\n', err);

    fprintf('\n=== 图已保存: %s ===\n', figdir);
end
