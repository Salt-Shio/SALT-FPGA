`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: CandidateAxis
// Description:
//   單軸候選神經元計算(Conv.md 第 2 節「神經元」),純組合邏輯。
//   y、x 兩軸各例化一次,上層再做 BANK_COUNT x BANK_COUNT 配對、組 bank 內位址。
//   第 r 組輸出就是 bank r(out_coord mod BANK_COUNT = r)的候選。
//   valid[r]=0 時,同一組的 out_coord/bank_offset/tap 值不保證,上層不能使用。
//   算法見 Conv.md 第 2 節「每個 bank 的候選怎麼算」:
//   從 o_max 往左找每個 bank 的座標,整筆事件只除以 STRIDE、除以 BANK_COUNT 各一次。
//////////////////////////////////////////////////////////////////////////////////

module CandidateAxis #(
	parameter integer KERNEL_SIZE    = 3,    // K
	parameter integer STRIDE         = 1,    // S
	parameter integer PADDING        = 1,    // P
	parameter integer OUT_SIZE       = 64,   // O_max,這一軸的輸出長度(OUT_ROWS 或 OUT_COLS)
	parameter integer IN_COORD_WIDTH = 9,    // 輸入座標位元寬(Y_WIDTH 或 X_WIDTH)

	// 推導出來的值($clog2(1)=0 時至少保留 1 bit)
	localparam integer BANK_COUNT        = (KERNEL_SIZE + STRIDE - 1) / STRIDE,   // M = ceil(K/S),這一軸的 bank 數,也是候選數上限
	localparam integer BANK_SLOTS        = (OUT_SIZE + BANK_COUNT - 1) / BANK_COUNT,   // ceil(O_max/M),每個 bank 在這一軸上有幾格
	localparam integer OUT_COORD_WIDTH   = (OUT_SIZE > 1) ? $clog2(OUT_SIZE) : 1,
	localparam integer BANK_OFFSET_WIDTH = (BANK_SLOTS > 1) ? $clog2(BANK_SLOTS) : 1,
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1
)(
	input  logic [IN_COORD_WIDTH-1:0]    in_coord,                         // i,事件在這一軸的座標
	output logic                         valid       [0:BANK_COUNT-1],     // 這一組有沒有合法候選
	output logic [OUT_COORD_WIDTH-1:0]   out_coord   [0:BANK_COUNT-1],     // o,候選的輸出座標
	output logic [BANK_OFFSET_WIDTH-1:0] bank_offset [0:BANK_COUNT-1],     // floor(o/M),在 bank 裡的第幾格
	output logic [TAP_WIDTH-1:0]         tap         [0:BANK_COUNT-1]      // k,kernel tap
);

	// 內部運算位寬:涵蓋輸入座標的整個範圍,不只影像內的合法範圍
	localparam integer PADDED_COORD_MAX      = (2 ** IN_COORD_WIDTH - 1) + PADDING;               // i+P 的最大值
	localparam integer PADDED_COORD_WIDTH    = $clog2(PADDED_COORD_MAX + 1);
	localparam integer MAX_OUT_COORD_MAX     = PADDED_COORD_MAX / STRIDE;                          // o_max 的最大值
	localparam integer MAX_OUT_COORD_WIDTH   = (MAX_OUT_COORD_MAX > 0) ? $clog2(MAX_OUT_COORD_MAX + 1) : 1;
	localparam integer MAX_BANK_OFFSET_MAX   = MAX_OUT_COORD_MAX / BANK_COUNT;                      // g_max 的最大值
	localparam integer MAX_BANK_OFFSET_WIDTH = (MAX_BANK_OFFSET_MAX > 0) ? $clog2(MAX_BANK_OFFSET_MAX + 1) : 1;
	localparam integer BANK_INDEX_WIDTH      = (BANK_COUNT > 1) ? $clog2(BANK_COUNT) : 1;           // m、m_max、n_m 都在 0~BANK_COUNT-1

	// 整筆事件算一次
	logic [PADDED_COORD_WIDTH-1:0]    padded_coord;      // i+P
	logic [MAX_OUT_COORD_WIDTH-1:0]   max_out_coord;     // o_max
	logic [BANK_INDEX_WIDTH-1:0]      max_bank;          // m_max = o_max mod M
	logic [MAX_BANK_OFFSET_WIDTH-1:0] max_bank_offset;   // g_max = floor(o_max / M)

	// 每個 bank 各算一份
	logic                             wraps          [0:BANK_COUNT-1];   // 往左走時有沒有繞過 bank 0(m > m_max)
	logic [BANK_INDEX_WIDTH-1:0]      step_count     [0:BANK_COUNT-1];   // n_m,從 o_max 往左走幾步
	logic [MAX_OUT_COORD_WIDTH-1:0]   full_out_coord [0:BANK_COUNT-1];   // o_m,截斷到輸出位寬之前,判斷 o_m < O_max 要用完整值
	logic [PADDED_COORD_WIDTH-1:0]    full_tap       [0:BANK_COUNT-1];   // k_m,截斷到輸出位寬之前,判斷 k_m < K 要用完整值

	always_comb begin
		padded_coord    = PADDED_COORD_WIDTH'(in_coord + PADDING);
		max_out_coord   = MAX_OUT_COORD_WIDTH'(padded_coord / STRIDE);
		max_bank        = BANK_INDEX_WIDTH'(max_out_coord % BANK_COUNT);
		max_bank_offset = MAX_BANK_OFFSET_WIDTH'(max_out_coord / BANK_COUNT);

		for (int unsigned bank = 0; bank < BANK_COUNT; bank++) begin
			wraps[bank] = (bank > max_bank);

			// 不繞:n_m = m_max - m;繞過 bank 0:n_m = m_max - m + M
			step_count[bank] = wraps[bank] ? BANK_INDEX_WIDTH'(max_bank - bank + BANK_COUNT)
			                               : BANK_INDEX_WIDTH'(max_bank - bank);

			full_out_coord[bank] = max_out_coord - step_count[bank];
			full_tap[bank]       = PADDED_COORD_WIDTH'(padded_coord - STRIDE * full_out_coord[bank]);

			// o_m >= 0:只有 g_max = 0 又繞過 bank 0 時才會變負數
			// o_m < O_max:沒超出影像右邊/下邊
			// k_m < K:kernel 蓋得到;k_m >= 0 在 o_m >= 0 時一定成立
			valid[bank] = !(max_bank_offset == 0 && wraps[bank])
			           && (full_out_coord[bank] < OUT_SIZE)
			           && (full_tap[bank] < KERNEL_SIZE);

			out_coord[bank]   = OUT_COORD_WIDTH'(full_out_coord[bank]);
			// g_m:不繞是 g_max,繞過 bank 0 跨進前一輪是 g_max - 1
			bank_offset[bank] = wraps[bank] ? BANK_OFFSET_WIDTH'(max_bank_offset - 1'b1)
			                                : BANK_OFFSET_WIDTH'(max_bank_offset);
			tap[bank]         = TAP_WIDTH'(full_tap[bank]);
		end
	end

endmodule
