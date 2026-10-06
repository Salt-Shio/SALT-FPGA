`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: WeightMemory
// Description:
//   權重 ROM(Conv.md 第 2 節「權重」),同步讀取:這一拍送 (o_c, c),下一拍 kernel_word 是 q[o_c,c] 的寬字。
//   位址 o_c * IN_CHANNELS + c,深度 OUT_CHANNELS * IN_CHANNELS,緊密排列,不補到 2 的次方。
//   寬字 KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH bits,tap k_y*K + k_x 從第 (k_y*K + k_x)*WEIGHT_WIDTH bit 起。
//   內容用 $readmemh 從 WEIGHT_FILE 載入,檔案格式見 Conv.md 第 2 節「權重」的「檔案格式」。
//   read_enable=0 時 kernel_word 保持上一次讀出的值。
//   上層保證 in_channel < IN_CHANNELS、out_channel < OUT_CHANNELS,超出時讀出的值不保證。
//////////////////////////////////////////////////////////////////////////////////

module WeightMemory #(
	parameter integer IN_CHANNEL_WIDTH = 4,
	parameter integer IN_CHANNELS      = 2,    // C
	parameter integer OUT_CHANNELS     = 16,   // OC
	parameter integer KERNEL_SIZE      = 3,    // K
	parameter integer WEIGHT_WIDTH     = 7,    // b

	// 不寫型別:Vivado 不支援 SystemVerilog string 型別參數,也不支援空字串參數(UG901)
	parameter WEIGHT_FILE = "weight.mem",

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	localparam integer WEIGHT_DEPTH      = OUT_CHANNELS * IN_CHANNELS,
	localparam integer WEIGHT_ADDR_WIDTH = (WEIGHT_DEPTH > 1) ? $clog2(WEIGHT_DEPTH) : 1,
	localparam integer KERNEL_WORD_WIDTH = KERNEL_SIZE * KERNEL_SIZE * WEIGHT_WIDTH,
	localparam integer OUT_CHANNEL_WIDTH = (OUT_CHANNELS > 1) ? $clog2(OUT_CHANNELS) : 1
)(
	input  logic clk,

	input  logic                         read_enable,
	input  logic [OUT_CHANNEL_WIDTH-1:0] out_channel,   // o_c
	input  logic [IN_CHANNEL_WIDTH-1:0]  in_channel,    // c
	output logic [KERNEL_WORD_WIDTH-1:0] kernel_word    // q[o_c,c],read_enable 那拍的下一拍有效
);

	// 一律用 BRAM,不交給 Vivado 依大小判斷:各層同一種資源,功耗、用量才能比較
	(* rom_style = "block" *) logic [KERNEL_WORD_WIDTH-1:0] rom [0:WEIGHT_DEPTH-1];
	logic [WEIGHT_ADDR_WIDTH-1:0] read_addr;

	initial begin
		$readmemh(WEIGHT_FILE, rom);
	end

	// o_c < OUT_CHANNELS、c < IN_CHANNELS 時結果一定小於 WEIGHT_DEPTH,截斷不會丟資料
	assign read_addr = WEIGHT_ADDR_WIDTH'(out_channel * IN_CHANNELS + in_channel);

	always_ff @(posedge clk) begin
		if (read_enable) begin
			kernel_word <= rom[read_addr];
		end
	end

endmodule
