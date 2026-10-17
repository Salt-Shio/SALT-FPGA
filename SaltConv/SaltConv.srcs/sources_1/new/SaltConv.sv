`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltConv
// Description:
//   事件驅動 Conv 層。設計依據見 docs/SNN/Concept/Layer-RTL/Conv.md。
//   名稱用描述性完整拼字,行尾註解標 Conv.md 的數學符號。
//
//   管線化版(Conv.md 5.3、5.4、5.3 改動四、5.3「OC=1」):一個 o_c 一個 o_c 做,彼此不重疊,
//   讀出的資料就緒那一拍(算的那一拍)就算、寫回,同一拍直接從算出的 s 挑一個送出,送完沒剩就同一拍開始下一個 o_c。
//   一個 o_c 占 max(1, k) 拍(OC = 1 時 max(2, k) 拍),k 是這個 o_c fire 的個數(out_ready 一直是 1 時)。
//
//   兩個 1 bit 暫存器取代無腦版的 IDLE / PROCESS / SENDING:
//     oc_in_progress :有一個 o_c 在做(current_channel、事件暫存器、候選暫存器有意義)。0 就是沒事做,等事件。
//     compute_cycle  :上一拍開始了這個 o_c(送了它的讀位址),這一拍讀出的是它的資料:
//                        算 (s, V̂_new)、寫回合法的候選,SpikeSelect 挑剛算出的 s && valid。
//                      0 時是清剩下的 fire:SpikeSelect 挑 bitmask,不寫回;
//                        這一拍讀出的資料可能已經是下一個 o_c 的,跟候選對不上,算出的結果不用。
//   這一拍做完,這個 o_c 的 fire 都送完了(oc_done),而且下一個 o_c 有東西可做,就開始下一個 o_c(begin_next_oc):
//     候選、o_c、compute_cycle 換成下一個 o_c 的;下一個 o_c 是新事件的 o_c = 0 時,從 FIFO 拿出事件存進事件暫存器。
//   挑出的那個沒送出去(out_ready=0)就不清,留在 bitmask:算的那一拍 out_ready=0,整份 s && valid 存進 bitmask(Conv.md 5.4)。
//   OC = 1 時,算的那一拍一律不算送完:下一個 o_c 是下一筆事件的 o_c = 0,讀、寫可能是同一顆神經元,
//   等這一拍寫回之後才讀(Conv.md 5.3「OC=1」)。
//
//   下一個 o_c 的讀位址不等 oc_done(Conv.md 5.3 改動四):下一個 o_c 是誰只看暫存器,
//     o_c < OC-1 :同一筆事件(事件暫存器)的 o_c + 1
//     否則        :FIFO 最前面那筆事件(EventFIFO 是 FWFT)的 o_c = 0;沒有 o_c 在做時也是
//   候選從拍子一開始就跟算 (s, V̂_new) 同時算。讀取開關目前每拍都開(下一個 o_c 有東西可做就讀):
//   沒開始下一個 o_c 的話,下一拍讀出的資料不用,下一拍再讀一次。
//   下一個 o_c 的神經元在它自己被算之前不會被寫入,早讀、重讀拿到的都是同一個值。
//
//   正在處理的事件存在事件暫存器:換事件那一拍,送出舊事件最後一個 fire 要舊事件的 t,
//   讀位址要新事件的 (x, y, c),FIFO 一次只看得到最前面那一筆。
//
//   反壓:out_ready=0 時送不出去,不清 bit,這個 o_c 就不會送完,不開始下一個 o_c、不從 FIFO 拿事件。
//   in_ready 是 FIFO 的 wr_ready(!full,暫存器)再擋掉清除期間,不看 out_ready;
//   out_valid 只看 oc_in_progress、s、bitmask,不看 out_ready。
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

	// ---------------------------------------------------------------
	// 輸入 FIFO
	// ---------------------------------------------------------------
	logic                        clearing;   // 神經元記憶體還在清 0(NeuronMemoryClear)
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
	// 控制:這個 o_c 做完了沒、下一個 o_c 是誰
	// ---------------------------------------------------------------
	logic [X_WIDTH-1:0]           event_x;   // 事件暫存器:正在處理的事件
	logic [Y_WIDTH-1:0]           event_y;
	logic [IN_CHANNEL_WIDTH-1:0]  event_channel;
	logic [TIME_WIDTH-1:0]        event_time;
	logic [OUT_CHANNEL_WIDTH-1:0] current_channel;   // 這個 o_c

	logic oc_in_progress;      // 有一個 o_c 在做
	logic compute_cycle;       // 這一拍讀出的是這個 o_c 的資料:算、寫回、挑 s
	logic last_channel;        // 這個 o_c 是 OC-1
	logic next_from_fifo;      // 下一個 o_c 是 FIFO 最前面那筆事件的 o_c = 0(只看暫存器)
	logic next_oc_available;   // 下一個 o_c 有東西可做(只看暫存器)
	logic oc_done;             // 這一拍做完,這個 o_c 的 fire 都送完了
	logic begin_next_oc;       // 這一拍開始做下一個 o_c

	assign last_channel      = (current_channel == OUT_CHANNEL_WIDTH'(OUT_CHANNELS - 1));
	assign next_from_fifo    = !oc_in_progress || last_channel; // 沒有 oc 在算了 或是 現在最後一個 channel
	assign next_oc_available = !next_from_fifo || fifo_read_valid; // 拿不拿得到 = 不用從 FIFO 拿(一筆事件的所有 oc 還沒完)，或者 FIFO 有東西(從 FIFO 拿)
	// 沒有 o_c 在做時,FIFO 有事件就開始
	assign begin_next_oc     = (oc_done || !oc_in_progress) && next_oc_available;
	assign take_new_event    = begin_next_oc && next_from_fifo;

	// 下一個 o_c 的讀位址:新事件用 FIFO 最前面那筆、o_c = 0;否則用事件暫存器、o_c + 1
	logic [X_WIDTH-1:0]           read_x;
	logic [Y_WIDTH-1:0]           read_y;
	logic [IN_CHANNEL_WIDTH-1:0]  read_channel;
	logic [OUT_CHANNEL_WIDTH-1:0] read_out_channel;
	logic                         read_enable;   // 讀取開關:下一個 o_c 有東西可做就讀,不等 oc_done

	assign read_x           = next_from_fifo ? fifo_x : event_x;
	assign read_y           = next_from_fifo ? fifo_y : event_y;
	assign read_channel     = next_from_fifo ? fifo_channel : event_channel;
	assign read_out_channel = next_from_fifo ? '0 : OUT_CHANNEL_WIDTH'(current_channel + 1'b1);
	assign read_enable      = next_oc_available;

	// ---------------------------------------------------------------
	// 候選:每拍算下一個 o_c 的,開始下一個 o_c 那一拍存進候選暫存器
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

	// 候選暫存器:這個 o_c 的候選,算的那一拍跟讀出的資料對齊,之後清剩下的 fire 也用這一份
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
	// 權重:每拍讀下一個 o_c 的 (o_c, c),算的那一拍用候選暫存器的 tap 選
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
		.read_enable(read_enable),
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
	// 神經元記憶體與膜電位更新:每個 bank 一份 NeuronMemory + NeuronUpdate
	// 每拍讀下一個 o_c 的,算的那一拍算、寫回合法的候選
	// ---------------------------------------------------------------
	logic [BANK_ADDR_WIDTH-1:0] clear_addr;
	logic                       spike [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	// 所有 bank 同一拍清同一個位址,計數器只有一份
	NeuronMemoryClear #(
		.BANK_DEPTH(BANK_DEPTH)
	) neuron_memory_clear (
		.clk       (clk),
		.rst_n     (rst_n),
		.clearing  (clearing),
		.clear_addr(clear_addr)
	);

	for (genvar row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin : row_banks
		for (genvar col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin : col_banks
			logic signed [MEMBRANE_WIDTH-1:0] membrane;       // 讀出的 V̂
			logic        [TIME_WIDTH-1:0]     last_time;      // 讀出的 t_last
			logic signed [MEMBRANE_WIDTH-1:0] new_membrane;   // 算出的 V̂_new

			NeuronMemory #(
				.BANK_DEPTH    (BANK_DEPTH),
				.MEMBRANE_WIDTH(MEMBRANE_WIDTH),
				.TIME_WIDTH    (TIME_WIDTH)
			) neuron_memory (
				.clk            (clk),
				.clearing       (clearing),
				.clear_addr     (clear_addr),
				// 沒有合法候選的 bank 不讀
				.read_enable    (read_enable && grid_valid[row_bank][col_bank]),
				.read_addr      (grid_bank_addr[row_bank][col_bank]),
				.read_membrane  (membrane),
				.read_last_time (last_time),
				// NeuronUpdate 對不合法的候選也照算,只寫回合法的;不是算的那一拍,讀出的資料跟候選對不上,不寫
				.write_enable   (compute_cycle && candidate_valid[row_bank][col_bank]),
				.write_addr     (candidate_bank_addr[row_bank][col_bank]),
				.write_membrane (new_membrane),
				.write_last_time(event_time)   // t_last,new = t
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
				.DECAY_FILE         (DECAY_FILE)
			) neuron_update (
				.weight_code (weight_code[row_bank][col_bank]),
				.membrane    (membrane),
				.last_time   (last_time),
				.event_time  (event_time),
				.threshold   (thresholds[current_channel]),
				.spike       (spike[row_bank][col_bank]),
				.new_membrane(new_membrane)
			);
		end
	end

	// ---------------------------------------------------------------
	// 送出:算的那一拍挑 s && valid,之後挑 bitmask;挑 (o_y, o_x) 最小的
	// ---------------------------------------------------------------
	logic                   bitmask      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 這個 o_c 之前的拍子沒送出的 fire
	logic                   pending      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 這一拍還沒送出的 fire
	logic                   pending_left [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 這一拍做完剩下的
	logic                   found;
	logic                   selected     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0] selected_y;
	logic [OUT_X_WIDTH-1:0] selected_x;
	logic                   spike_sent;   // 這一拍有一個 fire 交出去

	always_comb begin
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				// 不合法的候選也算出 spike,要先排除
				pending[row_bank][col_bank] = compute_cycle
				                            ? (spike[row_bank][col_bank] && candidate_valid[row_bank][col_bank])
				                            : bitmask[row_bank][col_bank];
			end
		end
	end

	SpikeSelect #(
		.OUT_ROWS   (OUT_ROWS),
		.OUT_COLS   (OUT_COLS),
		.KERNEL_SIZE(KERNEL_SIZE),
		.STRIDE     (STRIDE)
	) spike_select (
		.pending      (pending),
		.out_y        (candidate_out_y),
		.out_x        (candidate_out_x),
		.top_row_bank (candidate_top_row_bank),
		.left_col_bank(candidate_left_col_bank),
		.found        (found),
		.selected     (selected),
		.selected_y   (selected_y),
		.selected_x   (selected_x)
	);

	assign out_valid   = oc_in_progress && found;
	assign out_x       = selected_x;
	assign out_y       = selected_y;
	assign out_channel = current_channel;
	assign out_time    = event_time;
	assign spike_sent  = out_valid && out_ready;

	always_comb begin
		// OC = 1:算的那一拍一律不算送完,下一筆事件的 o_c = 0 等這一拍寫回之後才讀
		oc_done = oc_in_progress && !((OUT_CHANNELS == 1) && compute_cycle); // 先默認這個 oc 完成了(oc_done = 1)，後續掃到有剩才 oc_done = 0
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				pending_left[row_bank][col_bank] = pending[row_bank][col_bank]
				                                && !(spike_sent && selected[row_bank][col_bank]);
				if (pending_left[row_bank][col_bank]) begin
					oc_done = 1'b0;
				end
			end
		end
	end

	// 沒有 o_c 在做時清成 0;reset 期間 oc_in_progress=0,釋放後第一拍就是 0
	always_ff @(posedge clk) begin
		for (int unsigned row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int unsigned col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				bitmask[row_bank][col_bank] <= oc_in_progress && pending_left[row_bank][col_bank];
			end
		end
	end

	// ---------------------------------------------------------------
	// oc_in_progress、compute_cycle、o_c、事件暫存器
	// ---------------------------------------------------------------
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			oc_in_progress <= 1'b0;
			compute_cycle  <= 1'b0;
		end else begin
			compute_cycle <= begin_next_oc;
			if (begin_next_oc) begin
				oc_in_progress <= 1'b1;
			end else if (oc_done) begin
				// 送完了,下一個 o_c 沒東西可做(最後一個 o_c,FIFO 是空的)
				oc_in_progress <= 1'b0;
			end
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
