`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: StaleScan
// Description:
//   SaltConv 的掃描控制:輪流讀神經元記憶體的每一格,太久沒更新的神經元寫 0,
//   讓時間戳記繞回後算出的 Δt 不會錯(docs/SNN/Todo「待決事項 → 系統整合 → 時間戳記繞回」、「時間處理 → T3」)。
//   這裡只放刻度、掃描位址、讓事件暫停的控制;每個 bank 讀出後判斷要不要清,寫在 SaltConv 每個 bank 的 generate 區塊,
//   寫 0 走 reset 清除那條路徑(NeuronMemory 的 clearing、clear_addr)。所有 bank 同一拍掃同一個位址,一層一份。
//
//   刻度:「現在」(current_time,網路最新收進的事件時間)每跨過一個刻度,掃 CELLS_PER_TICK(N)格、刻度往後加 T。
//     T = max(1, floor(2^(W-2) * N / BANK_DEPTH)),W = TIME_WIDTH;同一格最久隔 P = T * ceil(BANK_DEPTH / N) ms 才再被掃到。
//     「到了沒」看 W 位元減法「現在 - 刻度」的第 W-1 位,0 是到了:兩個都會繞回,直接比大小會錯。
//     一次跨過好幾個刻度就接著補掃,每一格都用當下的「現在」判斷。
//   一格的流程(R = READ_LATENCY):
//     刻度到了 → 擋住事件的讀(scan_hold)→ 等管線位置 1..L 都空(pipeline_empty)→ 所有 bank 讀掃描那一格(scan_read)
//     → R 拍後讀出的是這一格(scan_word_valid,SaltConv 把判斷結果存一級暫存器)→ 下一拍要清的 bank 寫 0(scan_clear)
//     → N 格掃完、刻度沒有再到,就放開事件。每格 R + 2 拍。
//     等管線空:事件已經讀出、還沒寫回的格子可能就是要掃的那一格;位置 L 被 out_ready=0 停住時也要等,
//       停住時讀出第二級起不往後推(SaltConv 的 read_shift_enable = !stall),掃描讀出的資料出不來。
//     寫 0 那一拍事件還不能讀:同一拍讀寫同一格,讀出的值不保證(NeuronMemory)。
//   前提(不成立時會算錯,電路不檢查):輸入至少每 J ms 一筆,J < 2^W - 2^(W-1) - P;輸入的時間不倒退。
//   reset:刻度、掃描位址歸 0;reset 清除神經元記憶體期間(clearing)不掃。
//     reset 後「現在」= 0 剛好在刻度 0,清除結束就掃第 0 格。
//////////////////////////////////////////////////////////////////////////////////

module StaleScan #(
	parameter integer TIME_WIDTH     = 16,     // W,單位:整數 ms
	parameter integer BANK_DEPTH     = 1024,   // 佔位預設值,實際深度由例化端決定(每個 bank 的格數)
	parameter integer CELLS_PER_TICK = 1,      // N,每個刻度掃幾格
	parameter integer READ_LATENCY   = 1,      // R,送讀位址到資料可用的拍數

	// 推導出來的位寬($clog2(1)=0 時至少保留 1 bit)
	localparam integer BANK_ADDR_WIDTH = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1
)(
	input  logic clk,
	input  logic rst_n,   // active-low,非同步觸發、同步釋放

	input  logic                  clearing,         // reset 清除神經元記憶體中,不掃
	input  logic [TIME_WIDTH-1:0] current_time,     // 「現在」
	input  logic                  pipeline_empty,   // 管線位置 1..L 都沒有 o_c

	output logic                       scan_hold,         // 擋住事件的讀:下一個 o_c 不送讀位址、FIFO 不拿
	output logic                       scan_read,         // 這一拍所有 bank 讀 scan_addr
	output logic                       scan_word_valid,   // 這一拍讀出的是 scan_addr 那一格,判斷要不要清
	output logic                       scan_clear,        // 這一拍判斷要清的 bank 把 scan_addr 寫 0
	output logic [BANK_ADDR_WIDTH-1:0] scan_addr          // 正在掃的那一格
);

	localparam integer TICK_INTERVAL_FLOOR = ((2 ** TIME_WIDTH) / 4) * CELLS_PER_TICK / BANK_DEPTH;   // floor(2^(W-2) * N / BANK_DEPTH)
	localparam integer TICK_INTERVAL       = (TICK_INTERVAL_FLOOR > 1) ? TICK_INTERVAL_FLOOR : 1;   // T
	localparam integer SCAN_PERIOD         = TICK_INTERVAL * ((BANK_DEPTH + CELLS_PER_TICK - 1) / CELLS_PER_TICK);   // P
	localparam integer CELL_COUNT_WIDTH    = (CELLS_PER_TICK > 1) ? $clog2(CELLS_PER_TICK) : 1;
	localparam integer READ_WAIT_WIDTH     = (READ_LATENCY > 1) ? $clog2(READ_LATENCY) : 1;

	// 同一格最久隔 P 才再被掃到;P 超過 2^(W-1) 時,年紀可能在兩次掃描之間跨過 2^W,掃描就判斷不到
	initial begin
		if (CELLS_PER_TICK < 1) begin
			$fatal(1, "StaleScan: CELLS_PER_TICK=%0d, at least 1", CELLS_PER_TICK);
		end
		if (READ_LATENCY < 1) begin
			$fatal(1, "StaleScan: READ_LATENCY=%0d, at least 1", READ_LATENCY);
		end
		if (SCAN_PERIOD > 2 ** (TIME_WIDTH - 1)) begin
			$fatal(1, "StaleScan: scan period P=%0d ms > 2^(TIME_WIDTH-1)=%0d (TIME_WIDTH=%0d, BANK_DEPTH=%0d, CELLS_PER_TICK=%0d)",
			       SCAN_PERIOD, 2 ** (TIME_WIDTH - 1), TIME_WIDTH, BANK_DEPTH, CELLS_PER_TICK);
		end
	end

	// 刻度到了沒:「現在 - 刻度」的最高位是 0
	logic [TIME_WIDTH-1:0] next_tick;   // 下一個刻度
	logic [TIME_WIDTH-1:0] time_past_tick;
	logic                  tick_reached;

	assign time_past_tick = current_time - next_tick;
	assign tick_reached   = !time_past_tick[TIME_WIDTH-1];

	// 一格的步驟:不掃 → 等管線空(空了那拍讀)→ 等讀出 → 寫 0
	localparam logic [1:0] PHASE_IDLE       = 2'd0;
	localparam logic [1:0] PHASE_WAIT_EMPTY = 2'd1;
	localparam logic [1:0] PHASE_READ_WAIT  = 2'd2;
	localparam logic [1:0] PHASE_CLEAR      = 2'd3;

	logic [1:0]                  phase;
	logic [READ_WAIT_WIDTH-1:0]  read_wait;    // PHASE_READ_WAIT:還要等幾拍讀出的才是這一格
	logic [CELL_COUNT_WIDTH-1:0] cells_left;   // 這個刻度掃完這一格之後還剩幾格

	assign scan_hold       = (phase != PHASE_IDLE);
	assign scan_read       = (phase == PHASE_WAIT_EMPTY) && pipeline_empty;
	assign scan_word_valid = (phase == PHASE_READ_WAIT) && (read_wait == '0);
	assign scan_clear      = (phase == PHASE_CLEAR);

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			phase      <= PHASE_IDLE;
			read_wait  <= '0;
			cells_left <= '0;
			next_tick  <= '0;
			scan_addr  <= '0;
		end else begin
			case (phase)
				PHASE_IDLE: begin
					// 一個刻度開始:刻度先往後加,掃完這個刻度的最後一格時看的就是下一個刻度
					if (!clearing && tick_reached) begin
						phase      <= PHASE_WAIT_EMPTY;
						cells_left <= CELL_COUNT_WIDTH'(CELLS_PER_TICK - 1);
						next_tick  <= next_tick + TIME_WIDTH'(TICK_INTERVAL);
					end
				end
				PHASE_WAIT_EMPTY: begin
					if (pipeline_empty) begin
						phase     <= PHASE_READ_WAIT;
						read_wait <= READ_WAIT_WIDTH'(READ_LATENCY - 1);
					end
				end
				PHASE_READ_WAIT: begin
					if (read_wait == '0) begin
						phase <= PHASE_CLEAR;
					end else begin
						read_wait <= read_wait - 1'b1;
					end
				end
				PHASE_CLEAR: begin
					scan_addr <= (scan_addr == BANK_ADDR_WIDTH'(BANK_DEPTH - 1)) ? '0 : scan_addr + 1'b1;
					// 管線還是空的,下一格直接讀
					if (cells_left != '0) begin
						phase      <= PHASE_WAIT_EMPTY;
						cells_left <= cells_left - 1'b1;
					end else if (tick_reached) begin
						phase      <= PHASE_WAIT_EMPTY;
						cells_left <= CELL_COUNT_WIDTH'(CELLS_PER_TICK - 1);
						next_tick  <= next_tick + TIME_WIDTH'(TICK_INTERVAL);
					end else begin
						phase <= PHASE_IDLE;
					end
				end
			endcase
		end
	end

endmodule
