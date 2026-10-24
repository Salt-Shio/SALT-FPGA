`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltFC
// Description:
//   事件驅動 FC 層。設計依據見 docs/SNN/Concept/Layer-RTL/FC.md。
//   名稱用描述性完整拼字,行尾註解標 FC.md 的數學符號。
//   目前只有介面(SaltFC Part 2),module 本體由後續 Part 依序填入。
//
//   n_out 顆神經元照編號逐列排,每列 n_col 顆,一拍處理一列;一筆事件從第 0 列做到第 n_row-1 列。
//   SystemVerilog 不能照 parameter 拿掉 port:SPIKE_OUTPUT = 0 時 spike 輸出埠的 out_valid 固定 0,
//   MEMBRANE_OUTPUT = 0 時膜電位輸出埠的 membrane_valid 固定 0,合成時修剪掉。
//////////////////////////////////////////////////////////////////////////////////

module SaltFC #(
	// 維度
	parameter integer IN_NEURONS      = 1296,   // n_in,上一層神經元數
	parameter integer OUT_NEURONS     = 10,     // n_out,這一層神經元數
	parameter integer NEURONS_PER_ROW = 4,      // n_col,每列幾顆,也是更新電路份數

	// 時間與資料
	parameter integer TIME_WIDTH          = 16,   // 單位:整數 ms
	parameter integer WEIGHT_WIDTH        = 7,    // b,權重碼位元寬
	parameter integer MEMBRANE_INT_WIDTH  = 14,   // i_V,膜電位暫存器整數位元(含符號位)
	parameter integer MEMBRANE_FRAC_WIDTH = 0,    // f_V,膜電位暫存器小數位元
	parameter integer DECAY_FRAC_WIDTH    = 6,    // f_a,衰減碼小數位元
	parameter integer DECAY_TABLE_DEPTH   = 75,   // Δt_max,衰減表深度

	// 量化行為(兩種都要能合成,由例化端選)
	parameter bit ROUND    = 1,   // 1:round,0:truncate
	parameter bit SATURATE = 1,   // 1:飽和,0:繞回

	// 兩個輸出各自的開關(FC.md 第 6 節 ②)
	parameter bit SPIKE_OUTPUT    = 1,   // 1:判斷 fire、送 spike;0:不 fire,沒有門檻 BRAM
	parameter bit MEMBRANE_OUTPUT = 0,   // 1:每寫回一列送出這一列的 V̂_new

	// 訓練出來的資料,用 $readmemh 載入,格式見 FC.md 第 2 節「權重」「門檻」、第 3 節 ①
	// 不寫型別:Vivado 不支援 SystemVerilog string 型別參數,也不支援空字串參數(UG901)
	parameter WEIGHT_FILE    = "weight.mem",      // 權重寬字,位址 y*n_in + src,每字 NEURONS_PER_ROW*WEIGHT_WIDTH bits
	parameter THRESHOLD_FILE = "threshold.mem",   // 門檻寬字,位址 y,每字 NEURONS_PER_ROW*MEMBRANE_WIDTH bits;SPIKE_OUTPUT = 0 時不讀
	parameter DECAY_FILE     = "decay.mem",       // 衰減表,位址 Δt-1,每字 DECAY_FRAC_WIDTH bits 無號

	// 輸入 FIFO
	parameter integer FIFO_DEPTH = 16,

	// 管線(FC.md 第 5 節 ⑤、⑦)
	parameter integer READ_LATENCY    = 1,   // R,送讀位址到資料可用的拍數;2 = 開 BRAM 輸出暫存器
	parameter integer COMPUTE_LATENCY = 1,   // C,計算級數:1 或 2(2 = 在第 3 節 ② 之後切開)
	parameter bit     OVERLAP         = 0,   // 1:列跟列重疊,下一列先讀、前一列還在算

	// 推導出來的位寬($clog2(1)=0 時至少保留 1 bit)
	localparam integer MEMBRANE_WIDTH   = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH,   // w
	localparam integer ROW_COUNT        = (OUT_NEURONS + NEURONS_PER_ROW - 1) / NEURONS_PER_ROW,   // n_row
	localparam integer IN_NEURON_WIDTH  = (IN_NEURONS > 1) ? $clog2(IN_NEURONS) : 1,
	localparam integer OUT_NEURON_WIDTH = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1
)(
	input  logic clk,
	input  logic rst_n,   // active-low,同步釋放;釋放後先把神經元記憶體逐位址清 0,清完才拉高 in_ready

	// 輸入事件 (src, t)(分離欄位,valid/ready 握手);FC 接 FC 時接上一層同名的 out_ 欄位
	input  logic                       in_valid,
	output logic                       in_ready,
	input  logic [IN_NEURON_WIDTH-1:0] in_neuron,   // src,上一層送出 spike 的神經元編號
	input  logic [TIME_WIDTH-1:0]      in_time,

	// spike 輸出 (i, t)(分離欄位,valid/ready 握手);SPIKE_OUTPUT = 0 時 out_valid 固定 0
	output logic                        out_valid,
	input  logic                        out_ready,
	output logic [OUT_NEURON_WIDTH-1:0] out_neuron,   // i = y*n_col + x
	output logic [TIME_WIDTH-1:0]       out_time,     // 觸發這次 fire 的輸入事件時間

	// 膜電位輸出(valid/ready 握手),每寫回一列送出一筆;MEMBRANE_OUTPUT = 0 時 membrane_valid 固定 0
	output logic                                       membrane_valid,
	input  logic                                       membrane_ready,
	output logic [OUT_NEURON_WIDTH-1:0]                membrane_row_start,   // y*n_col,這一列第 0 行的神經元編號
	output logic [NEURONS_PER_ROW*MEMBRANE_WIDTH-1:0]  membrane_values,      // 第 x 行的 V̂_new 在第 x*w 到 (x+1)*w-1 位元;最後一列空的位置沒有意義
	output logic [TIME_WIDTH-1:0]                      membrane_time         // 觸發這次更新的輸入事件時間
);

endmodule
