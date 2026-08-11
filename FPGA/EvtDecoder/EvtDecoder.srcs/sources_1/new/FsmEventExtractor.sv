`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/08/10 16:32:48
// Design Name:
// Module Name: FsmEventExtractor
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//   Top-level:axis_data_fifo_0(16 深輸入緩衝)-> EventProcessor(展開 FSM)
//   -> 外部 m_axis;FsmConfigSetter 提供 AXI-Lite 控制介面。
//   對外只留 s_axis / m_axis / s_axi_lite / clk / reset。
//
// Dependencies:
//   axis_data_fifo_0(Xilinx axis_data_fifo IP,16 深、64-bit、HAS_TLAST=1,
//   HAS_TKEEP=HAS_TSTRB=0,IS_ACLK_ASYNC=0)、EventProcessor、FsmConfigSetter
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////

module FsmEventExtractor #(
	parameter integer C_S_AXIS_TDATA_WIDTH = 64,
	parameter integer C_M_AXIS_TDATA_WIDTH = 64,
	parameter integer C_S_AXI_DATA_WIDTH   = 32,
	parameter integer C_S_AXI_ADDR_WIDTH   = 32
)(
	// AXI4-Stream CLK & RSTN
	input logic  AXIS_ACLK,
	input logic  AXIS_ARESETN,

	// AXI4-Stream Slave(接感測器/ESST)
	output logic  S_AXIS_TREADY,
	input logic [C_S_AXIS_TDATA_WIDTH-1 : 0] S_AXIS_TDATA,
	input logic [(C_S_AXIS_TDATA_WIDTH/8)-1 : 0] S_AXIS_TSTRB,
	input logic  S_AXIS_TLAST,
	input logic  S_AXIS_TVALID,

	// AXI4-Stream Master(接 axi_dma)
	output logic  M_AXIS_TVALID,
	output logic [C_M_AXIS_TDATA_WIDTH-1 : 0] M_AXIS_TDATA,
	output logic [(C_M_AXIS_TDATA_WIDTH/8)-1 : 0] M_AXIS_TSTRB,
	output logic  M_AXIS_TLAST,
	input logic  M_AXIS_TREADY,

	// AXI4-Lite Slave(接 PS 控制)
	input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
	input wire [2 : 0] S_AXI_AWPROT,
	input wire  S_AXI_AWVALID,
	output wire  S_AXI_AWREADY,
	input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
	input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
	input wire  S_AXI_WVALID,
	output wire  S_AXI_WREADY,
	output wire [1 : 0] S_AXI_BRESP,
	output wire  S_AXI_BVALID,
	input wire  S_AXI_BREADY,
	input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
	input wire [2 : 0] S_AXI_ARPROT,
	input wire  S_AXI_ARVALID,
	output wire  S_AXI_ARREADY,
	output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
	output wire [1 : 0] S_AXI_RRESP,
	output wire  S_AXI_RVALID,
	input wire  S_AXI_RREADY
);

	/* ---------------- FsmConfigSetter 輸出的控制訊號 ---------------- */
	logic cfg_enable;
	logic cfg_enable_pattern;
	logic [15:0] cfg_tlast_timeout;
	logic cfg_soft_reset;
	logic cfg_fifo_clear;

	/* ---------------- Reset 產生:soft_reset 影響全部,fifo_clear 只影響 FIFO ---------------- */
	logic rstn_core; // 給 EventProcessor:整體軟體重置
	logic rstn_fifo; // 給 axis_data_fifo_0:軟體重置 或 只清 FIFO 都會觸發
	assign rstn_core = AXIS_ARESETN && !cfg_soft_reset;
	assign rstn_fifo = AXIS_ARESETN && !cfg_soft_reset && !cfg_fifo_clear;

	/* ---------------- 輸入端:axis_data_fifo_0 -> EventProcessor ---------------- */
	logic fifo_m_tvalid;
	logic fifo_m_tready;
	logic [C_S_AXIS_TDATA_WIDTH-1:0] fifo_m_tdata;
	logic fifo_m_tlast;

	axis_data_fifo_0 u_axis_data_fifo (
		.s_axis_aresetn (rstn_fifo),
		.s_axis_aclk    (AXIS_ACLK),
		.s_axis_tvalid  (S_AXIS_TVALID),
		.s_axis_tready  (S_AXIS_TREADY),
		.s_axis_tdata   (S_AXIS_TDATA),
		.s_axis_tlast   (S_AXIS_TLAST),
		.m_axis_tvalid  (fifo_m_tvalid),
		.m_axis_tready  (fifo_m_tready),
		.m_axis_tdata   (fifo_m_tdata),
		.m_axis_tlast   (fifo_m_tlast)
	);

	/* ---------------- 展開 FSM ---------------- */
	EventProcessor #(
		.C_S_AXIS_TDATA_WIDTH(C_S_AXIS_TDATA_WIDTH),
		.C_M_AXIS_TDATA_WIDTH(C_M_AXIS_TDATA_WIDTH)
	) u_event_processor (
		.AXIS_ACLK(AXIS_ACLK),
		.AXIS_ARESETN(rstn_core),

		.S_AXIS_TREADY(fifo_m_tready),
		.S_AXIS_TDATA(fifo_m_tdata),
		.S_AXIS_TSTRB({(C_S_AXIS_TDATA_WIDTH/8){1'b1}}), // FIFO 沒接 tstrb,EVT2.1 一律整拍有效
		.S_AXIS_TLAST(fifo_m_tlast),
		.S_AXIS_TVALID(fifo_m_tvalid),

		.M_AXIS_TVALID(M_AXIS_TVALID),
		.M_AXIS_TDATA(M_AXIS_TDATA),
		.M_AXIS_TSTRB(M_AXIS_TSTRB),
		.M_AXIS_TLAST(M_AXIS_TLAST),
		.M_AXIS_TREADY(M_AXIS_TREADY),

		.cfg_enable(cfg_enable),
		.cfg_enable_pattern(cfg_enable_pattern),
		.cfg_tlast_timeout(cfg_tlast_timeout)
	);

	/* ---------------- AXI-Lite 控制介面 ---------------- */
	FsmConfigSetter #(
		.C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
	) u_fsm_config_setter (
		.S_AXI_ACLK(AXIS_ACLK),
		.S_AXI_ARESETN(AXIS_ARESETN), // AXI-Lite 本身不跟著 soft_reset 一起重置,不然 PS 沒辦法再把它改回來

		.S_AXI_AWADDR(S_AXI_AWADDR),
		.S_AXI_AWPROT(S_AXI_AWPROT),
		.S_AXI_AWVALID(S_AXI_AWVALID),
		.S_AXI_AWREADY(S_AXI_AWREADY),
		.S_AXI_WDATA(S_AXI_WDATA),
		.S_AXI_WSTRB(S_AXI_WSTRB),
		.S_AXI_WVALID(S_AXI_WVALID),
		.S_AXI_WREADY(S_AXI_WREADY),
		.S_AXI_BRESP(S_AXI_BRESP),
		.S_AXI_BVALID(S_AXI_BVALID),
		.S_AXI_BREADY(S_AXI_BREADY),
		.S_AXI_ARADDR(S_AXI_ARADDR),
		.S_AXI_ARPROT(S_AXI_ARPROT),
		.S_AXI_ARVALID(S_AXI_ARVALID),
		.S_AXI_ARREADY(S_AXI_ARREADY),
		.S_AXI_RDATA(S_AXI_RDATA),
		.S_AXI_RRESP(S_AXI_RRESP),
		.S_AXI_RVALID(S_AXI_RVALID),
		.S_AXI_RREADY(S_AXI_RREADY),

		.cfg_enable(cfg_enable),
		.cfg_enable_pattern(cfg_enable_pattern),
		.cfg_tlast_timeout(cfg_tlast_timeout),
		.cfg_soft_reset(cfg_soft_reset),
		.cfg_fifo_clear(cfg_fifo_clear)
	);

endmodule
