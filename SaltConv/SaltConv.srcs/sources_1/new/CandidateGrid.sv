`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: CandidateGrid
// Description:
//   一筆事件在一個 output channel 的全部候選神經元(Conv.md 第 2 節「神經元」),純組合邏輯。
//   y、x 各例化一個 CandidateAxis,兩軸的 BANK_COUNT 組兩兩配對成 BANK_COUNT x BANK_COUNT 組,
//   第 [r_y][r_x] 組就是 bank (r_y, r_x) 的候選,再算出它在 bank 內的位址。
//   valid[r_y][r_x]=0 時,同一組其他輸出的值不保證,上層不能使用。
//   bank 內位址(Conv.md 第 2 節「bank 內部位址」):
//     addr = (o_c * ROW_SLOTS + g_y) * COL_SLOTS + g_x,緊密排列,不補到 2 的次方。
//   每個 bank 一律開 OUT_CHANNELS * ROW_SLOTS * COL_SLOTS 格,邊界不整除時有些 bank 會空幾格。
//////////////////////////////////////////////////////////////////////////////////

module CandidateGrid #(
	parameter integer X_WIDTH      = 9,
	parameter integer Y_WIDTH      = 9,
	parameter integer OUT_CHANNELS = 16,   // OC
	parameter integer OUT_ROWS     = 64,   // H_out
	parameter integer OUT_COLS     = 64,   // W_out
	parameter integer KERNEL_SIZE  = 3,    // K
	parameter integer STRIDE       = 1,    // S
	parameter integer PADDING      = 1,    // P

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	// BANK_COUNT、*_SLOTS、*_WIDTH 跟 CandidateAxis 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer BANK_COUNT        = (KERNEL_SIZE + STRIDE - 1) / STRIDE,           // M = ceil(K/S),每軸的 bank 數
	localparam integer ROW_SLOTS         = (OUT_ROWS + BANK_COUNT - 1) / BANK_COUNT,      // G_y = ceil(H_out/M)
	localparam integer COL_SLOTS         = (OUT_COLS + BANK_COUNT - 1) / BANK_COUNT,      // G_x = ceil(W_out/M)
	localparam integer BANK_DEPTH        = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS,          // 每個 bank 的格數
	localparam integer BANK_ADDR_WIDTH   = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1,
	localparam integer OUT_CHANNEL_WIDTH = (OUT_CHANNELS > 1) ? $clog2(OUT_CHANNELS) : 1,
	localparam integer OUT_Y_WIDTH       = (OUT_ROWS > 1) ? $clog2(OUT_ROWS) : 1,
	localparam integer OUT_X_WIDTH       = (OUT_COLS > 1) ? $clog2(OUT_COLS) : 1,
	localparam integer ROW_OFFSET_WIDTH  = (ROW_SLOTS > 1) ? $clog2(ROW_SLOTS) : 1,
	localparam integer COL_OFFSET_WIDTH  = (COL_SLOTS > 1) ? $clog2(COL_SLOTS) : 1,
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1
)(
	input  logic [Y_WIDTH-1:0]           in_y,                                              // y,事件座標
	input  logic [X_WIDTH-1:0]           in_x,                                              // x,事件座標
	input  logic [OUT_CHANNEL_WIDTH-1:0] out_channel,                                       // o_c,這一拍處理的 output channel

	output logic                         valid     [0:BANK_COUNT-1][0:BANK_COUNT-1],   // 這個 bank 有沒有合法候選
	output logic [BANK_ADDR_WIDTH-1:0]   bank_addr [0:BANK_COUNT-1][0:BANK_COUNT-1],   // 候選在 bank 內的位址
	output logic [OUT_Y_WIDTH-1:0]       out_y     [0:BANK_COUNT-1][0:BANK_COUNT-1],   // o_y
	output logic [OUT_X_WIDTH-1:0]       out_x     [0:BANK_COUNT-1][0:BANK_COUNT-1],   // o_x
	output logic [TAP_WIDTH-1:0]         tap_y     [0:BANK_COUNT-1][0:BANK_COUNT-1],   // k_y
	output logic [TAP_WIDTH-1:0]         tap_x     [0:BANK_COUNT-1][0:BANK_COUNT-1]    // k_x
);

	// y 軸的候選,第 r_y 組是 o_y mod M = r_y 的那個
	logic                        row_valid  [0:BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0]      row_coord  [0:BANK_COUNT-1];   // o_y
	logic [ROW_OFFSET_WIDTH-1:0] row_offset [0:BANK_COUNT-1];   // g_y = floor(o_y/M)
	logic [TAP_WIDTH-1:0]        row_tap    [0:BANK_COUNT-1];   // k_y

	// x 軸的候選,第 r_x 組是 o_x mod M = r_x 的那個
	logic                        col_valid  [0:BANK_COUNT-1];
	logic [OUT_X_WIDTH-1:0]      col_coord  [0:BANK_COUNT-1];   // o_x
	logic [COL_OFFSET_WIDTH-1:0] col_offset [0:BANK_COUNT-1];   // g_x = floor(o_x/M)
	logic [TAP_WIDTH-1:0]        col_tap    [0:BANK_COUNT-1];   // k_x

	CandidateAxis #(
		.KERNEL_SIZE   (KERNEL_SIZE),
		.STRIDE        (STRIDE),
		.PADDING       (PADDING),
		.OUT_SIZE      (OUT_ROWS),
		.IN_COORD_WIDTH(Y_WIDTH)
	) row_axis (
		.in_coord   (in_y),
		.valid      (row_valid),
		.out_coord  (row_coord),
		.bank_offset(row_offset),
		.tap        (row_tap)
	);

	CandidateAxis #(
		.KERNEL_SIZE   (KERNEL_SIZE),
		.STRIDE        (STRIDE),
		.PADDING       (PADDING),
		.OUT_SIZE      (OUT_COLS),
		.IN_COORD_WIDTH(X_WIDTH)
	) col_axis (
		.in_coord   (in_x),
		.valid      (col_valid),
		.out_coord  (col_coord),
		.bank_offset(col_offset),
		.tap        (col_tap)
	);

	always_comb begin
		for (int unsigned row_bank = 0; row_bank < BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < BANK_COUNT; col_bank++) begin
				valid[row_bank][col_bank] = row_valid[row_bank] && col_valid[col_bank];

				// 兩軸都合法時 g_y < ROW_SLOTS、g_x < COL_SLOTS,結果一定小於 BANK_DEPTH,截斷不會丟資料
				bank_addr[row_bank][col_bank] = BANK_ADDR_WIDTH'((out_channel * ROW_SLOTS + row_offset[row_bank]) * COL_SLOTS
				                                                 + col_offset[col_bank]);

				out_y[row_bank][col_bank] = row_coord[row_bank];
				out_x[row_bank][col_bank] = col_coord[col_bank];
				tap_y[row_bank][col_bank] = row_tap[row_bank];
				tap_x[row_bank][col_bank] = col_tap[col_bank];
			end
		end
	end

endmodule
