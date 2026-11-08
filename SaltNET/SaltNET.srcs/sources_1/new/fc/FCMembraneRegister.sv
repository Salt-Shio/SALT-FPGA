`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: FCMembraneRegister
// Description:
//   SaltFC 膜電位輸出後面的暫存器模組(FC.md 第 6 節 ⑥),放在層外,只接在要讀 V̂ 的那一層後面。
//   每顆神經元一格,存最新的 V̂;SaltFC 每送來一列(membrane_valid=1),就把那一列 n_col 格蓋成新值。
//   最後一列空的位置(y*n_col + x >= n_out)沒有格子,那幾段不寫。
//   沒有 ready:一拍寫得完一列,SaltFC 一拍最多送一列,每一拍都收得下。
//
//   一筆輸入事件分 n_row 拍寫完,中間的拍子新舊混在一起。收到最後一列的下一拍拉一拍 update_done,
//   這一拍 membranes 的 n_out 格保證全是同一筆事件更新完的值,update_time 是那筆事件的 t;
//   下一筆事件最快在同一拍就開始寫,下一拍起又會混在一起。要慢慢用的(argmax 逐顆比、送 PS)在這一拍複製一份。
//   n_row = 1 時每一列都是最後一列,每次寫入的下一拍都有 update_done。
//
//   reset 時全部歸 0,跟 SaltFC 清除後的神經元記憶體相同。
//////////////////////////////////////////////////////////////////////////////////

module FCMembraneRegister #(
	parameter integer OUT_NEURONS     = 10,   // n_out
	parameter integer NEURONS_PER_ROW = 4,    // n_col
	parameter integer MEMBRANE_WIDTH  = 14,   // w = i_V + f_V
	parameter integer TIME_WIDTH      = 16,   // 單位:整數 ms

	// 推導出來的位寬($clog2(1)=0 時至少保留 1 bit);ROW_COUNT、OUT_NEURON_WIDTH 跟 SaltFC 的 localparam 同一套公式,
	// port 位寬要對上才能接
	localparam integer ROW_COUNT        = (OUT_NEURONS + NEURONS_PER_ROW - 1) / NEURONS_PER_ROW,   // n_row
	localparam integer OUT_NEURON_WIDTH = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1
)(
	input  logic clk,
	input  logic rst_n,   // active-low,非同步觸發、同步釋放

	// SaltFC 的膜電位輸出,同名接上
	input  logic                                      membrane_valid,
	input  logic [OUT_NEURON_WIDTH-1:0]               membrane_row_base,   // y*n_col
	input  logic [NEURONS_PER_ROW*MEMBRANE_WIDTH-1:0] membrane_values,     // 第 x 行的 V̂_new 在第 x*w 到 (x+1)*w-1 位元
	input  logic [TIME_WIDTH-1:0]                     membrane_time,       // 觸發這次更新的輸入事件時間

	output logic [OUT_NEURONS*MEMBRANE_WIDTH-1:0]     membranes,           // 第 i 顆的 V̂ 在第 i*w 到 (i+1)*w-1 位元
	output logic                                      update_done,         // 這一拍 membranes 全是同一筆事件更新完的值
	output logic [TIME_WIDTH-1:0]                     update_time          // 那筆事件的 t;update_done=1 那一拍才有意義
);

	// 這一拍寫第 y 列:收到的 y*n_col 跟這一列的相同
	logic row_selected [0:ROW_COUNT-1];

	for (genvar row = 0; row < ROW_COUNT; row++) begin : rows
		assign row_selected[row] = membrane_valid && (membrane_row_base == OUT_NEURON_WIDTH'(row * NEURONS_PER_ROW));
	end

	// 每顆一格:第 i 顆在第 i / n_col 列、第 i % n_col 段
	for (genvar neuron = 0; neuron < OUT_NEURONS; neuron++) begin : neurons
		localparam integer ROW    = neuron / NEURONS_PER_ROW;   // y
		localparam integer COLUMN = neuron % NEURONS_PER_ROW;   // x

		always_ff @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				membranes[neuron * MEMBRANE_WIDTH +: MEMBRANE_WIDTH] <= '0;
			end else if (row_selected[ROW]) begin
				membranes[neuron * MEMBRANE_WIDTH +: MEMBRANE_WIDTH] <= membrane_values[COLUMN * MEMBRANE_WIDTH +: MEMBRANE_WIDTH];
			end
		end
	end

	// 一筆更新完:收到最後一列的下一拍,格子已經寫進去
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			update_done <= 1'b0;
			update_time <= '0;
		end else begin
			update_done <= row_selected[ROW_COUNT - 1];
			if (row_selected[ROW_COUNT - 1]) begin
				update_time <= membrane_time;
			end
		end
	end

endmodule
