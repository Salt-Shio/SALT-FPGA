`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: WeightMemory
// Description:
//   權重 ROM(Conv.md 第 2 節「權重」),同步讀取:這一拍送 (o_c, c),READ_LATENCY 拍後 kernel_word 是 q[o_c,c] 的寬字。
//   這裡只算位址;陣列、$readmemh、讀出暫存器在 lib/ReadOnlyMemory(READ_LATENCY、read_enable、shift_enable 的行為見那裡)。
//   位址 o_c * IN_CHANNELS + c,深度 OUT_CHANNELS * IN_CHANNELS,緊密排列,不補到 2 的次方。
//   寬字 KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH bits,tap k_y*K + k_x 從第 (k_y*K + k_x)*WEIGHT_WIDTH bit 起。
//   內容用 $readmemh 從 WEIGHT_FILE 載入,檔案格式見 Conv.md 第 2 節「權重」的「檔案格式」。
//   上層保證 in_channel < IN_CHANNELS、out_channel < OUT_CHANNELS,超出時讀出的值不保證。
//////////////////////////////////////////////////////////////////////////////////

module WeightMemory #(
	parameter integer IN_CHANNEL_WIDTH = 4,
	parameter integer IN_CHANNELS      = 2,    // C
	parameter integer OUT_CHANNELS     = 16,   // OC
	parameter integer KERNEL_SIZE      = 3,    // K
	parameter integer WEIGHT_WIDTH     = 7,    // b
	parameter integer READ_LATENCY     = 1,    // R,送讀位址到資料可用的拍數,至少 1

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
	input  logic                         shift_enable,  // 第二級起往後推的開關(接 BRAM 輸出暫存器的 CE)
	input  logic [OUT_CHANNEL_WIDTH-1:0] out_channel,   // o_c
	input  logic [IN_CHANNEL_WIDTH-1:0]  in_channel,    // c
	output logic [KERNEL_WORD_WIDTH-1:0] kernel_word    // q[o_c,c],read_enable 那拍的 READ_LATENCY 拍後有效
);

	logic [WEIGHT_ADDR_WIDTH-1:0] read_addr;

	// o_c < OUT_CHANNELS、c < IN_CHANNELS 時結果一定小於 WEIGHT_DEPTH,截斷不會丟資料
	assign read_addr = WEIGHT_ADDR_WIDTH'(out_channel * IN_CHANNELS + in_channel);

	ReadOnlyMemory #(
		.DEPTH       (WEIGHT_DEPTH),
		.WORD_WIDTH  (KERNEL_WORD_WIDTH),
		.READ_LATENCY(READ_LATENCY),
		.INIT_FILE   (WEIGHT_FILE)
	) memory_array (
		.clk         (clk),
		.read_enable (read_enable),
		.shift_enable(shift_enable),
		.read_addr   (read_addr),
		.read_word   (kernel_word)
	);

endmodule
