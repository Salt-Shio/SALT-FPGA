`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: NeuronMemoryArray
// Description:
//   NeuronMemory 一個 bank 的記憶體陣列,只放陣列、寫入、讀出暫存器,推斷成一顆 BRAM(simple dual port)。
//   讀:read_enable 那拍送 read_addr,READ_LATENCY 拍後 read_word 有效(R,Conv.md 5.5);
//       READ_LATENCY = 1 只用 BRAM 的讀出暫存器,2 再用 BRAM 內建的輸出暫存器(DOB_REG),大於 2 多出的級是一般 FF;
//       read_enable=0 時第一級保持上一次讀出的值;第二級起 shift_enable=1 才往後推,0 時保持。
//   寫:write_enable 那拍的 posedge 寫入。
//   同一拍讀、寫同一個位址時,讀出的值不保證,上層要避開。
//   上層保證 read_addr、write_addr 小於 DEPTH,超出時讀寫的結果不保證。
//   模組加 keep_hierarchy = "soft",照 AMD XPM 記憶體模組(xpm_memory_base)的做法,而且跟 XPM 一樣只框住陣列和讀出暫存器:
//     上層攤平時,跨模組的最佳化會讓輸出暫存器併不進 BRAM(Synth 8-7052,Vivado 沒有說明原因);
//     soft 只留常數傳遞,其他跨邊界最佳化都擋掉(UG901)。清除等其他邏輯放在外層,照常跟外面一起最佳化。
//   布局時 Vivado 可能把輸出暫存器搬到 BRAM 外面的 FF(BRAM register optimization,時序變好才搬),行為不變。
//////////////////////////////////////////////////////////////////////////////////

(* keep_hierarchy = "soft" *)
module NeuronMemoryArray #(
	parameter integer DEPTH        = 1024,   // 佔位預設值,實際深度由例化端決定
	parameter integer WORD_WIDTH   = 25,
	parameter integer READ_LATENCY = 1,      // R,送讀位址到資料可用的拍數,至少 1

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	localparam integer ADDR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
	input  logic clk,

	// 寫 port
	input  logic                  write_enable,
	input  logic [ADDR_WIDTH-1:0] write_addr,
	input  logic [WORD_WIDTH-1:0] write_word,

	// 讀 port
	input  logic                  read_enable,
	input  logic                  shift_enable,   // 第二級起往後推的開關(接 BRAM 輸出暫存器的 CE)
	input  logic [ADDR_WIDTH-1:0] read_addr,
	output logic [WORD_WIDTH-1:0] read_word
);

	// 一律用 BRAM,不交給 Vivado 依大小判斷:各層同一種資源,功耗、用量才能比較
	(* ram_style = "block" *) logic [WORD_WIDTH-1:0] bank [0:DEPTH-1];

	always_ff @(posedge clk) begin
		if (write_enable) begin
			bank[write_addr] <= write_word;
		end
	end

	// 讀出:[0] 是 BRAM 的讀出暫存器,[1] 是輸出暫存器
	logic [WORD_WIDTH-1:0] read_stage [0:READ_LATENCY-1];

	always_ff @(posedge clk) begin
		if (read_enable) begin
			read_stage[0] <= bank[read_addr];
		end
	end

	// 第二級起 shift_enable=1 往後推;第二級 Vivado 併進 BRAM 的輸出暫存器
	for (genvar stage = 1; stage < READ_LATENCY; stage++) begin : read_stages
		always_ff @(posedge clk) begin
			if (shift_enable) begin
				read_stage[stage] <= read_stage[stage-1];
			end
		end
	end

	assign read_word = read_stage[READ_LATENCY-1];

endmodule
