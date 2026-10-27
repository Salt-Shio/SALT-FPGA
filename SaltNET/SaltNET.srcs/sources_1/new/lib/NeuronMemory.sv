`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: NeuronMemory
// Description:
//   神經元記憶體,conv、FC 共用:清除 + 一顆 BRAM(simple dual port),一個讀 port、一個寫 port,位址各自獨立。
//     conv:一個 bank,每格存 {t_last, V̂}(Conv.md 第 2 節「神經元」),上層例化 M x M 份
//     FC  :每格存一列 n_col 顆的 V̂(FC.md 第 2 節「神經元」),上層例化 1 份
//   寬字怎麼打包、切段由上層決定(conv、FC 都在 generate 區塊裡),這裡只認 WORD_WIDTH 位元的字。
//     讀:read_enable 那拍送 read_addr,READ_LATENCY 拍後 read_word 有效(R);
//         read_enable=0 時保持上一次讀出的值;R >= 2 時第二級起 shift_enable=1 才往後推。
//     寫:write_enable 那拍的 posedge 寫入。
//   同一拍讀、寫同一個位址時,讀出的值不保證,上層要避開。
//   清除(Conv.md、FC.md 第 2 節「清除」):clearing、clear_addr 由 NeuronMemoryClear 給,一層共用一份;
//   clearing=1 的每個 posedge 把 clear_addr 那一格寫 0,外部寫入一律忽略。
//   上層保證 read_addr、write_addr 小於 DEPTH,超出時讀寫的結果不保證。
//   這一層只放清除;陣列和讀出暫存器在 lib/NeuronMemoryArray(BRAM 輸出暫存器怎麼保證併入,見那個檔頭)。
//////////////////////////////////////////////////////////////////////////////////

module NeuronMemory #(
	parameter integer DEPTH        = 1024,   // 佔位預設值,實際深度由例化端決定(conv:一個 bank 的格數;FC:n_row)
	parameter integer WORD_WIDTH   = 25,     // conv:TIME_WIDTH + w;FC:n_col*w
	parameter integer READ_LATENCY = 1,      // R,送讀位址到資料可用的拍數,至少 1

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	localparam integer ADDR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
	input  logic clk,

	// 清除,接 NeuronMemoryClear
	input  logic                  clearing,
	input  logic [ADDR_WIDTH-1:0] clear_addr,

	// 讀 port
	input  logic                  read_enable,
	input  logic                  shift_enable,   // 讀出第二級起往後推的開關
	input  logic [ADDR_WIDTH-1:0] read_addr,
	output logic [WORD_WIDTH-1:0] read_word,

	// 寫 port
	input  logic                  write_enable,
	input  logic [ADDR_WIDTH-1:0] write_addr,
	input  logic [WORD_WIDTH-1:0] write_word
);

	logic                  array_write_enable;
	logic [ADDR_WIDTH-1:0] array_write_addr;
	logic [WORD_WIDTH-1:0] array_write_word;

	// 清除期間寫 0,外部寫入忽略
	assign array_write_enable = clearing || write_enable;
	assign array_write_addr   = clearing ? clear_addr : write_addr;
	assign array_write_word   = clearing ? '0 : write_word;

	// 讀取端清除不接管,直接用外部的
	NeuronMemoryArray #(
		.DEPTH       (DEPTH),
		.WORD_WIDTH  (WORD_WIDTH),
		.READ_LATENCY(READ_LATENCY)
	) memory_array (
		.clk         (clk),
		.write_enable(array_write_enable),
		.write_addr  (array_write_addr),
		.write_word  (array_write_word),
		.read_enable (read_enable),
		.shift_enable(shift_enable),
		.read_addr   (read_addr),
		.read_word   (read_word)
	);

endmodule
