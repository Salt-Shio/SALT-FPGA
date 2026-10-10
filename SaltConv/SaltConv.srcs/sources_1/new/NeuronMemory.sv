`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: NeuronMemory
// Description:
//   神經元記憶體(Conv.md 第 2 節「神經元」),存每顆輸出神經元的 (V̂, t_last)。
//   AXIS_BANK_COUNT x AXIS_BANK_COUNT 個 bank,bank (r_y, r_x) 存 o_y mod M = r_y、o_x mod M = r_x 的神經元。
//   bank 內位址由上層(CandidateGrid 的 bank_addr)算好送進來,每個 bank 一律開 BANK_DEPTH 格。
//   每個 bank 一個讀 port、一個寫 port(simple dual port),位址各自獨立:
//     讀:read_enable 那拍送 read_addr,下一拍 read_membrane、read_last_time 有效;
//         read_enable=0 時保持上一次讀出的值。
//     寫:write_enable 那拍的 posedge 寫入。
//   同一個 bank 同一拍讀、寫同一個位址時,讀出的值不保證,上層要避開。
//   每格存一個字 {t_last, V̂},V̂ 在低位,寬 MEMBRANE_WIDTH + TIME_WIDTH。
//   清除(Conv.md 第 2 節「清除」):rst_n=0 期間 clearing=1;釋放後第 n 個 posedge 每個 bank 的位址 n-1 寫 0,
//   寫完位址 BANK_DEPTH-1 的那個 posedge 之後 clearing 變 0。clearing=1 期間外部寫入一律忽略。
//   上層保證 read_addr、write_addr 小於 BANK_DEPTH,超出時讀寫的結果不保證。
//////////////////////////////////////////////////////////////////////////////////

module NeuronMemory #(
	parameter integer OUT_CHANNELS   = 16,   // OC
	parameter integer OUT_ROWS       = 64,   // H_out
	parameter integer OUT_COLS       = 64,   // W_out
	parameter integer KERNEL_SIZE    = 3,    // K
	parameter integer STRIDE         = 1,    // S
	parameter integer MEMBRANE_WIDTH = 9,    // w,膜電位暫存器位元寬(有號)
	parameter integer TIME_WIDTH     = 16,   // t_last 位元寬,單位:整數 ms

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	// AXIS_BANK_COUNT、*_SLOTS、BANK_* 跟 CandidateGrid 的 localparam 同一套公式,bank_addr 才接得上
	localparam integer AXIS_BANK_COUNT = (KERNEL_SIZE + STRIDE - 1) / STRIDE,                  // M = ceil(K/S),每軸的 bank 數
	localparam integer ROW_SLOTS       = (OUT_ROWS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT,   // G_y = ceil(H_out/M)
	localparam integer COL_SLOTS       = (OUT_COLS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT,   // G_x = ceil(W_out/M)
	localparam integer BANK_DEPTH      = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS,                 // 每個 bank 的格數
	localparam integer BANK_ADDR_WIDTH = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1,
	localparam integer WORD_WIDTH      = MEMBRANE_WIDTH + TIME_WIDTH                           // {t_last, V̂}
)(
	input  logic clk,
	input  logic rst_n,      // active-low,非同步觸發、同步釋放
	output logic clearing,   // 1:還在清,上層不能收事件

	// 讀 port,每個 bank 一組
	input  logic                              read_enable     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],
	input  logic        [BANK_ADDR_WIDTH-1:0] read_addr       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],
	output logic signed [MEMBRANE_WIDTH-1:0]  read_membrane   [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // V̂
	output logic        [TIME_WIDTH-1:0]      read_last_time  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // t_last

	// 寫 port,每個 bank 一組
	input  logic                              write_enable    [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],
	input  logic        [BANK_ADDR_WIDTH-1:0] write_addr      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],
	input  logic signed [MEMBRANE_WIDTH-1:0]  write_membrane  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // V̂_new
	input  logic        [TIME_WIDTH-1:0]      write_last_time [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1]    // t
);

	// 清除:所有 bank 共用同一個位址計數器,同一拍寫同一個位址
	logic [BANK_ADDR_WIDTH-1:0] clear_addr;

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			clearing   <= 1'b1;
			clear_addr <= '0;
		end else if (clearing) begin
			if (clear_addr == BANK_ADDR_WIDTH'(BANK_DEPTH - 1)) begin
				clearing <= 1'b0;
			end else begin
				clear_addr <= clear_addr + 1'b1;
			end
		end
	end

	for (genvar row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin : row_banks
		for (genvar col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin : col_banks
			// 一律用 BRAM,不交給 Vivado 依大小判斷:各層同一種資源,功耗、用量才能比較
			(* ram_style = "block" *) logic [WORD_WIDTH-1:0] bank [0:BANK_DEPTH-1];

			logic                       bank_write_enable;
			logic [BANK_ADDR_WIDTH-1:0] bank_write_addr;
			logic [WORD_WIDTH-1:0]      bank_write_word;
			logic                       bank_read_enable;
			logic [BANK_ADDR_WIDTH-1:0] bank_read_addr;
			logic [WORD_WIDTH-1:0]      bank_read_word;   // BRAM 的讀出暫存器

			// 清除期間寫 0,外部寫入忽略
			assign bank_write_enable = clearing || write_enable[row_bank][col_bank];
			assign bank_write_addr   = clearing ? clear_addr : write_addr[row_bank][col_bank];
			assign bank_write_word   = clearing ? '0
			                                    : {write_last_time[row_bank][col_bank], write_membrane[row_bank][col_bank]};

			// 讀取端清除不接管,直接用外部的
			assign bank_read_enable = read_enable[row_bank][col_bank];
			assign bank_read_addr   = read_addr[row_bank][col_bank];

			always_ff @(posedge clk) begin
				if (bank_write_enable) begin
					bank[bank_write_addr] <= bank_write_word;
				end
			end

			always_ff @(posedge clk) begin
				if (bank_read_enable) begin
					bank_read_word <= bank[bank_read_addr];
				end
			end

			assign read_membrane[row_bank][col_bank]  = bank_read_word[MEMBRANE_WIDTH-1:0];
			assign read_last_time[row_bank][col_bank] = bank_read_word[WORD_WIDTH-1:MEMBRANE_WIDTH];
		end
	end

endmodule
