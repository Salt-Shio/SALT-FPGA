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
	parameter integer T_WIDTH = 16,   // 單位:整數 ms
	parameter integer Q_WIDTH = 7,    // 權重碼位元寬 b
	parameter integer I_V     = 9,    // 膜電位暫存器整數位元(含符號位)
	parameter integer F_V     = 0,    // 膜電位暫存器小數位元
	parameter integer F_A     = 6,    // 衰減碼小數位元
	parameter integer DT_MAX  = 75,   // 衰減表深度 Δt_max

	// 量化行為(兩種都要能合成,尚未選定)
	parameter bit ROUND    = 1,       // 1:round,0:truncate
	parameter bit SATURATE = 1,       // 1:飽和,0:繞回

	// 訓練出來的資料,用 $readmemh 載入
	// 不寫型別:Vivado 不支援 SystemVerilog string 型別參數,也不支援空字串參數(UG901)
	parameter Q_FILE   = "q.mem",     // 權重寬字,位址 (o_c,c),每字 K*K*Q_WIDTH bits
	parameter VTH_FILE = "vth.mem",   // 門檻,位址 o_c,每字 I_V+F_V bits 有號
	parameter A_FILE   = "a.mem",     // 衰減表,位址 Δt-1,每字 F_A bits 無號

	// 輸入 FIFO
	parameter integer FIFO_DEPTH = 16
)(
	input  logic clk,
	input  logic rst_n,          // active-low,同步釋放;釋放後先把神經元記憶體逐位址清 0,清完才拉高 s_ready

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

	localparam integer V_WIDTH = I_V + F_V;   // 膜電位暫存器寬度 w

endmodule
