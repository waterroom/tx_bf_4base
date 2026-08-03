% ANALYZE_DAC_8ELEM 验证全部 8 个 DAC 通道 (8 阵元)
%  读 sim_out/dac_out_8elem.log (每行: 8 阵元 I/Q, 已交织为 2.4GHz 序列)
%  验证内容:
%   1) 每阵元频谱: 4 波束峰应在 210/930/-850/-130 MHz
%   2) 8 阵元一致性: 本 TB 配置 (delay=0, weight=1) 下 8 阵元输出应逐样本相同
%   3) 幅度/噪声底统计
%
%  用法: analyze_dac_8elem  (PowerShell / MATLAB GUI / run_analyze.bat)
function analyze_dac_8elem()
    FID_NAME = 'sim_out/dac_out_8elem.log';
    fid = fopen(FID_NAME, 'r');
    if fid < 0
        error('找不到 %s (先跑 run_sim.tcl / run_all.bat 生成仿真输出)', FID_NAME);
    end
    fgetl(fid);                                   % 跳过标题
    raw = textscan(fid, repmat('%d ', 1, 16));    % 16 列: i0 q0 i1 q1 ... i7 q7
    fclose(fid);

    NE = 8;
    N  = numel(raw{1});
    I  = zeros(N, NE);  Q = zeros(N, NE);
    for e = 1:NE
        I(:,e) = raw{2*e-1};
        Q(:,e) = raw{2*e};
    end
    fprintf('样本数/阵元: %d (2.4GHz 域)\n', N);

    Fs  = 2.4e9;
    f   = ((0:N-1) - N/2) / N * Fs;
    f_exp = [210, 930, -850, -130] * 1e6;   % 4 波束预期峰 (LO+基带, 含混叠)
    win = hann(N);

    fprintf('\n=== 8 阵元频谱峰验证 (每阵元 4 波束) ===\n');
    peak_db = zeros(NE, 4);
    for e = 1:NE
        sig = complex(I(:,e), Q(:,e));
        sig = sig - mean(sig);
        S   = abs(fftshift(fft(sig .* win)));
        fprintf('阵元%d: ', e-1);
        for k = 1:4
            mask  = abs(f - f_exp(k)) < 50e6;
            f_m   = f(mask);  S_m = S(mask);
            [pk, idx] = max(S_m);
            peak_db(e,k) = 20*log10(pk/(N/2) + eps);
            fprintf('  峰%d %.1fMHz %5.1fdB', k, f_m(idx)/1e6, peak_db(e,k));
        end
        fprintf('\n');
    end

    fprintf('\n=== 8 阵元一致性 (本配置 delay=0/weight=1, 应逐样本相同) ===\n');
    ref = complex(I(:,1), Q(:,1));
    max_diff = zeros(NE-1, 1);
    for e = 2:NE
        c = complex(I(:,e), Q(:,e));
        max_diff(e-1) = max(abs(c - ref));
    end
    fprintf(' 阵元0 vs 1..7 最大逐样本差: %.3f %.3f %.3f %.3f %.3f %.3f %.3f\n', max_diff);
    fprintf(' (应≈0: 8 阵元复用同一 4 波束叠加, 无 TTD/加权时完全一致)\n');

    fprintf('\n=== 幅度统计 ===\n');
    fprintf(' 峰值 dB 范围: [%.1f, %.1f] (8 阵元 × 4 波束)\n', min(peak_db(:)), max(peak_db(:)));
    amp = max(abs(complex(I,Q)), [], 1);
    fprintf(' 时域峰值范围: [%.0f, %.0f] (LSD)\n', min(amp), max(amp));
    fprintf('\n=== 分析完成 ===\n');
end
