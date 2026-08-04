% VERIFY_USER_HB 验证用户 FDATool 设计的 3 级半带系数 (级联频响)
%   读 rtl/fdacoefs_hffir_*.h, 逐级 freqz + 级联总频响
%   检查: 半带结构/对称性/增益/通带纹波/阻带(镜像)抑制
function verify_user_hb()
    rtl = fullfile('..','rtl');
    files = {'fdacoefs_hffir_300Mto600M_87p5Mpass.h', ...
             'fdacoefs_hffir_600Mto1200M_87p5Mpass.h', ...
             'fdacoefs_hffir_1200Mto2400M_87p5Mpass.h'};
    fs_in = [300e6 600e6 1200e6];       % 各级输入率
    f_p = 88e6;                         % 目标通带

    h = cell(1,3);
    for s = 1:3
        txt = fileread(fullfile(rtl, files{s}));
        tok = regexp(txt, 'B\[(\d+)\]\s*=\s*\{([^}]*)\}', 'tokens', 'once');
        N = str2double(tok{1});
        nums = regexp(tok{2}, '-?\d+', 'match');   % 提取所有整数 (免疫异常字符)
        c = str2double(nums); c = c(:).';
        h{s} = c / 32768;               % 归一化 (中心 16384 = 0.5)
        fout = fs_in(s)*2;
        % 结构检查
        even_ok = all(h{s}(2:2:end-1) == 0);        % 奇索引(除中心)为0? 中心索引=N/2
        sym_err = max(abs(c - fliplr(c)));
        dc = sum(c);
        fprintf('级%d (%d->%dMHz): N=%d 非零=%d 对称err=%d 增益=%.4f\n', ...
            s, fs_in(s)/1e6, fout/1e6, N, sum(c~=0), sym_err, dc/32768);
        % 频响
        [H, w] = freqz(h{s}, 1, 16384, fout);
        magdB = 20*log10(abs(H)+eps);
        f_s = fs_in(s) - f_p;                       % 阻带起 (镜像下边)
        stop = max(magdB(w >= f_s));
        ripple = max(magdB(w <= f_p)) - min(magdB(w <= f_p));
        fprintf('   通带纹波=%.3fdB 阻带(%.0fM起)=%.1fdB\n', ripple, f_s/1e6, stop);
    end

    % ---- 级联总频响 (2.4G 输出域) ----
    % 3 级级联: 级1(600M) -> 级2(1200M) -> 级3(2400M)
    % 用多相级联仿真: 输入 1 样本/拍(300M), 逐级 2 倍插值, 8 拍输出 8 样本
    N = 4096;                               % 输入样本
    x = zeros(1, N); x(1) = 1;              % 冲激
    y = x;
    for s = 1:3
        y = upsample(y, 2);                 % 零填充 2 倍
        y = filter(h{s}, 1, y);             % 半带滤波
    end
    Fs_out = 2.4e9;
    [H, w] = freqz(y, 1, 32768, Fs_out);
    magdB = 20*log10(abs(H)+eps);
    f_p = 88e6; f_s1 = 212e6;               % 最近镜像 300M 下边
    ripple = max(magdB(w<=f_p)) - min(magdB(w<=f_p));
    stop1  = max(magdB(w>=f_s1 & w<=388e6));
    stop_all = max(magdB(w>=f_s1));
    fprintf('\n=== 级联总频响 (2.4GHz 域) ===\n');
    fprintf('通带纹波(0-88M): %.3f dB\n', ripple);
    fprintf('镜像抑制 212-388M(最近): %.1f dB\n', stop1);
    fprintf('阻带全部(212M-Nyquist): %.1f dB\n', stop_all);

    % 保存级联频响图
    figure('Visible','off','Position',[100 100 900 420]);
    plot(w/1e6, magdB, 'LineWidth', 1);
    xline(88,'r--'); xline(212,'r--'); xline(300,'k--'); xline(600,'k--'); xline(1200,'k--');
    grid on; xlabel('MHz'); ylabel('dB'); ylim([-120 10]);
    title('用户 3 级半带级联总频响 (2.4GHz 域)');
    print(gcf, fullfile('..','rpt','user_hb_cascade.png'), '-dpng', '-r120');
    fprintf('图: rpt/user_hb_cascade.png\n');
end
