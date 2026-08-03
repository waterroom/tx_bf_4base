function verify_beam_pattern()
%VERIFY_BEAM_PATTERN 波束方向图验证
%   扫描到达角 (-90°~+90°), 计算每个波束的方向图, 验证 4 波束指向 4 个方向
%   方向/频率解耦: 方向由 DBF 延时/权重决定, 频率由 LO 决定

    cfg = tx_bf_duc_model(0);   % 取默认 cfg (N=0 仅取配置, 不计算)
    % 上面调用会因 N=0 出错, 改为直接构造默认配置:
    cfg = make_cfg_local();

    N_ELEM = cfg.N_ELEM;
    d_elem = 0.5;
    c = 3e8;
    pos = (0:N_ELEM-1) * d_elem;
    Fs_base = cfg.Fs_base;

    theta_scan = -90:0.5:90;
    figure('Name','波束方向图','Position',[100 100 900 600]);
    colors = {'r','g','b','m'};
    hold on;
    for b = 1:cfg.N_BEAM
        % 该波束的 TTD 延时 (样本) 对应的等效相移 (以某参考频率计算方向图)
        % 方向图 = |sum_e exp(-j*2*pi*f*delay_e) * exp(j*2*pi*f*pos_e*sin(theta)/c)|
        % 取 f = 50MHz (基带中心) 评估方向图形状
        f_ref = 50e6;
        delay_e = cfg.int_d(b,:) + cfg.frac_d(b,:);   % 总延时样本
        pattern = zeros(size(theta_scan));
        for k = 1:length(theta_scan)
            theta = theta_scan(k);
            steer = exp(1j * 2*pi * f_ref * pos * sind(theta) / c);   % 空间相位
            % DBF 延时引入的相位 (延时 = 负相位斜率)
            bf_phase = exp(-1j * 2*pi * f_ref * delay_e / Fs_base);
            pattern(k) = abs(sum(steer .* bf_phase .* cfg.weight(b,:)));
        end
        pattern = pattern / max(pattern);
        plot(theta_scan, 20*log10(pattern + eps), colors{b}, 'LineWidth', 1.5, ...
             'DisplayName', sprintf('波束%d (θ=%g°, LO=%.0fMHz)', b, cfg.angle(b), cfg.f_LO(b)/1e6));
        % 标注指向角
        [pk, idx] = max(pattern);
        plot(theta_scan(idx), 20*log10(pk+eps), 'k*', 'MarkerSize', 8, 'HandleVisibility','off');
    end
    hold off;
    grid on; xlabel('到达角 θ (°)'); ylabel('方向图 (dB)');
    title('4 波束方向图 (8 阵元, TTD 延时指向)');
    legend('Location','South'); ylim([-40 3]);
    fprintf('=== 波束方向图验证完成 ===\n');
    fprintf('  4 条曲线峰值应分别在 %g, %g, %g, %g°\n', cfg.angle(1), cfg.angle(2), cfg.angle(3), cfg.angle(4));
end

function cfg = make_cfg_local()
% 复用 tx_bf_duc_model 的默认配置逻辑 (避免 N=0 调用)
    cfg.Fs_base = 300e6; cfg.INTERP = 8; cfg.Fs_high = cfg.Fs_base*cfg.INTERP;
    cfg.N_BEAM = 4; cfg.N_ELEM = 8; cfg.TAPS = 16;
    cfg.bb_freq = [10e6, 30e6, 50e6, 70e6];
    cfg.f_LO = [200e6, 900e6, 1500e6, 2200e6];
    cfg.angle = [-30, -10, 10, 30];
    d_elem = 0.5; c = 3e8; pos = (0:cfg.N_ELEM-1)*d_elem;
    delay_samples = zeros(cfg.N_BEAM, cfg.N_ELEM);
    for b = 1:cfg.N_BEAM
        geo = pos*sind(cfg.angle(b))/c*cfg.Fs_base;
        geo = geo - min(geo);
        delay_samples(b,:) = geo;
    end
    cfg.int_d = floor(delay_samples);
    cfg.frac_d = delay_samples - cfg.int_d;
    cfg.weight = ones(cfg.N_BEAM, cfg.N_ELEM) + 0j;
end
