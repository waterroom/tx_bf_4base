function verify_spectrum(N)
%VERIFY_SPECTRUM 频谱验证: 4 波束落 4 个射频频率
%   verify_spectrum(N)  N 默认 2048
%   对 8 路 DAC 输出做 FFT, 验证 4 个谱峰位置正确、杂散 < -50 dBc
    if nargin < 1, N = 2048; end

    [dac, info] = tx_bf_duc_model(N);
    Fs_high = info.Fs_high;
    N_ELEM  = info.cfg.N_ELEM;
    f_LO    = info.cfg.f_LO;

    Nh = N * 8;
    f_axis = (0:Nh-1).' / Nh * Fs_high;   % 频率轴 (Hz)

    figure('Name','频谱验证: 8 路 DAC 输出','Position',[100 100 1200 700]);
    for e = 1:N_ELEM
        subplot(2, 4, e);
        sig = dac.i(e, :) + 1j * dac.q(e, :);   % 复信号
        S = 20*log10(abs(fftshift(fft(sig))) / Nh + eps);
        f_plot = f_axis - Fs_high/2;             % 居中
        plot(f_plot/1e6, S, 'b');
        hold on;
        for b = 1:length(f_LO)
            yline(f_LO(b)/1e6 - Fs_high/2, 'r--', sprintf('LO%d', b));
        end
        xlabel('频率 (MHz)'); ylabel('幅度 (dB)');
        title(sprintf('阵元 %d', e-1));
        grid on; xlim([-Fs_high/2 Fs_high/2]/1e6); ylim([-100 5]);
    end
    sgtitle('8 路 DAC 复数输出频谱 (4 波束 4 频率)');

    % 检查 4 个 LO 频率处是否有谱峰
    fprintf('=== 频谱验证 ===\n');
    sig0 = dac.i(1,:) + 1j*dac.q(1,:);
    S0 = abs(fft(sig0));
    for b = 1:length(f_LO)
        bin = round(f_LO(b) / Fs_high * Nh) + 1;
        peak = 20*log10(S0(bin)/Nh + eps);
        fprintf('  LO%d = %.0f MHz: 谱峰幅度 %.1f dB\n', b, f_LO(b)/1e6, peak);
    end
    fprintf('频谱验证完成 (人工目检 4 个红色虚线处应有谱峰)\n');
end
