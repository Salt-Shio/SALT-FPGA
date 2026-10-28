`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: FCSpikeSelect
// Description:
//   在一列還沒送出的 fire 裡挑編號最小的那一顆(FC.md 第 4 節 ②),純組合邏輯。
//   同一列裡 i = y*n_col + x,x 越小編號越小,所以是固定順序的優先權編碼器:從第 0 行往後找第一個 pending=1。
//   送出的編號 i(第 4 節 ③):row_start(這一列的 y*n_col,上層用跟著這一列帶的值)加上選到的 x。
//     n_col 是 2 的次方時 row_start 的低 log2(n_col) 位一定是 0,直接把 x 接進低位,不用加法;
//     其他 n_col(含 n_col = 1,x 一定是 0)用加法。
//
//   pending 要由上層先處理好:算的那一拍是 s,之後是 bitmask;最後一列空的位置(y*n_col + x >= n_out)遮成 0。
//   bitmask 暫存器、送出交握、t 都由上層處理,這裡只決定這一拍送哪一顆;
//   上層用 selected 清掉送出的那個 bit,下一拍再從第 0 行重新找。
//   found=0 時 selected 全 0,selected_neuron 的值不保證。
//////////////////////////////////////////////////////////////////////////////////

module FCSpikeSelect #(
	parameter integer OUT_NEURONS     = 10,   // n_out
	parameter integer NEURONS_PER_ROW = 4,    // n_col

	// 推導出來的位寬($clog2(1)=0 時至少保留 1 bit);OUT_NEURON_WIDTH 跟 SaltFC 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer OUT_NEURON_WIDTH = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1,
	localparam integer COLUMN_WIDTH     = (NEURONS_PER_ROW > 1) ? $clog2(NEURONS_PER_ROW) : 1
)(
	input  logic [NEURONS_PER_ROW-1:0]  pending,           // 第 x 位元:第 x 行還有 fire 沒送
	input  logic [OUT_NEURON_WIDTH-1:0] row_start,         // y*n_col,這一列第 0 行的神經元編號
	output logic                        found,             // 有沒有東西可以送
	output logic [NEURONS_PER_ROW-1:0]  selected,          // 選中的行,one-hot
	output logic [OUT_NEURON_WIDTH-1:0] selected_neuron    // i = y*n_col + x
);

	logic [COLUMN_WIDTH-1:0] chosen_column;   // x

	// 從第 0 行往後找,第一個 pending=1 的就是編號最小的
	always_comb begin
		found         = 1'b0;
		chosen_column = '0;
		for (int unsigned column = 0; column < NEURONS_PER_ROW; column++) begin
			if (!found && pending[column]) begin
				found         = 1'b1;
				chosen_column = COLUMN_WIDTH'(column);
			end
		end

		for (int unsigned column = 0; column < NEURONS_PER_ROW; column++) begin
			selected[column] = found && (chosen_column == COLUMN_WIDTH'(column));
		end
	end

	// i = y*n_col + x
	localparam bit POWER_OF_TWO_COLUMNS = (NEURONS_PER_ROW > 1) && ((NEURONS_PER_ROW & (NEURONS_PER_ROW - 1)) == 0);

	if (POWER_OF_TWO_COLUMNS && OUT_NEURON_WIDTH > COLUMN_WIDTH) begin : concat_column
		// row_start 的低 COLUMN_WIDTH 位一定是 0,換成 x
		assign selected_neuron = {row_start[OUT_NEURON_WIDTH-1:COLUMN_WIDTH], chosen_column};
	end else if (POWER_OF_TWO_COLUMNS) begin : single_row
		// n_out <= 2^OUT_NEURON_WIDTH <= n_col:只有一列,row_start 一定是 0;x < n_out,截掉的高位是 0
		assign selected_neuron = OUT_NEURON_WIDTH'(chosen_column);
	end else begin : add_column
		// x 只有在 y*n_col + x < n_out 時被選到,和放得進 OUT_NEURON_WIDTH 位
		assign selected_neuron = row_start + OUT_NEURON_WIDTH'(chosen_column);
	end

endmodule
