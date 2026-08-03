function cfg = make_default_cfg()
%MAKE_DEFAULT_CFG 默认测试配置: 4 波束 4 频率, 8 阵元
%   model (tx_bf_duc_model) 与验证 (tx_bf_verify) 共用
%   覆盖字段可自定义: 如 cfg.int_d = zeros(...) 关闭 TTD 延时
    cfg.Fs_base = 300e6;       % 基带采样率 300 MHz
    cfg.INTERP  = 8;           % 8 倍内插
    cfg.Fs_high = cfg.Fs_base * cfg.INTERP;   % 2.4 GHz
    cfg.N_BEAM  = 4;           % 波束数
    cfg.N_ELEM  = 8;           % 单 FPGA 阵元数
    cfg.TAPS    = 16;          % 分数延时 FIR 抽头数

    % 4 路基带单音频率 (88MHz 通带内), 与 tb_tx_top.sv 一致
    cfg.bb_freq = [10e6, 30e6, 50e6, 70e6];

    % 4 个波束 LO 频率 (与 TB phase_inc 配置一致)
    cfg.f_LO = [200e6, 900e6, 1500e6, 2200e6];

    % 4 波束指向角 (度), 用于计算 TTD 延时
    cfg.angle = [-30, -10, 10, 30];

    % 阵元间距 (波长), 半波长量级
    d_elem = 0.5;
    c = 3e8;
    pos = (0:cfg.N_ELEM-1) * d_elem;   % 阵元位置

    % 计算每波束每阵元的几何延时 (样本数 @300MHz), 平移使最小为 0
    delay_samples = zeros(cfg.N_BEAM, cfg.N_ELEM);
    for b = 1:cfg.N_BEAM
        geo = pos * sind(cfg.angle(b)) / c * cfg.Fs_base;   % 样本
        geo = geo - min(geo);            % 保证非负
        delay_samples(b, :) = geo;
    end
    cfg.int_d  = floor(delay_samples);
    cfg.frac_d = delay_samples - cfg.int_d;

    % 复数权重 (幅度锥削 + 相位), 默认幅度 1、相位 0
    cfg.weight = ones(cfg.N_BEAM, cfg.N_ELEM) + 0j;

    % 8 倍内插 FIR 系数 (48 抽头, 来自 fdacoefs_fir_300Mto2400M_88Mpass.h)
    cfg.h_interp = load_interp_coeffs();
end
