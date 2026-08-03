// =============================================================================
// tx_bf_pkg.sv  --  宽带 TX DBF + DUC 公共参数与类型包
// =============================================================================
// 全局参数定义, 供新写模块 (cmult_8p / add_tree_4 / beam_duc / sum_4to1 /
// cfg_bus / tx_top 等) 引用。参考仓库复用的 4 个模块 (int_delay /
// frac_delay_fir / cmult_3dsp / tx_bf_core) 自带参数, 不依赖本包。
//
// 数据总线约定: 8 并行采样用 unpacked 数组 typedef, 便于可读性与波形调试。
// =============================================================================

`ifndef TX_BF_PKG_SV
`define TX_BF_PKG_SV

package tx_bf_pkg;

    // ---------- 系统规模 ----------
    localparam int N_BEAM       = 4;     // 波束数
    localparam int N_ELEM       = 8;     // 单 FPGA 阵元数 (两片共 16)
    localparam int N_ELEM_TOTAL = 16;    // 全系统阵元数

    // ---------- 采样率与时钟 ----------
    localparam int INTERP       = 8;     // 8 倍内插 (300MHz → 2.4GHz 等效)

    // ---------- 位宽 ----------
    localparam int DATA_W       = 16;    // 基带 IQ 位宽 (有符号)
    localparam int FIR_OUT_W    = 18;    // DBF / 内插 FIR 输出位宽
    localparam int DDS_PHASE_W  = 32;    // DDS 相位累加位宽 (Hz 级分辨率: 2.4G/2^32≈0.56Hz)
    localparam int DDS_OUT_W    = 16;    // DDS sin/cos 输出位宽
    localparam int MIXER_OUT_W  = 18;    // 复数混频输出位宽 (截位 18+16→18)
    localparam int SUM_OUT_W    = 20;    // 4 路求和输出位宽 (18 + log2(4)=2)
    localparam int DAC_W        = 16;    // DAC 数据位宽 (PL 通路; RF-DAC 原生 14bit 截位)

    // ---------- TTD 参数 (与参考仓库一致) ----------
    localparam int TAPS         = 16;    // 分数延时 FIR 抽头数
    localparam int COEF_W       = 16;    // FIR 系数 / 复数权重位宽
    localparam int MAX_DELAY    = 64;    // 整数延时最大深度

    // ---------- 标量类型 ----------
    typedef logic signed [DATA_W-1:0]       iq_t;        // 基带 IQ 一路
    typedef logic signed [FIR_OUT_W-1:0]    iq_fir_t;    // DBF/内插后 IQ
    typedef logic signed [DDS_OUT_W-1:0]    nco_t;       // DDS sin/cos
    typedef logic signed [MIXER_OUT_W-1:0]  mix_t;       // 混频输出
    typedef logic signed [SUM_OUT_W-1:0]    sum_t;       // 求和输出
    typedef logic signed [DAC_W-1:0]        dac_t;       // DAC 输出

    // ---------- 8 并行采样类型 (unpacked 数组) ----------
    // 用于 2.4GHz 等效域: 每拍 8 个时序对齐的并行采样
    typedef iq_fir_t   iq_fir_8p_t [INTERP-1:0];   // 内插后 8 并行 IQ
    typedef nco_t      nco_8p_t    [INTERP-1:0];   // DDS 8 并行 cos/sin
    typedef mix_t      mix_8p_t   [INTERP-1:0];   // 混频后 8 并行
    typedef sum_t      sum_8p_t   [INTERP-1:0];   // 求和后 8 并行
    typedef dac_t      dac_8p_t   [INTERP-1:0];   // DAC 8 并行

endpackage : tx_bf_pkg

`endif // TX_BF_PKG_SV
