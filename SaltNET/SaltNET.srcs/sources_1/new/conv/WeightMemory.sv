`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: WeightMemory
// Description:
//   權重 ROM(Conv.md 第 2 節「權重」),同步讀取:這一拍送 (o_c, c),READ_LATENCY 拍後 kernel_word 是 q[o_c,c] 的寬字。
//   READ_LATENCY = 2 時第二級是 BRAM 內建的輸出暫存器(DOB_REG),不佔 FF。
//   位址 o_c * IN_CHANNELS + c,深度 OUT_CHANNELS * IN_CHANNELS,緊密排列,不補到 2 的次方。
//   寬字 KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH bits,tap k_y*K + k_x 從第 (k_y*K + k_x)*WEIGHT_WIDTH bit 起。
//   內容用 $readmemh 從 WEIGHT_FILE 載入,檔案格式見 Conv.md 第 2 節「權重」的「檔案格式」。
//   read_enable=0 時第一級保持上一次讀出的值;第二級起 shift_enable=1 才往後推,0 時保持。
//   上層保證 in_channel < IN_CHANNELS、out_channel < OUT_CHANNELS,超出時讀出的值不保證。
//   模組加 keep_hierarchy = "soft"(照 AMD XPM 記憶體模組的做法):上層攤平時,跨模組的最佳化會讓
//   輸出暫存器併不進 BRAM(Synth 8-7052,Vivado 沒有說明原因);soft 只留常數傳遞,其他跨邊界最佳化都擋掉(UG901)。
//   布局時 Vivado 可能把輸出暫存器搬到 BRAM 外面的 FF(BRAM register optimization,時序變好才搬),行為不變。
//////////////////////////////////////////////////////////////////////////////////

(* keep_hierarchy = "soft" *)
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

	// 一律用 BRAM,不交給 Vivado 依大小判斷:各層同一種資源,功耗、用量才能比較
	(* rom_style = "block" *) logic [KERNEL_WORD_WIDTH-1:0] rom [0:WEIGHT_DEPTH-1];
	logic [WEIGHT_ADDR_WIDTH-1:0] read_addr;

	initial begin
		$readmemh(WEIGHT_FILE, rom);
	end

	// o_c < OUT_CHANNELS、c < IN_CHANNELS 時結果一定小於 WEIGHT_DEPTH,截斷不會丟資料
	assign read_addr = WEIGHT_ADDR_WIDTH'(out_channel * IN_CHANNELS + in_channel);

	logic [KERNEL_WORD_WIDTH-1:0] read_stage [0:READ_LATENCY-1];   // [0] 是 BRAM 的讀出暫存器,[1] 是輸出暫存器

	always_ff @(posedge clk) begin
		if (read_enable) begin
			read_stage[0] <= rom[read_addr];
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

	assign kernel_word = read_stage[READ_LATENCY-1];

endmodule
