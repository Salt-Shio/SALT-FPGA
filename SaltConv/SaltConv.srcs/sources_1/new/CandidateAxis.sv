`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: CandidateAxis
// Description:
//   單軸候選神經元計算(Conv.md 第 2 節「神經元」),純組合邏輯。
//   y、x 兩軸各例化一次,上層再做 BANK_COUNT x BANK_COUNT 配對、組 bank 內位址。
//   第 r 組輸出就是 bank r(out_coord mod BANK_COUNT = r)的候選。
//   valid[r]=0 時,同一組的 out_coord/bank_offset/tap 值不保證,上層不能使用。
//   目前只有介面規格,module 本體待填入。
//////////////////////////////////////////////////////////////////////////////////

module CandidateAxis #(
	parameter integer KERNEL_SIZE    = 3,    // K
	parameter integer STRIDE         = 1,    // S
	parameter integer PADDING        = 1,    // P
	parameter integer OUT_SIZE       = 64,   // O_max,這一軸的輸出長度(OUT_ROWS 或 OUT_COLS)
	parameter integer IN_COORD_WIDTH = 9,    // 輸入座標位元寬(Y_WIDTH 或 X_WIDTH)

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	localparam integer BANK_COUNT        = (KERNEL_SIZE + STRIDE - 1) / STRIDE,   // M = ceil(K/S),這一軸的 bank 數,也是候選數上限
	localparam integer BANK_SLOTS        = (OUT_SIZE + BANK_COUNT - 1) / BANK_COUNT,   // ceil(O_max/M),每個 bank 在這一軸上有幾格
	localparam integer OUT_COORD_WIDTH   = (OUT_SIZE > 1) ? $clog2(OUT_SIZE) : 1,
	localparam integer BANK_OFFSET_WIDTH = (BANK_SLOTS > 1) ? $clog2(BANK_SLOTS) : 1,
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1
)(
	input  logic [IN_COORD_WIDTH-1:0]    in_coord,                         // i,事件在這一軸的座標
	output logic                         valid       [0:BANK_COUNT-1],     // 這一組有沒有合法候選
	output logic [OUT_COORD_WIDTH-1:0]   out_coord   [0:BANK_COUNT-1],     // o,候選的輸出座標
	output logic [BANK_OFFSET_WIDTH-1:0] bank_offset [0:BANK_COUNT-1],     // floor(o/M),在 bank 裡的第幾格
	output logic [TAP_WIDTH-1:0]         tap         [0:BANK_COUNT-1]      // k,kernel tap
);

endmodule
