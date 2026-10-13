`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: NeuronMemory
// Description:
//   神經元記憶體的一個 bank(Conv.md 第 2 節「神經元」),存輸出神經元的 (V̂, t_last)。
//   上層例化 AXIS_BANK_COUNT x AXIS_BANK_COUNT 份,bank (r_y, r_x) 存 o_y mod M = r_y、o_x mod M = r_x 的神經元。
//   bank 內位址由上層(CandidateGrid 的 bank_addr)算好送進來,一律開 BANK_DEPTH 格。
//   一個讀 port、一個寫 port(simple dual port),位址各自獨立:
//     讀:read_enable 那拍送 read_addr,下一拍 read_membrane、read_last_time 有效;
//         read_enable=0 時保持上一次讀出的值。
//     寫:write_enable 那拍的 posedge 寫入。
//   同一拍讀、寫同一個位址時,讀出的值不保證,上層要避開。
//   每格存一個字 {t_last, V̂},V̂ 在低位,寬 MEMBRANE_WIDTH + TIME_WIDTH。
//   清除(Conv.md 第 2 節「清除」):clearing、clear_addr 由 NeuronMemoryClear 給,每個 bank 共用同一份;
//   clearing=1 的每個 posedge 把 clear_addr 那一格寫 0,外部寫入一律忽略。
//   上層保證 read_addr、write_addr 小於 BANK_DEPTH,超出時讀寫的結果不保證。
//////////////////////////////////////////////////////////////////////////////////

module NeuronMemory #(
	parameter integer BANK_DEPTH     = 1024,   // 佔位預設值,實際深度由例化端決定(每個 bank 的格數)
	parameter integer MEMBRANE_WIDTH = 9,      // w,膜電位暫存器位元寬(有號)
	parameter integer TIME_WIDTH     = 16,     // t_last 位元寬,單位:整數 ms

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	localparam integer BANK_ADDR_WIDTH = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1,
	localparam integer WORD_WIDTH      = MEMBRANE_WIDTH + TIME_WIDTH   // {t_last, V̂}
)(
	input  logic clk,

	// 清除,接 NeuronMemoryClear
	input  logic                              clearing,
	input  logic        [BANK_ADDR_WIDTH-1:0] clear_addr,

	// 讀 port
	input  logic                              read_enable,
	input  logic        [BANK_ADDR_WIDTH-1:0] read_addr,
	output logic signed [MEMBRANE_WIDTH-1:0]  read_membrane,     // V̂
	output logic        [TIME_WIDTH-1:0]      read_last_time,    // t_last

	// 寫 port
	input  logic                              write_enable,
	input  logic        [BANK_ADDR_WIDTH-1:0] write_addr,
	input  logic signed [MEMBRANE_WIDTH-1:0]  write_membrane,    // V̂_new
	input  logic        [TIME_WIDTH-1:0]      write_last_time    // t
);

	// 一律用 BRAM,不交給 Vivado 依大小判斷:各層同一種資源,功耗、用量才能比較
	(* ram_style = "block" *) logic [WORD_WIDTH-1:0] bank [0:BANK_DEPTH-1];

	logic                       bank_write_enable;
	logic [BANK_ADDR_WIDTH-1:0] bank_write_addr;
	logic [WORD_WIDTH-1:0]      bank_write_word;
	logic [WORD_WIDTH-1:0]      bank_read_word;   // BRAM 的讀出暫存器

	// 清除期間寫 0,外部寫入忽略
	assign bank_write_enable = clearing || write_enable;
	assign bank_write_addr   = clearing ? clear_addr : write_addr;
	assign bank_write_word   = clearing ? '0 : {write_last_time, write_membrane};

	always_ff @(posedge clk) begin
		if (bank_write_enable) begin
			bank[bank_write_addr] <= bank_write_word;
		end
	end

	// 讀取端清除不接管,直接用外部的
	always_ff @(posedge clk) begin
		if (read_enable) begin
			bank_read_word <= bank[read_addr];
		end
	end

	assign read_membrane  = bank_read_word[MEMBRANE_WIDTH-1:0];
	assign read_last_time = bank_read_word[WORD_WIDTH-1:MEMBRANE_WIDTH];

endmodule
