`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SpikeSelect
// Description:
//   在還沒送出的 fire 裡挑 (o_y, o_x) 最小的那一個(Conv.md 第 4 節),純組合邏輯。
//   先比 o_y 再比 o_x,跟神經元編號 o_y*W_out + o_x 由小到大的順序相同(model_operation_quant.md 第 5 節)。
//
//   窗:一筆事件在一個 o_c 的候選,在輸出面上剛好框住 M x M 格(每軸連續 M 個座標,邊界外的格子不是候選)。
//   bank (r_y, r_x) = (o_y mod M, o_x mod M),窗裡每一格各在不同的 bank。
//   (o_y, o_x) 由小到大,就是把窗由左上往右下讀:上面的列先讀,同一列左邊先讀。
//
//   做法:不比座標,只用窗左上角那格的 bank 推出讀的順序,再照這個順序找第一個 pending=1 的 bank。
//     top_row_bank  = 窗最上面那列的 o_y mod M
//     left_col_bank = 窗最左邊那行的 o_x mod M
//     窗裡第 k 列(最上面是第 0 列)的列編號 = (top_row_bank + k) mod M:往下一列 o_y 加 1,餘數加 1,到 M 變回 0。
//     窗裡第 k 行同理,用 left_col_bank。
//     照「第 0 列第 0 行、第 0 列第 1 行、…、第 M-1 列第 M-1 行」的順序,第一個 pending=1 的就是 (o_y, o_x) 最小的。
//   等於一個優先權編碼器,優先順序由窗左上角的 bank 決定。
//   邊界外的格子不是候選,pending 一定是 0,讀的時候跳過,不影響其他格子的先後。
//
//   pending 要由上層先跟 CandidateGrid 的 valid 做 AND:NeuronUpdate 對不合法的候選也照算 spike。
//   bitmask 暫存器、送出交握、o_c 跟 t 都由上層處理,這裡只決定這一拍送哪一個;
//   上層用 selected 清掉送出的那個 bit,下一拍再從窗的左上角重新讀。
//   top_row_bank、left_col_bank 要小於 M,超出時結果不保證。
//   found=0 時 selected 全 0,selected_y、selected_x 的值不保證。
//////////////////////////////////////////////////////////////////////////////////

module SpikeSelect #(
	parameter integer OUT_ROWS    = 64,   // H_out
	parameter integer OUT_COLS    = 64,   // W_out
	parameter integer KERNEL_SIZE = 3,    // K
	parameter integer STRIDE      = 1,    // S

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	// AXIS_BANK_COUNT、OUT_*_WIDTH 跟 CandidateGrid 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer AXIS_BANK_COUNT  = (KERNEL_SIZE + STRIDE - 1) / STRIDE,   // M = ceil(K/S),每軸的 bank 數
	localparam integer BANK_INDEX_WIDTH = (AXIS_BANK_COUNT > 1) ? $clog2(AXIS_BANK_COUNT) : 1,
	localparam integer OUT_Y_WIDTH      = (OUT_ROWS > 1) ? $clog2(OUT_ROWS) : 1,
	localparam integer OUT_X_WIDTH      = (OUT_COLS > 1) ? $clog2(OUT_COLS) : 1
)(
	input  logic                        pending       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // 這個 bank 還有 fire 沒送
	input  logic [OUT_Y_WIDTH-1:0]      out_y         [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // o_y
	input  logic [OUT_X_WIDTH-1:0]      out_x         [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // o_x
	input  logic [BANK_INDEX_WIDTH-1:0] top_row_bank,                                               // 窗最上面那列的 o_y mod M
	input  logic [BANK_INDEX_WIDTH-1:0] left_col_bank,                                              // 窗最左邊那行的 o_x mod M
	output logic                        found,                                                      // 有沒有東西可以送
	output logic                        selected      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1],   // 選中的 bank,one-hot
	output logic [OUT_Y_WIDTH-1:0]      selected_y,                                                 // 選中那個 bank 的 o_y
	output logic [OUT_X_WIDTH-1:0]      selected_x                                                  // 選中那個 bank 的 o_x
);

	logic [BANK_INDEX_WIDTH-1:0] window_row_bank [0:AXIS_BANK_COUNT-1];   // 窗裡第 k 列的列編號
	logic [BANK_INDEX_WIDTH-1:0] window_col_bank [0:AXIS_BANK_COUNT-1];   // 窗裡第 k 行的行編號
	logic [BANK_INDEX_WIDTH-1:0] chosen_row;
	logic [BANK_INDEX_WIDTH-1:0] chosen_col;

	// (start_bank + offset) mod M:兩者都小於 M,和小於 2M,到 M 以上減一次 M 就好,不用除法
	function automatic logic [BANK_INDEX_WIDTH-1:0] bank_at_offset(input logic [BANK_INDEX_WIDTH-1:0] start_bank,
	                                                              input int unsigned offset);
		logic [BANK_INDEX_WIDTH:0] sum;
		sum = start_bank + offset;
		return (sum >= AXIS_BANK_COUNT) ? BANK_INDEX_WIDTH'(sum - AXIS_BANK_COUNT) : BANK_INDEX_WIDTH'(sum);
	endfunction

	always_comb begin
		for (int unsigned offset = 0; offset < AXIS_BANK_COUNT; offset++) begin
			window_row_bank[offset] = bank_at_offset(top_row_bank, offset);
			window_col_bank[offset] = bank_at_offset(left_col_bank, offset);
		end

		// 由窗的左上往右下讀,第一個 pending=1 的就是 (o_y, o_x) 最小的
		found      = 1'b0;
		chosen_row = '0;
		chosen_col = '0;
		for (int unsigned window_row = 0; window_row < AXIS_BANK_COUNT; window_row++) begin
			for (int unsigned window_col = 0; window_col < AXIS_BANK_COUNT; window_col++) begin
				if (!found && pending[window_row_bank[window_row]][window_col_bank[window_col]]) begin
					found      = 1'b1;
					chosen_row = window_row_bank[window_row];
					chosen_col = window_col_bank[window_col];
				end
			end
		end

		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				selected[row_bank][col_bank] = found
				                            && (chosen_row == BANK_INDEX_WIDTH'(row_bank))
				                            && (chosen_col == BANK_INDEX_WIDTH'(col_bank));
			end
		end
		selected_y = out_y[chosen_row][chosen_col];
		selected_x = out_x[chosen_row][chosen_col];
	end

endmodule
