`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: WeightTapSelect
// Description:
//   從一個 kernel 寬字選出每個候選要的權重碼(Conv.md 第 2 節「權重」),純組合邏輯。
//   AXIS_BANK_COUNT x AXIS_BANK_COUNT 個候選共用同一個寬字,第 [r_y][r_x] 個候選用自己的 (k_y, k_x)
//   選出 tap k_y*K + k_x 的權重碼,寬字排列跟 WeightMemory 相同。
//   tap 的位寬是 $clog2(K),K 不是 2 的次方時 tap 可能大於 K-1(這種候選的 valid 一定是 0),
//   這時輸出 0,不去選寬字範圍外的 bit。
//   寬字是 WeightMemory 下一拍才給的,tap 要由上層延遲 1 拍再接進來,這裡不存。
//////////////////////////////////////////////////////////////////////////////////

module WeightTapSelect #(
	parameter integer KERNEL_SIZE  = 3,   // K
	parameter integer STRIDE       = 1,   // S
	parameter integer WEIGHT_WIDTH = 7,   // b

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	// BANK_COUNT、TAP_WIDTH 跟 CandidateGrid 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE,   // M = ceil(K/S)
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1,
	localparam integer KERNEL_WORD_WIDTH = KERNEL_SIZE * KERNEL_SIZE * WEIGHT_WIDTH
)(
	input  logic        [KERNEL_WORD_WIDTH-1:0] kernel_word,                                              // q[o_c,c]
	input  logic        [TAP_WIDTH-1:0]         tap_y       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // k_y
	input  logic        [TAP_WIDTH-1:0]         tap_x       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // k_x
	output logic signed [WEIGHT_WIDTH-1:0]      weight_code [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1]    // q[o_c,c,k_y,k_x]
);

	always_comb begin
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				if (tap_y[row_bank][col_bank] < KERNEL_SIZE && tap_x[row_bank][col_bank] < KERNEL_SIZE) begin
					weight_code[row_bank][col_bank] =
						kernel_word[(tap_y[row_bank][col_bank] * KERNEL_SIZE + tap_x[row_bank][col_bank]) * WEIGHT_WIDTH +: WEIGHT_WIDTH];
				end else begin
					weight_code[row_bank][col_bank] = '0;
				end
			end
		end
	end

endmodule
