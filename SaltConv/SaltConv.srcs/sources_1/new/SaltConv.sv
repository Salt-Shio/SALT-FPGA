`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltConv
// Description:
//   事件驅動 Conv 層。設計依據見 docs/SNN/Concept/Layer-RTL/Conv.md(管線化:5.3、5.4),
//   流程圖、狀態圖見 Conv-image/SaltConvDataflow.md、SaltConvControl.md。
//   名稱用描述性完整拼字,行尾註解標 Conv.md 的數學符號。
//
//   讀位址送出後 READ_LATENCY(R)拍資料才出來;COMPUTE_LATENCY(C)= 2 時計算再分兩級(Conv.md 5.5)。
//   讀位址送出後第 p 拍,這個 o_c 在「管線位置 p」(p = 1..L,L = R + C - 1):
//     位置 R 是計算第 1 級(讀出的資料在這一拍出來),位置 L 是計算第 2 級(寫回、送 fire);C = 1 時兩個是同一個。
//   OVERLAP = 0:前一個 o_c 到位置 L 才送下一個 o_c 的讀位址,一個 o_c 占 (L-1) + max(1, k) 拍。
//   OVERLAP = 1:每拍都送下一個 o_c 的讀位址;位置 L 的 o_c 送不完時整條管線停住,一個 o_c 占 max(1, k) 拍。
//   L = 1(R = C = 1)時兩種是同一個電路。k 是這個 o_c fire 的個數(out_ready 一直是 1 時)。
//   OC <= L 時,新事件的 o_c = 0 要等上一筆事件的 o_c = 0 寫回才讀(讀寫衝突,第 6 段)。
//
//   檔案照一筆事件的流程由上往下排:
//     0 共用控制:宣告(第 6 段才算出來,前面就要用)
//     1 事件進來:清除、FIFO、事件暫存器
//     2 下一個 o_c 是誰、讀位址
//     3 下一個 o_c 碰到哪些神經元(CandidateGrid)
//     4 管線位置 1..L:每個位置一份那個 o_c 的候選、t、o_c
//     5 讀出、算、寫回:權重、門檻、NeuronMemory + NeuronUpdate
//     6 送出、做完沒、換不換
//   排列規則:變數的宣告跟設定它的邏輯放在同一段;要用到的變數,設定它的那段排在前面。
//   互相依賴的(例如 last_read_out_channel 和 read_out_channel)放同一段,宣告在段首。
//   例外只有第 0 段的控制訊號:要等第 6 段整串算完才知道,第 1 段起就要用。
//////////////////////////////////////////////////////////////////////////////////

module SaltConv #(
	// 輸入座標/通道位寬
	parameter integer X_WIDTH          = 9,
	parameter integer Y_WIDTH          = 9,
	parameter integer IN_CHANNEL_WIDTH = 4,

	// 維度與幾何
	parameter integer IN_CHANNELS  = 2,    // C
	parameter integer OUT_CHANNELS = 16,   // OC
	parameter integer OUT_ROWS     = 64,   // H_out
	parameter integer OUT_COLS     = 64,   // W_out
	parameter integer KERNEL_SIZE  = 3,    // K
	parameter integer STRIDE       = 1,    // S
	parameter integer PADDING      = 1,    // P

	// 時間與資料
	parameter integer TIME_WIDTH          = 16,   // 單位:整數 ms
	parameter integer WEIGHT_WIDTH        = 7,    // b,權重碼位元寬
	parameter integer MEMBRANE_INT_WIDTH  = 9,    // i_V,膜電位暫存器整數位元(含符號位)
	parameter integer MEMBRANE_FRAC_WIDTH = 0,    // f_V,膜電位暫存器小數位元
	parameter integer DECAY_FRAC_WIDTH    = 6,    // f_a,衰減碼小數位元
	parameter integer DECAY_TABLE_DEPTH   = 75,   // Δt_max,衰減表深度

	// 量化行為(兩種都要能合成,由例化端選)
	parameter bit ROUND    = 1,   // 1:round,0:truncate
	parameter bit SATURATE = 1,   // 1:飽和,0:繞回

	// 訓練出來的資料,用 $readmemh 載入
	// 不寫型別:Vivado 不支援 SystemVerilog string 型別參數,也不支援空字串參數(UG901)
	parameter WEIGHT_FILE    = "weight.mem",      // 權重寬字,位址 (o_c,c),每字 KERNEL_SIZE*KERNEL_SIZE*WEIGHT_WIDTH bits
	parameter THRESHOLD_FILE = "threshold.mem",   // 門檻,位址 o_c,每字 MEMBRANE_WIDTH bits 有號
	parameter DECAY_FILE     = "decay.mem",       // 衰減表,位址 Δt-1,每字 DECAY_FRAC_WIDTH bits 無號

	// 輸入 FIFO
	parameter integer FIFO_DEPTH = 16,

	// 管線(Conv.md 5.5)
	parameter integer READ_LATENCY    = 1,   // R,送讀位址到資料可用的拍數;2 = 開 BRAM 輸出暫存器
	parameter integer COMPUTE_LATENCY = 1,   // C,計算級數:1 或 2(2 = NeuronUpdate 在 ② 之後切開)
	parameter bit     OVERLAP         = 0,   // 1:o_c 重疊,下一個 o_c 先讀、前一個還在算

	// 推導出來的位寬($clog2(1)=0 時至少保留 1 bit)
	localparam integer MEMBRANE_WIDTH    = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH,   // w
	localparam integer OUT_CHANNEL_WIDTH = (OUT_CHANNELS > 1) ? $clog2(OUT_CHANNELS) : 1,
	localparam integer OUT_Y_WIDTH       = (OUT_ROWS > 1) ? $clog2(OUT_ROWS) : 1,
	localparam integer OUT_X_WIDTH       = (OUT_COLS > 1) ? $clog2(OUT_COLS) : 1
)(
	input  logic clk,
	input  logic rst_n,   // active-low,同步釋放;釋放後先把神經元記憶體逐位址清 0,清完才拉高 in_ready

	// 輸入事件(分離欄位,valid/ready 握手)
	input  logic                        in_valid,
	output logic                        in_ready,
	input  logic [X_WIDTH-1:0]          in_x,
	input  logic [Y_WIDTH-1:0]          in_y,
	input  logic [IN_CHANNEL_WIDTH-1:0] in_channel,
	input  logic [TIME_WIDTH-1:0]       in_time,

	// 輸出事件(分離欄位,valid/ready 握手);conv 接 conv 時直接接下一層同名的 in_ 欄位
	output logic                         out_valid,
	input  logic                         out_ready,
	output logic [OUT_X_WIDTH-1:0]       out_x,         // o_x
	output logic [OUT_Y_WIDTH-1:0]       out_y,         // o_y
	output logic [OUT_CHANNEL_WIDTH-1:0] out_channel,   // o_c
	output logic [TIME_WIDTH-1:0]        out_time
);

	// 跟 CandidateGrid 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE;                  // M = ceil(K/S),每軸的 bank 數
	localparam integer ROW_SLOTS         = (OUT_ROWS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;   // G_y
	localparam integer COL_SLOTS         = (OUT_COLS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;   // G_x
	localparam integer BANK_DEPTH        = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS;
	localparam integer BANK_ADDR_WIDTH   = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1;
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1;
	localparam integer BANK_INDEX_WIDTH  = (AXIS_BANK_COUNT > 1) ? $clog2(AXIS_BANK_COUNT) : 1;
	localparam integer KERNEL_WORD_WIDTH = KERNEL_SIZE * KERNEL_SIZE * WEIGHT_WIDTH;
	localparam integer EVENT_WIDTH       = TIME_WIDTH + IN_CHANNEL_WIDTH + Y_WIDTH + X_WIDTH;   // FIFO 一格 {t, c, y, x}
	localparam integer PIPELINE_DEPTH    = READ_LATENCY + COMPUTE_LATENCY - 1;                  // L,計算第 2 級的位置
	// 重疊時停住的拍子,位置 1..L-1 的 o_c 還要用讀出的資料,讀出暫存器要留著;L = 1 時沒有這種位置
	localparam bit     HOLD_READ_ON_STALL = OVERLAP && (PIPELINE_DEPTH > 1);

	// ===============================================================
	// 0 共用控制:第 6 段算,第 1 段起就要用
	// ===============================================================
	logic stall;            // 位置 L 的 o_c 這一拍送不完:整條管線停住
	logic begin_next_oc;    // 這一拍送下一個 o_c 的讀位址
	logic take_new_event;   // 送的是新事件的 o_c = 0,從 FIFO 拿出最前面那筆

	// ===============================================================
	// 1 事件進來
	// ===============================================================
	// reset 釋放後先把神經元記憶體清 0;所有 bank 同一拍清同一個位址,計數器只有一份
	logic                       clearing;   // 還在清
	logic [BANK_ADDR_WIDTH-1:0] clear_addr;

	NeuronMemoryClear #(
		.BANK_DEPTH(BANK_DEPTH)
	) neuron_memory_clear (
		.clk       (clk),
		.rst_n     (rst_n),
		.clearing  (clearing),
		.clear_addr(clear_addr)
	);

	// 輸入 FIFO(FWFT:最前面那筆不用拿走就看得到)
	logic                   fifo_write_ready;
	logic                   fifo_read_valid;
	logic [EVENT_WIDTH-1:0] fifo_read_data;

	// 清除期間不收事件:in_ready 拉 0,wr_valid 也要擋,不然 FIFO 照樣收
	assign in_ready = fifo_write_ready && !clearing;

	EventFIFO #(
		.DATA_WIDTH(EVENT_WIDTH),
		.DEPTH     (FIFO_DEPTH)
	) event_fifo (
		.clk     (clk),
		.rst_n   (rst_n),
		.wr_valid(in_valid && !clearing),
		.wr_ready(fifo_write_ready),
		.wr_data ({in_time, in_channel, in_y, in_x}),
		.rd_valid(fifo_read_valid),
		.rd_ready(take_new_event),
		.rd_data (fifo_read_data)
	);

	// FIFO 最前面那筆
	logic [X_WIDTH-1:0]          fifo_x;
	logic [Y_WIDTH-1:0]          fifo_y;
	logic [IN_CHANNEL_WIDTH-1:0] fifo_channel;
	logic [TIME_WIDTH-1:0]       fifo_time;

	assign {fifo_time, fifo_channel, fifo_y, fifo_x} = fifo_read_data;

	// 事件暫存器:正在送讀位址的那筆。換事件那一拍,FIFO 最前面已經是下一筆,舊事件的 t 和 (x, y, c) 要自己留著
	// (管線位置上的 o_c 各自帶 t,見第 4 段)
	logic [X_WIDTH-1:0]          event_x;
	logic [Y_WIDTH-1:0]          event_y;
	logic [IN_CHANNEL_WIDTH-1:0] event_channel;
	logic [TIME_WIDTH-1:0]       event_time;

	always_ff @(posedge clk) begin
		if (take_new_event) begin
			event_x       <= fifo_x;
			event_y       <= fifo_y;
			event_channel <= fifo_channel;
			event_time    <= fifo_time;
		end
	end

	// ===============================================================
	// 2 下一個 o_c 是誰、讀位址(下一個 o_c 是誰只看暫存器和 FIFO;讀取開關見下面)
	// ===============================================================
	// 上一次送讀位址的 o_c、下一個 o_c:下一個 = 上一次 + 1(或新事件的 0),送讀位址時 上一次 ← 下一個
	logic [OUT_CHANNEL_WIDTH-1:0] last_read_out_channel;
	logic [OUT_CHANNEL_WIDTH-1:0] read_out_channel;

	logic next_from_fifo;      // 下一個 o_c 是 FIFO 最前面那筆事件的 o_c = 0
	logic next_oc_available;   // 下一個 o_c 有東西可做

	// 上一次是 OC-1:下一個是 FIFO 那筆事件的 o_c = 0;否則是同一筆事件的 o_c + 1
	assign next_from_fifo    = (last_read_out_channel == OUT_CHANNEL_WIDTH'(OUT_CHANNELS - 1));
	// 下一個 oc 可不可用看: 是不是同一筆事件的 oc + 1 (!next_from_fifo) 如果不是就看 fifo 拿不拿的了 (fifo_read_valid)
	assign next_oc_available = !next_from_fifo || fifo_read_valid;

	// 下一個 o_c 要讀的那筆:新事件用 FIFO 最前面那筆,否則用事件暫存器
	logic [X_WIDTH-1:0]          read_x;
	logic [Y_WIDTH-1:0]          read_y;
	logic [IN_CHANNEL_WIDTH-1:0] read_channel;
	logic [TIME_WIDTH-1:0]       read_time;

	assign read_x           = next_from_fifo ? fifo_x : event_x;
	assign read_y           = next_from_fifo ? fifo_y : event_y;
	assign read_channel     = next_from_fifo ? fifo_channel : event_channel;
	assign read_time        = next_from_fifo ? fifo_time : event_time;
	assign read_out_channel = next_from_fifo ? '0 : OUT_CHANNEL_WIDTH'(last_read_out_channel + 1'b1);

	// 讀取開關:下一個 o_c 有東西可做就讀。
	// HOLD_READ_ON_STALL:停住的拍子不讀,讀出暫存器(R >= 2 時連輸出暫存器)留著位置 1..L-1 那些 o_c 的資料。
	// 其他設定停住期間讀出的資料沒人用,讀取開關不看 stall(stall 要等第 6 段整串算完)
	logic read_enable;
	logic read_shift_enable;   // 讀出第二級起往後推的開關

	if (HOLD_READ_ON_STALL) begin : hold_read
		assign read_enable       = next_oc_available && !stall;
		assign read_shift_enable = !stall;
	end else begin : no_hold_read
		assign read_enable       = next_oc_available;
		assign read_shift_enable = 1'b1;
	end

	// reset 後當成上一次送讀位址的是一筆事件的最後一個 o_c(OC-1),第一個 o_c 就從 FIFO 拿
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			last_read_out_channel <= OUT_CHANNEL_WIDTH'(OUT_CHANNELS - 1);
		end else if (begin_next_oc) begin
			last_read_out_channel <= read_out_channel;
		end
	end

	// ===============================================================
	// 3 下一個 o_c 碰到哪些神經元
	// ===============================================================
	logic                        grid_valid     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_ADDR_WIDTH-1:0]  grid_bank_addr [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0]      grid_out_y     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_X_WIDTH-1:0]      grid_out_x     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]        grid_tap_y     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]        grid_tap_x     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_INDEX_WIDTH-1:0] grid_top_row_bank;
	logic [BANK_INDEX_WIDTH-1:0] grid_left_col_bank;

	CandidateGrid #(
		.X_WIDTH     (X_WIDTH),
		.Y_WIDTH     (Y_WIDTH),
		.OUT_CHANNELS(OUT_CHANNELS),
		.OUT_ROWS    (OUT_ROWS),
		.OUT_COLS    (OUT_COLS),
		.KERNEL_SIZE (KERNEL_SIZE),
		.STRIDE      (STRIDE),
		.PADDING     (PADDING)
	) candidate_grid (
		.in_y         (read_y),
		.in_x         (read_x),
		.out_channel  (read_out_channel),
		.valid        (grid_valid),
		.bank_addr    (grid_bank_addr),
		.out_y        (grid_out_y),
		.out_x        (grid_out_x),
		.tap_y        (grid_tap_y),
		.tap_x        (grid_tap_x),
		.top_row_bank (grid_top_row_bank),
		.left_col_bank(grid_left_col_bank)
	);

	// ===============================================================
	// 4 管線位置 1..L:讀出的資料 R 拍後才出來,候選、t、o_c 跟著讀位址往後走,在位置 R、L 跟資料對齊
	// ===============================================================
	// 沒停住的拍子整排往後推一格,位置 1 放這一拍送讀位址的 o_c(沒送就是空的);停住時全部不動。
	// 位置 R 用 tap 選權重、t 算 Δt;位置 L 用其他的:寫回、門檻、挑 fire、送出,停住期間清剩下的 fire 也用這一份
	logic                         pipe_valid               [1:PIPELINE_DEPTH];   // 這個位置有 o_c
	logic [OUT_CHANNEL_WIDTH-1:0] pipe_channel             [1:PIPELINE_DEPTH];   // o_c
	logic [TIME_WIDTH-1:0]        pipe_time                [1:PIPELINE_DEPTH];   // t
	logic                         pipe_candidate_valid     [1:PIPELINE_DEPTH][0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_ADDR_WIDTH-1:0]   pipe_bank_addr           [1:PIPELINE_DEPTH][0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0]       pipe_out_y               [1:PIPELINE_DEPTH][0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_X_WIDTH-1:0]       pipe_out_x               [1:PIPELINE_DEPTH][0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]         pipe_tap_y               [1:PIPELINE_DEPTH][0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]         pipe_tap_x               [1:PIPELINE_DEPTH][0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_INDEX_WIDTH-1:0]  pipe_top_row_bank        [1:PIPELINE_DEPTH];
	logic [BANK_INDEX_WIDTH-1:0]  pipe_left_col_bank       [1:PIPELINE_DEPTH];
	logic                         pipe_held;   // 上一拍停住:每個位置上的 o_c 跟上一拍相同

	always_ff @(posedge clk) begin
		if (!stall) begin
			pipe_channel[1]         <= read_out_channel;
			pipe_time[1]            <= read_time;
			pipe_candidate_valid[1] <= grid_valid;
			pipe_bank_addr[1]       <= grid_bank_addr;
			pipe_out_y[1]           <= grid_out_y;
			pipe_out_x[1]           <= grid_out_x;
			pipe_tap_y[1]           <= grid_tap_y;
			pipe_tap_x[1]           <= grid_tap_x;
			pipe_top_row_bank[1]    <= grid_top_row_bank;
			pipe_left_col_bank[1]   <= grid_left_col_bank;
			for (int position = 2; position <= PIPELINE_DEPTH; position++) begin
				pipe_channel[position]         <= pipe_channel[position-1];
				pipe_time[position]            <= pipe_time[position-1];
				pipe_candidate_valid[position] <= pipe_candidate_valid[position-1];
				pipe_bank_addr[position]       <= pipe_bank_addr[position-1];
				pipe_out_y[position]           <= pipe_out_y[position-1];
				pipe_out_x[position]           <= pipe_out_x[position-1];
				pipe_tap_y[position]           <= pipe_tap_y[position-1];
				pipe_tap_x[position]           <= pipe_tap_x[position-1];
				pipe_top_row_bank[position]    <= pipe_top_row_bank[position-1];
				pipe_left_col_bank[position]   <= pipe_left_col_bank[position-1];
			end
		end
	end

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			for (int position = 1; position <= PIPELINE_DEPTH; position++) begin
				pipe_valid[position] <= 1'b0;
			end
			pipe_held <= 1'b0;
		end else begin
			pipe_held <= stall;
			if (!stall) begin
				pipe_valid[1] <= begin_next_oc;
				for (int position = 2; position <= PIPELINE_DEPTH; position++) begin
					pipe_valid[position] <= pipe_valid[position-1];
				end
			end
		end
	end

	// 剛到的那一拍:停住的拍子位置上還是同一個 o_c,不算剛到
	logic compute_cycle;   // 位置 L 的 o_c 剛到:讀出的資料(C = 2 時是切點暫存器)是它的,算、寫回、挑 s
	logic data_cycle;      // 位置 R 的 o_c 剛到:讀出的資料是它的(C = 1 時跟 compute_cycle 相同)

	assign compute_cycle = pipe_valid[PIPELINE_DEPTH] && !pipe_held;
	assign data_cycle    = pipe_valid[READ_LATENCY] && !pipe_held;

	// ===============================================================
	// 5 讀出、算、寫回
	// ===============================================================
	// 權重:讀下一個 o_c 的 (o_c, c),位置 R 用那個 o_c 的 tap 選(C = 2 時選好的權重碼存進切點暫存器)
	logic        [KERNEL_WORD_WIDTH-1:0] kernel_word;
	logic signed [WEIGHT_WIDTH-1:0]      weight_code [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	WeightMemory #(
		.IN_CHANNEL_WIDTH(IN_CHANNEL_WIDTH),
		.IN_CHANNELS     (IN_CHANNELS),
		.OUT_CHANNELS    (OUT_CHANNELS),
		.KERNEL_SIZE     (KERNEL_SIZE),
		.WEIGHT_WIDTH    (WEIGHT_WIDTH),
		.READ_LATENCY    (READ_LATENCY),
		.WEIGHT_FILE     (WEIGHT_FILE)
	) weight_memory (
		.clk        (clk),
		.read_enable (read_enable),
		.shift_enable(read_shift_enable),
		.out_channel(read_out_channel),
		.in_channel (read_channel),
		.kernel_word(kernel_word)
	);

	WeightTapSelect #(
		.KERNEL_SIZE (KERNEL_SIZE),
		.STRIDE      (STRIDE),
		.WEIGHT_WIDTH(WEIGHT_WIDTH)
	) weight_tap_select (
		.kernel_word(kernel_word),
		.tap_y      (pipe_tap_y[READ_LATENCY]),
		.tap_x      (pipe_tap_x[READ_LATENCY]),
		.weight_code(weight_code)
	);

	// 門檻:每個 o_c 一個,載入後是常數,依 o_c 選
	logic signed [MEMBRANE_WIDTH-1:0] thresholds [0:OUT_CHANNELS-1];

	initial begin
		$readmemh(THRESHOLD_FILE, thresholds);
	end

	// 神經元記憶體與膜電位更新:每個 bank 一份 NeuronMemory + NeuronUpdate
	// 讀:下一個 o_c(第 3 段的 grid_*);寫:位置 L 的 o_c(第 4 段的 pipe_*),只在算的那一拍
	logic spike [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	for (genvar row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin : row_banks
		for (genvar col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin : col_banks
			logic signed [MEMBRANE_WIDTH-1:0] membrane;       // 讀出的 V̂
			logic        [TIME_WIDTH-1:0]     last_time;      // 讀出的 t_last
			logic signed [MEMBRANE_WIDTH-1:0] new_membrane;   // 算出的 V̂_new

			NeuronMemory #(
				.BANK_DEPTH    (BANK_DEPTH),
				.MEMBRANE_WIDTH(MEMBRANE_WIDTH),
				.TIME_WIDTH    (TIME_WIDTH),
				.READ_LATENCY  (READ_LATENCY)
			) neuron_memory (
				.clk            (clk),
				.clearing       (clearing),
				.clear_addr     (clear_addr),
				// 沒有合法候選的 bank 不讀
				.read_enable    (read_enable && grid_valid[row_bank][col_bank]),
				.shift_enable   (read_shift_enable),
				.read_addr      (grid_bank_addr[row_bank][col_bank]),
				.read_membrane  (membrane),
				.read_last_time (last_time),
				// NeuronUpdate 對不合法的候選也照算,只寫回合法的;不是算的那一拍,讀出的資料跟候選對不上,不寫
				.write_enable   (compute_cycle && pipe_candidate_valid[PIPELINE_DEPTH][row_bank][col_bank]),
				.write_addr     (pipe_bank_addr[PIPELINE_DEPTH][row_bank][col_bank]),
				.write_membrane (new_membrane),
				.write_last_time(pipe_time[PIPELINE_DEPTH])   // t_last,new = t
			);

			NeuronUpdate #(
				.TIME_WIDTH         (TIME_WIDTH),
				.WEIGHT_WIDTH       (WEIGHT_WIDTH),
				.MEMBRANE_INT_WIDTH (MEMBRANE_INT_WIDTH),
				.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
				.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
				.DECAY_TABLE_DEPTH  (DECAY_TABLE_DEPTH),
				.ROUND              (ROUND),
				.SATURATE           (SATURATE),
				.DECAY_FILE         (DECAY_FILE),
				.COMPUTE_LATENCY    (COMPUTE_LATENCY)
			) neuron_update (
				.clk         (clk),
				.weight_code (weight_code[row_bank][col_bank]),
				.membrane    (membrane),
				.last_time   (last_time),
				.event_time  (pipe_time[READ_LATENCY]),                // 計算第 1 級用
				.threshold   (thresholds[pipe_channel[PIPELINE_DEPTH]]),   // 計算第 2 級用
				.spike       (spike[row_bank][col_bank]),
				.new_membrane(new_membrane)
			);
		end
	end

	// ===============================================================
	// 6 送出、做完沒、換不換
	// ===============================================================
	// fire:這一拍要挑的、挑完剩下的、剩下的存起來下一拍再挑
	logic pending      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 這一拍還沒送出的 fire
	logic pending_left [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 這一拍做完剩下的
	logic bitmask      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 位置 L 的 o_c 之前的拍子沒送出的 fire

	// 算的那一拍挑 s && valid,之後挑 bitmask
	always_comb begin
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				// 不合法的候選也算出 spike,要先排除
				pending[row_bank][col_bank] = compute_cycle
				                            ? (spike[row_bank][col_bank] && pipe_candidate_valid[PIPELINE_DEPTH][row_bank][col_bank])
				                            : bitmask[row_bank][col_bank];
			end
		end
	end

	// 挑 (o_y, o_x) 最小的
	logic                   found;
	logic                   selected [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0] selected_y;
	logic [OUT_X_WIDTH-1:0] selected_x;

	SpikeSelect #(
		.OUT_ROWS   (OUT_ROWS),
		.OUT_COLS   (OUT_COLS),
		.KERNEL_SIZE(KERNEL_SIZE),
		.STRIDE     (STRIDE)
	) spike_select (
		.pending      (pending),
		.out_y        (pipe_out_y[PIPELINE_DEPTH]),
		.out_x        (pipe_out_x[PIPELINE_DEPTH]),
		.top_row_bank (pipe_top_row_bank[PIPELINE_DEPTH]),
		.left_col_bank(pipe_left_col_bank[PIPELINE_DEPTH]),
		.found        (found),
		.selected     (selected),
		.selected_y   (selected_y),
		.selected_x   (selected_x)
	);

	// 送出;out_valid 不看 out_ready
	logic spike_sent;   // 這一拍有一個 fire 交出去

	assign out_valid   = pipe_valid[PIPELINE_DEPTH] && found;
	assign out_x       = selected_x;
	assign out_y       = selected_y;
	assign out_channel = pipe_channel[PIPELINE_DEPTH];
	assign out_time    = pipe_time[PIPELINE_DEPTH];
	assign spike_sent  = out_valid && out_ready;

	// 剩下哪些:挑出的那個沒送出去(out_ready=0)就不清,留著;算的那一拍 out_ready=0,整份 s && valid 留下
	always_comb begin
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				pending_left[row_bank][col_bank] = pending[row_bank][col_bank]
				                                && !(spike_sent && selected[row_bank][col_bank]);
			end
		end
	end

	// 送完還有沒有剩:有 fire,而且下游不收或不只一個(一拍最多送一個)。
	// 跟挑中哪一個無關,只看個數,不等 SpikeSelect,stall 不用跟著 pending_left 那條走
	logic pending_any;        // 這一拍要送的 fire 至少一個
	logic pending_multiple;   // 這一拍要送的 fire 至少兩個
	logic fires_left;         // 這一拍做完還有沒送出的 fire

	always_comb begin
		pending_any      = 1'b0;
		pending_multiple = 1'b0;
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				if (pending[row_bank][col_bank]) begin
					if (pending_any) begin
						pending_multiple = 1'b1;
					end
					pending_any = 1'b1;
				end
			end
		end
	end

	assign fires_left = pending_any && (!out_ready || pending_multiple);
	assign stall      = pipe_valid[PIPELINE_DEPTH] && fires_left;

	// 位置 L 沒有 o_c 時清成 0;reset 期間 pipe_valid=0,釋放後第一拍就是 0
	always_ff @(posedge clk) begin
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				bitmask[row_bank][col_bank] <= pipe_valid[PIPELINE_DEPTH] && pending_left[row_bank][col_bank];
			end
		end
	end

	// 不重疊:位置 1..L-1 還有 o_c 時不送(前一個 o_c 到位置 L 才送下一個)
	logic earlier_positions_busy;

	always_comb begin
		earlier_positions_busy = 1'b0;
		for (int position = 1; position < PIPELINE_DEPTH; position++) begin
			if (pipe_valid[position]) begin
				earlier_positions_busy = 1'b1;
			end
		end
	end

	// 讀寫衝突(OC <= L):新事件的 o_c 跟上一筆事件同一個 o_c 讀寫同一批神經元,兩個要隔 L + 1 步(往前一步的拍子)。
	// 同一筆事件的 o_c 一步接一步送,所以只要比 o_c = 0:上一筆的 o_c = 0 還在管線裡(位置 1..L)就不送。
	// OC = 1 時沒有後面的 o_c:位置 L 停住過的已經寫回了,可以送;L = 1 時就是「算的那一拍不送下一筆」(Conv.md 5.3「OC=1」)。
	// OC >= 2 時位置 L 停住過也不送:上一筆的 o_c = 1 不一定停住,會在下一步寫回,新事件的 o_c = 1 不能在那一步讀。
	logic read_conflict;

	if (OUT_CHANNELS <= PIPELINE_DEPTH) begin : read_conflict_check
		logic zero_channel_too_close;   // 上一筆事件的 o_c = 0 跟現在差不到 L + 1 步

		always_comb begin
			if (OUT_CHANNELS == 1) begin
				zero_channel_too_close = compute_cycle;
			end else begin
				zero_channel_too_close = pipe_valid[PIPELINE_DEPTH] && (pipe_channel[PIPELINE_DEPTH] == '0);
			end
			for (int position = 1; position < PIPELINE_DEPTH; position++) begin
				if (pipe_valid[position] && pipe_channel[position] == '0) begin
					zero_channel_too_close = 1'b1;
				end
			end
		end

		assign read_conflict = next_from_fifo && zero_channel_too_close;
	end else begin : no_read_conflict
		assign read_conflict = 1'b0;
	end

	// 送不送下一個 o_c 的讀位址:沒停住、下一個 o_c 有東西可做、沒有讀寫衝突;不重疊時還要等前一個到位置 L
	assign begin_next_oc  = !stall && next_oc_available && !read_conflict && !(!OVERLAP && earlier_positions_busy);
	// 下一個 o_c 是新事件的 o_c = 0,就把那筆事件從 FIFO 拿走
	assign take_new_event = begin_next_oc && next_from_fifo;

endmodule
