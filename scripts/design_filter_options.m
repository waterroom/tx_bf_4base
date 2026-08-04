% DESIGN_FILTER_OPTIONS 内插滤波器多方案设计探索: 资源 vs 性能
%   8 倍内插 300MHz->2.4GHz, 通带 88MHz, 8 通道 x I/Q x 4 波束 = 8 个 FIR 实例
%   输出: 各方案 DSP/延迟/阻带对比表 (写入 rpt/filter_options.txt)
%   用法: design_filter_options
function design_filter_options()
    fs_in = 300e6;  f_p = 88e6;
    NCH_INST = 8;                  % 8 通道/实例
    N_INST   = 8;                  % 4 波束 x I/Q

    rpt = fopen(fullfile('..','rpt','filter_options.txt'),'w');
    pr = @(fmt,varargin) fprintf(rpt, fmt, varargin{:});

    fprintf('=== 内插滤波器方案探索 (通带 %.0fMHz, 8倍插值) ===\n', f_p/1e6);
    pr('=== 内插滤波器方案探索 (通带 %.0fMHz, 8倍插值) ===\n', f_p/1e6);
    fprintf('%-4s %-8s %-14s %-14s %-10s %-10s %-10s\n','#','方案','内插DSP','总DSP','阻带dB','延迟','备注');
    pr('%-4s %-8s %-14s %-14s %-10s %-10s %-10s\n','#','方案','内插DSP','总DSP','阻带dB','延迟','备注');

    % ============ 半带设计工具 (2倍插值, 输出域 Nyquist=fs_in) ============
    hb = @(N, f_p, fsin) firhalfband(N, f_p/fsin);   % N 偶数阶, 抽头 N+1

    % ============ 方案 A: 现状 48 抽头单级 8 并行 ============
    dspA = 8*8*6*N_INST;   % 8ch x 8ph x 6tap
    fprintf('%-4d %-8s %-14d %-14d %-10s %-10s %-10s\n',1,'48tap单级', dspA, dspA+1376, '-55','7拍','现状');
    pr('%-4d %-8s %-14d %-14d %-10s %-10s %-10s\n',1,'48tap单级', dspA, dspA+1376, '-55','7拍','现状');

    % ============ 方案 B: 3 级半带 (300->600->1200->2400) ============
    fprintf('\n--- 3 级半带各级设计 ---\n');
    pr('\n--- 3 级半带各级设计 ---\n');
    NB = [14 10 6];   % 各级阶数 (firhalfband 要求偶数, 抽头数=N+1)
    optB = cell(1,3);
    for s = 1:3
        fsin = fs_in * 2^(s-1);                    % 该级输入率
        fout = fsin * 2;
        f_s  = fsin - f_p;                         % 镜像下边 (输出域)
        best = []; best_stop = -inf;
        for N = NB(s):2:NB(s)+4
            h = hb(N, f_p, fout/2);                % 归一化 Nyquist=fout/2? firhalfband w 相对 fs=2
            % firhalfband(n,w): w 相对 Nyquist=1 (fs=2). 这里通带边 f_p/(fout/2)
            h = hb(N, f_p, fout/2);
            [H,w] = freqz(h,1,8192,fout);
            st = max(20*log10(abs(H(w>=f_s))+eps));
            if st > best_stop, best_stop = st; best = h; end
        end
        Nused = length(best);
        nz = sum(best~=0);                         % 非零系数
        optB{s} = struct('N',Nused,'nz',nz,'stop',best_stop,'fsin',fsin,'fout',fout);
        fprintf('  级%d (%d->%dMHz): N=%d 非零=%d 阻带=%.1fdB\n', s, fsin/1e6, fout/1e6, Nused, nz, best_stop);
        pr('  级%d (%d->%dMHz): N=%d 非零=%d 阻带=%.1fdB\n', s, fsin/1e6, fout/1e6, Nused, nz, best_stop);
    end
    % DSP: 级 s 输入并行度 2^(s-1) 样本/拍/通道, 每输出样本非零/2 (2倍插值 2相位均分)
    dspB = 0;
    for s = 1:3
        par = 2^(s-1);                              % 输入并行度
        dspB = dspB + par * ceil(optB{s}.nz/2);     % 每拍乘法
    end
    dspB = dspB * NCH_INST * N_INST;
    stopB = min(cellfun(@(x) x.stop, optB));
    fprintf('%-4d %-8s %-14d %-14d %-10.1f %-10s %-10s\n',2,'3级半带', dspB, dspB+1376, stopB, '~11拍','系数半零');
    pr('%-4d %-8s %-14d %-14d %-10.1f %-10s %-10s\n',2,'3级半带', dspB, dspB+1376, stopB, '~11拍','系数半零');

    % ============ 方案 C: 2 级混合 (4倍通用 + 2倍半带) ============
    fprintf('\n--- 方案 C: 4倍(24tap) + 2倍半带 ---\n');
    pr('\n--- 方案 C: 4倍(24tap) + 2倍半带 ---\n');
    % 级1: 4倍插值 300->1200, 24 抽头, 多相 4 相位 x 6 抽头
    f_s1 = fs_in - f_p;                             % 镜像 300
    h1 = firpm(23, [0 f_p f_s1 600e6]/(600e6), [1 1 0 0], [1 10]);
    [H1,w1] = freqz(h1,1,8192,1200e6);
    stop1 = max(20*log10(abs(H1(w1>=f_s1))+eps));
    % 级2: 2倍半带 1200->2400
    h2 = hb(6, f_p, 1200e6);
    [H2,w2] = freqz(h2,1,8192,2400e6);
    stop2 = max(20*log10(abs(H2(w2>=1200e6-f_p))+eps));
    % 级1: 4phx6tap=24 MAC/通道/拍; 级2: 输入并行4 x 非零系数 nz MAC/通道/拍
    dspC = (4*6 + 4*sum(h2~=0)) * NCH_INST * N_INST;
    fprintf('  级1 4倍24tap 阻带=%.1fdB | 级2 半带 阻带=%.1fdB | DSP=%d\n', stop1, stop2, dspC);
    pr('  级1 4倍24tap 阻带=%.1fdB | 级2 半带 阻带=%.1fdB | DSP=%d\n', stop1, stop2, dspC);
    fprintf('%-4d %-8s %-14d %-14d %-10.1f %-10s %-10s\n',3,'4倍+2倍半带', dspC, dspC+1376, min(stop1,stop2), '~9拍','');
    pr('%-4d %-8s %-14d %-14d %-10.1f %-10s %-10s\n',3,'4倍+2倍半带', dspC, dspC+1376, min(stop1,stop2), '~9拍','');

    % ============ 方案 D: 48 抽头时分复用 (分 2/3/6 拍) ============
    fprintf('\n--- 方案 D: 48 抽头 MAC 时分 (抽头分拍算) ---\n');
    pr('\n--- 方案 D: 48 抽头 MAC 时分 (抽头分拍算) ---\n');
    for k = [2 3 6]
        dspD = 8*8*ceil(6/k) * N_INST;             % 每拍抽头数 = ceil(6/k)
        fprintf('%-4d %-8s %-14d %-14d %-10s %-10s %-10s\n',4+(k==2), ...
            sprintf('48tap时%d拍',k), dspD, dspD+1376, '-55', sprintf('%d拍',7+k), '流水换DSP');
        pr('%-4d %-8s %-14d %-14d %-10s %-10s %-10s\n',4+(k==2), ...
            sprintf('48tap时%d拍',k), dspD, dspD+1376, '-55', sprintf('%d拍',7+k), '流水换DSP');
    end

    % ============ 方案 E: 40 抽头 (阻带妥协) ============
    dspE = 8*8*5*N_INST;
    fprintf('%-4d %-8s %-14d %-14d %-10s %-10s %-10s\n',7,'40tap单级', dspE, dspE+1376, '-48','7拍','阻带妥协');
    pr('%-4d %-8s %-14d %-14d %-10s %-10s %-10s\n',7,'40tap单级', dspE, dspE+1376, '-48','7拍','阻带妥协');

    fclose(rpt);
    fprintf('\n汇总表: rpt/filter_options.txt\n');
end
