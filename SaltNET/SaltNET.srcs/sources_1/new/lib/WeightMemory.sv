`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: WeightMemory
// Description:
//   權重 ROM,conv、FC 共用,同步讀取:這一拍送 (out_index, in_index),READ_LATENCY 拍後 read_word 是那一格的寬字。
//   一筆事件逐拍換 out_index(conv 的 o_c、FC 的列 y),in_index 是事件帶來的編號(conv 的 c、FC 的 src)。
//   位址 out_index * IN_COUNT + in_index,深度 OUT_COUNT * IN_COUNT,緊密排列,不補到 2 的次方。
//     conv:o_c * C + c,寬字是一個 kernel(Conv.md 第 2 節「權重」)
//     FC  :y * n_in + src,寬字是一列 n_col 顆的權重碼(FC.md 第 2 節「權重」)
//   寬字裡怎麼切由上層決定(conv 在每個 bank 的 generate 區塊裡選 tap,FC 在每行的 generate 區塊裡切)。
//   這裡只算位址;陣列、$readmemh、讀出暫存器在 lib/ReadOnlyMemory(READ_LATENCY、read_enable、shift_enable 的行為見那裡)。
//   內容用 $readmemh 從 WEIGHT_FILE 載入,檔案格式見 Conv.md、FC.md 第 2 節「權重」的「檔案格式」。
//   上層保證 in_index < IN_COUNT、out_index < OUT_COUNT,超出時讀出的值不保證。
//////////////////////////////////////////////////////////////////////////////////

module WeightMemory #(
	parameter integer IN_INDEX_WIDTH = 4,      // in_index 位寬,由上層決定(conv 的 c 位寬由上游決定,不一定等於 $clog2(IN_COUNT))
	parameter integer IN_COUNT       = 2,      // conv:C;FC:n_in
	parameter integer OUT_COUNT      = 16,     // conv:OC;FC:n_row
	parameter integer WORD_WIDTH     = 63,     // conv:K*K*b;FC:n_col*b
	parameter integer READ_LATENCY   = 1,      // R,送讀位址到資料可用的拍數,至少 1

	// 不寫型別:Vivado 不支援 SystemVerilog string 型別參數,也不支援空字串參數(UG901)
	parameter WEIGHT_FILE = "weight.mem",

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	localparam integer WEIGHT_DEPTH      = OUT_COUNT * IN_COUNT,
	localparam integer WEIGHT_ADDR_WIDTH = (WEIGHT_DEPTH > 1) ? $clog2(WEIGHT_DEPTH) : 1,
	localparam integer OUT_INDEX_WIDTH   = (OUT_COUNT > 1) ? $clog2(OUT_COUNT) : 1
)(
	input  logic clk,

	input  logic                       read_enable,
	input  logic                       shift_enable,   // 第二級起往後推的開關(接 BRAM 輸出暫存器的 CE)
	input  logic [OUT_INDEX_WIDTH-1:0] out_index,      // conv:o_c;FC:y
	input  logic [IN_INDEX_WIDTH-1:0]  in_index,       // conv:c;FC:src
	output logic [WORD_WIDTH-1:0]      read_word       // read_enable 那拍的 READ_LATENCY 拍後有效
);

	logic [WEIGHT_ADDR_WIDTH-1:0] read_addr;

	// out_index < OUT_COUNT、in_index < IN_COUNT 時結果一定小於 WEIGHT_DEPTH,截斷不會丟資料
	assign read_addr = WEIGHT_ADDR_WIDTH'(out_index * IN_COUNT + in_index);

	ReadOnlyMemory #(
		.DEPTH       (WEIGHT_DEPTH),
		.WORD_WIDTH  (WORD_WIDTH),
		.READ_LATENCY(READ_LATENCY),
		.INIT_FILE   (WEIGHT_FILE)
	) memory_array (
		.clk         (clk),
		.read_enable (read_enable),
		.shift_enable(shift_enable),
		.read_addr   (read_addr),
		.read_word   (read_word)
	);

endmodule
