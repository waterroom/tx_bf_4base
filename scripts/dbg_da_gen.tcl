# dbg_da_gen.tcl — 命令行调试 tb_da_data_gen (全部 IP 库)
set proj_root "C:/workbuddy_chat/tx_bf_4base"
cd $proj_root
set glbl [file join $env(RDI_DATADIR) "verilog" "src" "glbl.v"]
puts "=== 编译 RTL + TB ==="
set rtl_files [glob -nocomplain [file join $proj_root rtl *.sv]]
set rtl_files [lsearch -all -inline -not -exact $rtl_files [file join $proj_root rtl tx_bf_pkg.sv]]
exec xvlog -sv -i [file join $proj_root rtl] [file join $proj_root rtl tx_bf_pkg.sv] {*}$rtl_files [file join $proj_root tb tb_da_data_gen.sv]
exec xvlog $glbl
puts "=== xvhdl IP 明文模型 ==="
exec xvhdl [file join $proj_root sim_src fir_300to600_87p5pass_hf.vhd] [file join $proj_root sim_src fir_600to1200_87p5pass_hf.vhd] [file join $proj_root sim_src fir_1200to2400_87p5pass_hf.vhd]
exec xvhdl [file join $proj_root vivado_sim vivado_sim.srcs sources_1 ip dds_core sim dds_core.vhd]
puts "=== xelab (全部 IP 库) ==="
exec xelab -debug typical -L xpm -L fir_compiler_v7_2_18 -L xbip_utils_v3_0_10 -L axi_utils_v2_0_6 \
    -L dds_compiler_v6_0_22 -L xbip_pipe_v3_0_6 -L xbip_bram18k_v3_0 -L mult_gen_v12_0 \
    -L xbip_dsp48_wrapper_v3_0 -L xbip_dsp48_addsub_v3_0 -L xbip_dsp48_multadd_v3_0 \
    tb_da_data_gen glbl -s tb_dg
puts "=== 仿真 ==="
set sim_res [exec xsim tb_dg -runall]
puts $sim_res
puts "=== 完成 ==="
