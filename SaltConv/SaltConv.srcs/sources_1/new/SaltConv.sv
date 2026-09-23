`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltConv
// Description:
//   事件驅動 Conv 層。設計依據見 docs/SNN/Concept/Layer-RTL/Conv.md。
//   目前只有 Part 0(介面規格)定案,module 本體待後續 part 依序填入。
//////////////////////////////////////////////////////////////////////////////////

module SaltConv #(
	// 空間/通道位寬
	parameter integer X_WIDTH = 9,
	parameter integer Y_WIDTH = 9,
	parameter integer C_WIDTH = 4,

	// 維度與幾何
	parameter integer C     = 2,
	parameter integer OC    = 16,
	parameter integer H_OUT = 64,
	parameter integer W_OUT = 64,
	parameter integer K     = 3,
	parameter integer S     = 1,
	parameter integer P     = 1,

	// 時間與資料
	parameter integer T_WIDTH = 16,
	parameter integer QB       = 8,
	parameter integer V_WIDTH = 12,

	// LIF(整層共用一組)
	parameter integer TAU  = 16,
	parameter integer V_TH = 1,

	// 輸入 FIFO
	parameter integer FIFO_DEPTH = 16
)(
	input  logic clk,
	input  logic rst_n,          // active-low,同步釋放

	// 輸入事件(分離欄位)
	input  logic                  s_valid,
	output logic                  s_ready,
	input  logic [X_WIDTH-1:0]    s_x,
	input  logic [Y_WIDTH-1:0]    s_y,
	input  logic [C_WIDTH-1:0]    s_c,
	input  logic [T_WIDTH-1:0]    s_t,

	// 輸出事件(分離欄位)
	output logic                     m_valid,
	input  logic                     m_ready,
	output logic [$clog2(OC)-1:0]    m_oc,
	output logic [$clog2(H_OUT)-1:0] m_oy,
	output logic [$clog2(W_OUT)-1:0] m_ox,
	output logic [T_WIDTH-1:0]       m_t
);

endmodule
