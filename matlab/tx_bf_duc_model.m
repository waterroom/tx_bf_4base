function [dac, info] = tx_bf_duc_model(N, cfg)
%TX_BF_DUC_MODEL 宽带 TX DBF + DUC 全链路浮点参考模型
%   [dac, info] = tx_bf_duc_model(N, cfg)
%   单 FPGA 视角: 4 波束 × 8 阵元 → 8 路复数 DAC (2.4 Gs/s)
%
%   数据流:
%     BB1..4 (300MHz 复 IQ)
%       → 每波束 8 通道 TTD (整数延时 + 16 抽头分数延时 FIR + 复数加权)
%       → 8 倍内插 (48 抽头 FIR, upfirdn)
%       → 复数上变频 (DDS cos+j·sin × IQ, 保留 I+jQ)
%       → 8 阵元各求 4 波束之和
%       → 8 路复数 DAC 输出 (2.4 Gs/s, 8 并行 @300MHz)
%
%   输入:
%     N   - 基带样本数 (300MHz 域)
%     cfg - 配置结构体 (为空时用默认测试配置, 见 make_default_cfg)
%   输出:
%     dac.i      - 8 × (N*8) 实数矩阵, 8 阵元 I 分量 @2.4GHz
%     dac.q      - 8 × (N*8) 实数矩阵, 8 阵元 Q 分量 @2.4GHz
%     dac.i_8p   - 8 × N × 8 三维数组, [阵元, 时钟拍, 并行采样] (300MHz 域 8 并行)
%     dac.q_8p   - 同上 Q 分量
%     info       - 中间信号与配置 (调试用)

    %% ---------- 默认配置 ----------
    if nargin < 2 || isempty(cfg)
        cfg = make_default_cfg();
    end
    Fs_base = cfg.Fs_base;          % 300 MHz
    INTERP  = cfg.INTERP;           % 8
    Fs_high = Fs_base * INTERP;     % 2.4 GHz
    N_BEAM  = cfg.N_BEAM;           % 4
    N_ELEM  = cfg.N_ELEM;           % 8 (单 FPGA)
    TAPS    = cfg.TAPS;             % 16 (分数延时 FIR 抽头)
    Nh      = N * INTERP;           % 2.4GHz 域样本数

    %% ---------- 1. 生成 4 路基带复 IQ (300MHz) ----------
    %   每路一个不同频率的单音, 验证 4 波束 4 频率
    t_base = (0:N-1).' / Fs_base;
    bb = complex(zeros(N, N_BEAM), zeros(N, N_BEAM));
    for b = 1:N_BEAM
        bb(:, b) = exp(1j * 2*pi * cfg.bb_freq(b) * t_base);
    end

    %% ---------- 2. 8 倍内插滤波器系数 (48 抽头) ----------
    h_interp = cfg.h_interp;        % 1×48, 来自 fdacoefs_fir_300Mto2400M_88Mpass

    %% ---------- 3. 逐波束: DBF → 内插 → 复数上变频 → 累加到阵元 ----------
    dac_i = zeros(N_ELEM, Nh);      % 8 阵元 I 累加 (2.4GHz 域)
    dac_q = zeros(N_ELEM, Nh);      % 8 阵元 Q 累加
    for b = 1:N_BEAM
        % --- 3a. 8 通道 DBF: TTD (整数+分数延时) + 复数加权 ---
        bf_iq = zeros(N_ELEM, N);  % 8 阵元复 IQ (300MHz)
        for e = 1:N_ELEM
            y_i = ttd_delay(real(bb(:,b)), cfg.int_d(b,e), cfg.frac_d(b,e), TAPS);
            y_q = ttd_delay(imag(bb(:,b)), cfg.int_d(b,e), cfg.frac_d(b,e), TAPS);
            bf_iq(e, :) = (complex(y_i, y_q) * cfg.weight(b,e)).';
        end

        % --- 3b. 8 倍内插 (I/Q 分别内插, 等价复数内插) ---
        up_iq = zeros(N_ELEM, Nh);
        for e = 1:N_ELEM
            up_i = upfirdn(real(bf_iq(e,:)).', h_interp, INTERP);
            up_q = upfirdn(imag(bf_iq(e,:)).', h_interp, INTERP);
            up_iq(e, :) = complex(up_i(1:Nh).', up_q(1:Nh).');
        end

        % --- 3c. 复数上变频 (DDS cos+j·sin) 并累加到阵元 ---
        t_high = (0:Nh-1).' / Fs_high;
        lo = exp(1j * 2*pi * cfg.f_LO(b) * t_high);   % 复本振
        for e = 1:N_ELEM
            rf = up_iq(e, :).' .* lo;                  % 复数混频, 保留 I+jQ
            dac_i(e, :) = dac_i(e, :) + real(rf).';
            dac_q(e, :) = dac_q(e, :) + imag(rf).';
        end
    end

    %% ---------- 4. 整理输出 ----------
    dac.i = dac_i;              % 8 × N*8 @2.4GHz
    dac.q = dac_q;
    % 8 并行重塑: [阵元, 时钟拍, 并行采样]
    %   dac_i(e, :) 是 2.4GHz 序列, 重排为 (INTERP, N) 后转置得 (N, INTERP),
    %   再加阵元维 → (N_ELEM, N, INTERP)
    dac.i_8p = zeros(N_ELEM, N, INTERP);
    dac.q_8p = zeros(N_ELEM, N, INTERP);
    for e = 1:N_ELEM
        dac.i_8p(e, :, :) = reshape(dac_i(e, :).', INTERP, N).';
        dac.q_8p(e, :, :) = reshape(dac_q(e, :).', INTERP, N).';
    end

    info.bb = bb;
    info.cfg = cfg;
    info.Fs_base = Fs_base;
    info.Fs_high = Fs_high;
end

