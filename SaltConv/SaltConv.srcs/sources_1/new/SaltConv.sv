`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltConv
// Description:
//   事件驅動 Conv 層。設計依據見 docs/SNN/Concept/Layer-RTL/Conv.md。
//   名稱用描述性完整拼字,行尾註解標 Conv.md 的數學符號。
//
//   無腦版(Conv.md 5.2、5.7):一個 o_c 一個 o_c 做,彼此不重疊。三個狀態:
//     IDLE    :等事件。FIFO 是空的,什麼都不做;清除神經元記憶體期間不收事件,也停在這裡。
//     PROCESS :讀出的資料就緒,M x M 個候選一起算 (s, V̂_new),合法的候選寫回,s && valid 存進 bitmask。
//     SENDING :bitmask 有 fire 就挑 (o_y, o_x) 最小的送出;out_valid && out_ready 那一拍才清掉那個 bit。
//   送讀位址不是獨立的狀態,在 IDLE 或 SENDING 的最後一拍順便做:
//     IDLE    :FIFO 有事件 -> 開始做新事件的 o_c = 0
//     SENDING :這個 o_c 的 fire 送完了(oc_done)時
//                 o_c < OC-1     -> 開始做同一筆事件的 o_c + 1
//                 否則 FIFO 有事件 -> 開始做新事件的 o_c = 0
//                 否則            -> 回 IDLE
//               還沒送完 -> 留在 SENDING(還有剩,或 out_ready=0 送不出去)
//   一個 o_c 占 PROCESS 1 拍 + SENDING max(1, k) 拍,k 是這個 o_c fire 的個數(out_ready 一直是 1 時)。
//
//   正在處理的事件存在事件暫存器:換事件那一拍,送出舊事件最後一個 fire 要舊事件的 t,
//   讀位址要新事件的 (x, y, c),FIFO 一次只看得到最前面那一筆。
//   這一拍的讀位址直接用 FIFO 最前面那筆(EventFIFO 是 FWFT),拍子結束時存進事件暫存器。
//   送讀位址那一拍 CandidateGrid 算出的候選存進候選暫存器,PROCESS、SENDING 都用這一份,
//   到下一次送讀位址才換:讀出的資料晚 1 拍,候選要跟它對齊;SENDING 最後一拍當拍算出的已經是下一個 o_c 的。
//
//   反壓:out_ready=0 時 SENDING 停在原地,不清 bit、不換 o_c、不送讀位址、不從 FIFO 拿事件。
//   in_ready 是 FIFO 的 wr_ready(!full,暫存器)再擋掉清除期間,不看 out_ready;
//   out_valid 只看狀態跟 bitmask,不看 out_ready。
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

	// 跟 CandidateGrid、NeuronMemory 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE;                  // M = ceil(K/S),每軸的 bank 數
	localparam integer ROW_SLOTS         = (OUT_ROWS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;   // G_y
	localparam integer COL_SLOTS         = (OUT_COLS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;   // G_x
	localparam integer BANK_DEPTH        = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS;
	localparam integer BANK_ADDR_WIDTH   = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1;
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1;
	localparam integer BANK_INDEX_WIDTH  = (AXIS_BANK_COUNT > 1) ? $clog2(AXIS_BANK_COUNT) : 1;
	localparam integer KERNEL_WORD_WIDTH = KERNEL_SIZE * KERNEL_SIZE * WEIGHT_WIDTH;
	localparam integer EVENT_WIDTH       = TIME_WIDTH + IN_CHANNEL_WIDTH + Y_WIDTH + X_WIDTH;   // FIFO 一格 {t, c, y, x}

	typedef enum logic [1:0] {
		IDLE,
		PROCESS,
		SENDING
	} state_t;

	state_t state;

	// ---------------------------------------------------------------
	// 輸入 FIFO
	// ---------------------------------------------------------------
	logic                        clearing;   // NeuronMemory 還在清 0
	logic                        fifo_write_ready;
	logic                        fifo_read_valid;
	logic [EVENT_WIDTH-1:0]      fifo_read_data;
	logic [X_WIDTH-1:0]          fifo_x;
	logic [Y_WIDTH-1:0]          fifo_y;
	logic [IN_CHANNEL_WIDTH-1:0] fifo_channel;
	logic [TIME_WIDTH-1:0]       fifo_time;
	logic                        take_new_event;   // 這一拍開始做新事件的 o_c = 0,從 FIFO 拿出最前面那筆

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

	assign {fifo_time, fifo_channel, fifo_y, fifo_x} = fifo_read_data;

	// ---------------------------------------------------------------
	// 狀態機的控制訊號
	// ---------------------------------------------------------------
	logic [X_WIDTH-1:0]           event_x;   // 事件暫存器:正在處理的事件
	logic [Y_WIDTH-1:0]           event_y;
	logic [IN_CHANNEL_WIDTH-1:0]  event_channel;
	logic [TIME_WIDTH-1:0]        event_time;
	logic [OUT_CHANNEL_WIDTH-1:0] current_channel;   // 這個 o_c

	logic oc_done;         // SENDING:這一拍做完,這個 o_c 的 fire 都送完了
	logic begin_next_oc;   // 這一拍開始做下一個 o_c:送讀位址,下一拍是 PROCESS
	logic last_channel;    // 這個 o_c 是 OC-1

	assign last_channel = (current_channel == OUT_CHANNEL_WIDTH'(OUT_CHANNELS - 1));

	always_comb begin
		begin_next_oc  = 1'b0;
		take_new_event = 1'b0;
		case (state)
			IDLE: begin
				begin_next_oc  = fifo_read_valid;
				take_new_event = fifo_read_valid;
			end
			SENDING: begin
				begin_next_oc  = oc_done && (!last_channel || fifo_read_valid);
				take_new_event = oc_done && last_channel && fifo_read_valid;
			end
			default: ;
		endcase
	end

	// 讀位址的來源:新事件用 FIFO 最前面那筆、o_c = 0;否則用事件暫存器、o_c + 1
	logic [X_WIDTH-1:0]           read_x;
	logic [Y_WIDTH-1:0]           read_y;
	logic [IN_CHANNEL_WIDTH-1:0]  read_channel;
	logic [OUT_CHANNEL_WIDTH-1:0] read_out_channel;

	assign read_x           = take_new_event ? fifo_x : event_x;
	assign read_y           = take_new_event ? fifo_y : event_y;
	assign read_channel     = take_new_event ? fifo_channel : event_channel;
	assign read_out_channel = take_new_event ? '0 : OUT_CHANNEL_WIDTH'(current_channel + 1'b1);

	// ---------------------------------------------------------------
	// 候選:送讀位址那一拍算,存進候選暫存器
	// ---------------------------------------------------------------
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

	// 候選暫存器
	logic                        candidate_valid     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_ADDR_WIDTH-1:0]  candidate_bank_addr [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0]      candidate_out_y     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_X_WIDTH-1:0]      candidate_out_x     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]        candidate_tap_y     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]        candidate_tap_x     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_INDEX_WIDTH-1:0] candidate_top_row_bank;
	logic [BANK_INDEX_WIDTH-1:0] candidate_left_col_bank;

	always_ff @(posedge clk) begin
		if (begin_next_oc) begin
			candidate_valid         <= grid_valid;
			candidate_bank_addr     <= grid_bank_addr;
			candidate_out_y         <= grid_out_y;
			candidate_out_x         <= grid_out_x;
			candidate_tap_y         <= grid_tap_y;
			candidate_tap_x         <= grid_tap_x;
			candidate_top_row_bank  <= grid_top_row_bank;
			candidate_left_col_bank <= grid_left_col_bank;
		end
	end

	// ---------------------------------------------------------------
	// 權重:送讀位址那一拍送 (o_c, c),PROCESS 那一拍用存起來的 tap 選
	// ---------------------------------------------------------------
	logic        [KERNEL_WORD_WIDTH-1:0] kernel_word;
	logic signed [WEIGHT_WIDTH-1:0]      weight_code [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	WeightMemory #(
		.IN_CHANNEL_WIDTH(IN_CHANNEL_WIDTH),
		.IN_CHANNELS     (IN_CHANNELS),
		.OUT_CHANNELS    (OUT_CHANNELS),
		.KERNEL_SIZE     (KERNEL_SIZE),
		.WEIGHT_WIDTH    (WEIGHT_WIDTH),
		.WEIGHT_FILE     (WEIGHT_FILE)
	) weight_memory (
		.clk        (clk),
		.read_enable(begin_next_oc),
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
		.tap_y      (candidate_tap_y),
		.tap_x      (candidate_tap_x),
		.weight_code(weight_code)
	);

	// ---------------------------------------------------------------
	// 門檻:每個 o_c 一個,載入後是常數,依 o_c 選
	// ---------------------------------------------------------------
	logic signed [MEMBRANE_WIDTH-1:0] thresholds [0:OUT_CHANNELS-1];

	initial begin
		$readmemh(THRESHOLD_FILE, thresholds);
	end

	// ---------------------------------------------------------------
	// 神經元記憶體:送讀位址那一拍讀,PROCESS 那一拍寫回合法的候選
	// ---------------------------------------------------------------
	logic                             memory_read_enable   [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic signed [MEMBRANE_WIDTH-1:0] memory_membrane      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [TIME_WIDTH-1:0]     memory_last_time     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic                             memory_write_enable  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [TIME_WIDTH-1:0]     memory_write_time    [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic                             spike                [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic signed [MEMBRANE_WIDTH-1:0] new_membrane         [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	for (genvar row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin : row_banks
		for (genvar col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin : col_banks
			// 沒有合法候選的 bank 不讀
			assign memory_read_enable[row_bank][col_bank]  = begin_next_oc && grid_valid[row_bank][col_bank];
			// NeuronUpdate 對不合法的候選也照算,只寫回合法的
			assign memory_write_enable[row_bank][col_bank] = (state == PROCESS) && candidate_valid[row_bank][col_bank];
			assign memory_write_time[row_bank][col_bank]   = event_time;   // t_last,new = t

			NeuronUpdate #(
				.TIME_WIDTH         (TIME_WIDTH),
				.WEIGHT_WIDTH       (WEIGHT_WIDTH),
				.MEMBRANE_INT_WIDTH (MEMBRANE_INT_WIDTH),
				.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
				.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
				.DECAY_TABLE_DEPTH  (DECAY_TABLE_DEPTH),
				.ROUND              (ROUND),
				.SATURATE           (SATURATE),
				.DECAY_FILE         (DECAY_FILE)
			) neuron_update (
				.weight_code (weight_code[row_bank][col_bank]),
				.membrane    (memory_membrane[row_bank][col_bank]),
				.last_time   (memory_last_time[row_bank][col_bank]),
				.event_time  (event_time),
				.threshold   (thresholds[current_channel]),
				.spike       (spike[row_bank][col_bank]),
				.new_membrane(new_membrane[row_bank][col_bank])
			);
		end
	end

	// reviewer 這裡是否考慮讓 NeuronMemory 變成單一 bank 然後併入上方的 genvar
	NeuronMemory #(
		.OUT_CHANNELS  (OUT_CHANNELS),
		.OUT_ROWS      (OUT_ROWS),
		.OUT_COLS      (OUT_COLS),
		.KERNEL_SIZE   (KERNEL_SIZE),
		.STRIDE        (STRIDE),
		.MEMBRANE_WIDTH(MEMBRANE_WIDTH),
		.TIME_WIDTH    (TIME_WIDTH)
	) neuron_memory (
		.clk            (clk),
		.rst_n          (rst_n),
		.clearing       (clearing),
		.read_enable    (memory_read_enable),
		.read_addr      (grid_bank_addr),
		.read_membrane  (memory_membrane),
		.read_last_time (memory_last_time),
		.write_enable   (memory_write_enable),
		.write_addr     (candidate_bank_addr),
		.write_membrane (new_membrane),
		.write_last_time(memory_write_time)
	);

	// ---------------------------------------------------------------
	// 送出:bitmask 裡挑 (o_y, o_x) 最小的
	// ---------------------------------------------------------------
	logic                   bitmask      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 這個 o_c 還沒送出的 fire
	logic                   bitmask_left [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 這一拍做完剩下的
	logic                   found;
	logic                   selected     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0] selected_y;
	logic [OUT_X_WIDTH-1:0] selected_x;
	logic                   spike_sent;   // 這一拍有一個 fire 交出去

	SpikeSelect #(
		.OUT_ROWS   (OUT_ROWS),
		.OUT_COLS   (OUT_COLS),
		.KERNEL_SIZE(KERNEL_SIZE),
		.STRIDE     (STRIDE)
	) spike_select (
		.pending      (bitmask),
		.out_y        (candidate_out_y),
		.out_x        (candidate_out_x),
		.top_row_bank (candidate_top_row_bank),
		.left_col_bank(candidate_left_col_bank),
		.found        (found),
		.selected     (selected),
		.selected_y   (selected_y),
		.selected_x   (selected_x)
	);

	assign out_valid   = (state == SENDING) && found;
	assign out_x       = selected_x;
	assign out_y       = selected_y;
	assign out_channel = current_channel;
	assign out_time    = event_time;
	assign spike_sent  = out_valid && out_ready;

	always_comb begin
		oc_done = (state == SENDING);
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				bitmask_left[row_bank][col_bank] = bitmask[row_bank][col_bank]
				                                && !(spike_sent && selected[row_bank][col_bank]);
				if (bitmask_left[row_bank][col_bank]) begin
					oc_done = 1'b0;
				end
			end
		end
	end

	always_ff @(posedge clk) begin
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				if (state == PROCESS) begin
					// 不合法的候選也算出 spike,要先排除
					bitmask[row_bank][col_bank] <= spike[row_bank][col_bank] && candidate_valid[row_bank][col_bank];
				end else if (state == SENDING) begin
					bitmask[row_bank][col_bank] <= bitmask_left[row_bank][col_bank];
				end
			end
		end
	end

	// ---------------------------------------------------------------
	// 狀態、o_c、事件暫存器
	// ---------------------------------------------------------------
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state <= IDLE;
		end else begin
			case (state)
				IDLE:    state <= begin_next_oc ? PROCESS : IDLE;
				PROCESS: state <= SENDING;
				SENDING: state <= begin_next_oc ? PROCESS : (oc_done ? IDLE : SENDING);
				default: state <= IDLE;
			endcase
		end
	end

	always_ff @(posedge clk) begin
		if (begin_next_oc) begin
			current_channel <= read_out_channel;
		end
		if (take_new_event) begin
			event_x       <= fifo_x;
			event_y       <= fifo_y;
			event_channel <= fifo_channel;
			event_time    <= fifo_time;
		end
	end

endmodule
