% DESIGN_INTERP_FIR 设计/对比 8 倍内插 FIR (88MHz 通带, 2.4G 输出域)
%   验证不同抽头数 (32/40/48) 的通带纹波与阻带抑制, 决定最小抽头数
%   规格: 通带 [0,88MHz], 阻带 [212MHz, 1.2GHz] (212=300-88, 最近镜像)
%   用法: design_interp_fir   (输出频响对比图 + 表格)
function design_interp_fir()
    fs_out = 2.4e9;                 % 输出采样率
    f_p = 88e6;                     % 通带
    f_s = 300e6 - 88e6;             % 阻带起点 (镜像 300MHz 的带边)
    fn  = fs_out / 2;               % Nyquist 1.2GHz

    % 归一化频率 (firpm: Nyquist=1)
    F = [0 f_p f_s fn] / fn;
    A = [1 1 0 0];
    W = [1 10];                     % 阻带加权 10 (-> ~60dB)

    fprintf('=== 8 倍内插 FIR 设计对比 (通带 %.0fMHz, 阻带 %.0fMHz 起) ===\n', f_p/1e6, f_s/1e6);
    fprintf('%-6s %-12s %-12s %-12s\n', 'N', '通带纹波dB', '阻带抑止dB@300M', '阻带最差dB');
    for N = [32 40 48]
        h = firpm(N-1, F, A, W);
        h = h / sum(h);             % DC 增益 1
        [H, w] = freqz(h, 1, 8192, fs_out);
        magdB = 20*log10(abs(H) + eps);

        % 通带纹波 (0-f_p)
        pass = magdB(w <= f_p);
        ripple = max(pass) - min(pass);
        % 阻带最差 (f_s 到 Nyquist)
        stop = magdB(w >= f_s);
        stop_worst = max(stop);
        % 镜像中心 300MHz 处抑制
        [~, i3] = min(abs(w - 300e6));
        stop_300 = magdB(i3);

        fprintf('%-6d %-12.3f %-12.1f %-12.1f\n', N, ripple, stop_300, stop_worst);

        % 保存最佳设计 (N=40 优先) 到 rtl 头文件格式备查
        if N == 40
            B40 = round(h * 32768);
            fprintf('  N=40 系数 (int16): [%s]\n', num2str(B40));
        end
    end

    % 频响图
    figure('Visible','off','Position',[100 100 900 420]);
    hold on;
    for N = [32 40 48]
        h = firpm(N-1, F, A, W); h = h/sum(h);
        [H, w] = freqz(h, 1, 8192, fs_out);
        plot(w/1e6, 20*log10(abs(H)+eps), 'LineWidth', 1);
    end
    xline(88, 'r--'); xline(212, 'r--', '镜像'); xline(300, 'k--');
    grid on;
    xlabel('频率 (MHz)'); ylabel('幅度 (dB)');
    title('8 倍内插 FIR 频响对比 (88MHz 通带)');
    legend('32 tap','40 tap','48 tap','Location','best');
    ylim([-120 10]);
    print(gcf, fullfile(fileparts(mfilename('fullpath')), '..', 'rpt', 'interp_fir_compare.png'), '-dpng', '-r120');
    fprintf('\n频响图: rpt/interp_fir_compare.png\n');
end
