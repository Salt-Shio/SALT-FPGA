`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltFC
// Description:
//   事件驅動 FC 層。設計依據見 docs/SNN/Concept/Layer-RTL/FC.md(管線:第 5 節)。
//   名稱用描述性完整拼字,行尾註解標 FC.md 的數學符號。
//   SaltFC Part 8 完成(管線、fire 的送出與停住);膜電位輸出還沒寫(Part 9),membrane_* 埠目前沒有驅動。
//
//   n_out 顆神經元照編號逐列排,每列 n_col 顆,一拍處理一列;一筆事件從第 0 列做到第 n_row-1 列。
//   SystemVerilog 不能照 parameter 拿掉 port:SPIKE_OUTPUT = 0 時 spike 輸出埠的 out_valid 固定 0,
//   MEMBRANE_OUTPUT = 0 時膜電位輸出埠的 membrane_valid 固定 0,合成時修剪掉。
//
//   讀位址送出後 READ_LATENCY(R)拍資料才出來;COMPUTE_LATENCY(C)= 2 時計算再分兩級(FC.md 第 5 節 ⑤)。
//   讀位址送出後第 p 拍,這一列在「管線位置 p」(p = 1..L,L = R + C - 1):
//     位置 R 是計算第 1 級(讀出的資料在這一拍出來),位置 L 是計算第 2 級(寫回、送 fire);C = 1 時兩個是同一個。
//   OVERLAP = 0:前一列到位置 L 才送下一列的讀位址,一列占 (L-1) + max(1, k) 拍。
//   OVERLAP = 1:每拍都送下一列的讀位址;位置 L 的列送不完時整條管線停住,一列占 max(1, k) 拍。
//   L = 1(R = C = 1)時兩種是同一個電路。k 是這一列 fire 的個數(out_ready 一直是 1 時)。
//   n_row <= L 時,新事件的第 0 列要等上一筆事件的第 0 列寫回才讀(讀寫衝突,第 5 段)。
//
//   檔案照一筆事件的流程由上往下排:
//     0 共用控制:宣告(第 5 段才算出來,前面就要用)
//     1 事件進來:清除、FIFO、事件暫存器(src, t)、上一筆的 t
//     2 下一列是誰、讀位址
//     3 管線位置 1..L:每個位置一份那一列的 y*n_col、t、t_last
//     4 讀出、算、寫回:權重、V̂、門檻記憶體 + DecayLookup + 每行一份 NeuronUpdate
//     5 送出、做完沒、換不換
//   SaltConv 的第 3 段(下一個 o_c 碰到哪些神經元)這裡沒有:每列固定 n_col 顆,所以段號從管線位置起比 SaltConv 少一。
//   排列規則:變數的宣告跟設定它的邏輯放在同一段;要用到的變數,設定它的那段排在前面。
//   例外只有第 0 段的控制訊號:要等第 5 段整串算完才知道,第 1 段起就要用。
//////////////////////////////////////////////////////////////////////////////////

module SaltFC #(
	// 維度
	parameter integer IN_NEURONS      = 1296,   // n_in,上一層神經元數
	parameter integer OUT_NEURONS     = 10,     // n_out,這一層神經元數
	parameter integer NEURONS_PER_ROW = 4,      // n_col,每列幾顆,也是更新電路份數

	// 時間與資料
	parameter integer TIME_WIDTH          = 16,   // 單位:整數 ms
	parameter integer WEIGHT_WIDTH        = 7,    // b,權重碼位元寬
	parameter integer MEMBRANE_INT_WIDTH  = 14,   // i_V,膜電位暫存器整數位元(含符號位)
	parameter integer MEMBRANE_FRAC_WIDTH = 0,    // f_V,膜電位暫存器小數位元
	parameter integer DECAY_FRAC_WIDTH    = 6,    // f_a,衰減碼小數位元
	parameter integer DECAY_TABLE_DEPTH   = 75,   // Δt_max,衰減表深度

	// 量化行為(兩種都要能合成,由例化端選)
	parameter bit ROUND            = 1,   // 1:round,0:truncate
	parameter bit SATURATE         = 1,   // 1:飽和,0:繞回
	parameter bit SHARED_THRESHOLD = 0,   // 1:整層一個門檻(權重 per-tensor),編譯期常數;0:每顆一個(per-channel),門檻 BRAM

	// 兩個輸出各自的開關(FC.md 第 6 節 ②)
	parameter bit SPIKE_OUTPUT    = 1,   // 1:判斷 fire、送 spike;0:不 fire,沒有門檻 BRAM
	parameter bit MEMBRANE_OUTPUT = 0,   // 1:每寫回一列送出這一列的 V̂_new

	// 訓練出來的資料,用 $readmemh 載入,格式見 FC.md 第 2 節「權重」「門檻」、第 3 節 ①
	// 不寫型別:Vivado 不支援 SystemVerilog string 型別參數,也不支援空字串參數(UG901)
	parameter WEIGHT_FILE    = "weight.mem",      // 權重寬字,位址 y*n_in + src,每字 NEURONS_PER_ROW*WEIGHT_WIDTH bits
	parameter THRESHOLD_FILE = "threshold.mem",   // 門檻寬字,位址 y,每字 NEURONS_PER_ROW*MEMBRANE_WIDTH bits;SHARED_THRESHOLD = 1 時只有一行,MEMBRANE_WIDTH bits;SPIKE_OUTPUT = 0 時不讀
	parameter DECAY_FILE     = "decay.mem",       // 衰減表,位址 Δt-1,每字 DECAY_FRAC_WIDTH bits 無號

	// 輸入 FIFO
	parameter integer FIFO_DEPTH = 16,

	// 管線(FC.md 第 5 節 ⑤、⑦)
	parameter integer READ_LATENCY    = 1,   // R,送讀位址到資料可用的拍數;2 = 開 BRAM 輸出暫存器
	parameter integer COMPUTE_LATENCY = 1,   // C,計算級數:1 或 2(2 = 在第 3 節 ② 之後切開)
	parameter bit     OVERLAP         = 0,   // 1:列跟列重疊,下一列先讀、前一列還在算

	// 推導出來的位寬($clog2(1)=0 時至少保留 1 bit)
	localparam integer MEMBRANE_WIDTH   = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH,   // w
	localparam integer ROW_COUNT        = (OUT_NEURONS + NEURONS_PER_ROW - 1) / NEURONS_PER_ROW,   // n_row
	localparam integer IN_NEURON_WIDTH  = (IN_NEURONS > 1) ? $clog2(IN_NEURONS) : 1,
	localparam integer OUT_NEURON_WIDTH = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1
)(
	input  logic clk,
	input  logic rst_n,   // active-low,同步釋放;釋放後先把神經元記憶體逐位址清 0,清完才拉高 in_ready

	// 輸入事件 (src, t)(分離欄位,valid/ready 握手);FC 接 FC 時接上一層同名的 out_ 欄位
	input  logic                       in_valid,
	output logic                       in_ready,
	input  logic [IN_NEURON_WIDTH-1:0] in_neuron,   // src,上一層送出 spike 的神經元編號
	input  logic [TIME_WIDTH-1:0]      in_time,

	// spike 輸出 (i, t)(分離欄位,valid/ready 握手);SPIKE_OUTPUT = 0 時 out_valid 固定 0
	output logic                        out_valid,
	input  logic                        out_ready,
	output logic [OUT_NEURON_WIDTH-1:0] out_neuron,   // i = y*n_col + x
	output logic [TIME_WIDTH-1:0]       out_time,     // 觸發這次 fire 的輸入事件時間

	// 膜電位輸出(valid/ready 握手),每寫回一列送出一筆;MEMBRANE_OUTPUT = 0 時 membrane_valid 固定 0
	output logic                                       membrane_valid,
	input  logic                                       membrane_ready,
	output logic [OUT_NEURON_WIDTH-1:0]                membrane_row_base,    // y*n_col,這一列第 0 行的神經元編號
	output logic [NEURONS_PER_ROW*MEMBRANE_WIDTH-1:0]  membrane_values,      // 第 x 行的 V̂_new 在第 x*w 到 (x+1)*w-1 位元;最後一列空的位置沒有意義
	output logic [TIME_WIDTH-1:0]                      membrane_time         // 觸發這次更新的輸入事件時間
);

	localparam integer ROW_INDEX_WIDTH     = (ROW_COUNT > 1) ? $clog2(ROW_COUNT) : 1;               // y 的位寬,也是 V̂、門檻記憶體的位址位寬
	localparam integer EVENT_WIDTH         = TIME_WIDTH + IN_NEURON_WIDTH;                          // FIFO 一格 {t, src}
	localparam integer PIPELINE_DEPTH      = READ_LATENCY + COMPUTE_LATENCY - 1;                    // L,計算第 2 級的位置
	localparam integer WEIGHT_WORD_WIDTH   = NEURONS_PER_ROW * WEIGHT_WIDTH;                        // 權重一列 n_col*b
	localparam integer MEMBRANE_WORD_WIDTH = NEURONS_PER_ROW * MEMBRANE_WIDTH;                      // V̂、門檻一列 n_col*w
	localparam integer LAST_ROW_COLUMNS    = OUT_NEURONS - (ROW_COUNT - 1) * NEURONS_PER_ROW;   // 最後一列有幾顆

	// ===============================================================
	// 0 共用控制:第 5 段算,第 1 段起就要用
	// ===============================================================
	logic stall;            // 位置 L 的列這一拍送不完:整條管線停住
	logic read_next_row;    // 這一拍送下一列的讀位址
	logic take_new_event;   // 送的是新事件的第 0 列,從 FIFO 拿出最前面那筆

	// ===============================================================
	// 1 事件進來
	// ===============================================================
	// reset 釋放後先把 V̂ 記憶體清 0;一列一個位址,花 n_row 拍
	logic                       clearing;   // 還在清
	logic [ROW_INDEX_WIDTH-1:0] clear_addr;

	NeuronMemoryClear #(
		.BANK_DEPTH(ROW_COUNT)
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
		.wr_data ({in_time, in_neuron}),
		.rd_valid(fifo_read_valid),
		.rd_ready(take_new_event),
		.rd_data (fifo_read_data)
	);

	// FIFO 最前面那筆
	logic [IN_NEURON_WIDTH-1:0] fifo_src;    // src
	logic [TIME_WIDTH-1:0]      fifo_time;   // t

	assign {fifo_time, fifo_src} = fifo_read_data;

	// 事件暫存器:正在送讀位址的那筆。換事件那一拍,FIFO 最前面已經是下一筆,舊事件的 src 要自己留著
	logic [IN_NEURON_WIDTH-1:0] event_src;   // src

	always_ff @(posedge clk) begin
		if (take_new_event) begin
			event_src <= fifo_src;
		end
	end

	// 兩個時間暫存器:這筆的 t、上一筆的 t(也就是這筆的 t_last,整層共用,FC.md 第 2 節「t_last」)。
	// 換事件時一起往後推一格:新的 t 從 FIFO 來,原本的 t 變成新事件的 t_last。
	// 要 reset:conv 的 t_last 存在神經元記憶體裡跟著清除歸 0,FC 的存在這裡;
	// t_last 的基準是樣本開始,reset 後 event_time = 0,第一筆事件拿到的 t_last 就是 0
	// (管線位置上的列各自帶 t、t_last,見第 3 段)
	logic [TIME_WIDTH-1:0] event_time;        // t
	logic [TIME_WIDTH-1:0] event_last_time;   // t_last,上一筆事件的 t

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			event_time      <= '0;
			event_last_time <= '0;
		end else if (take_new_event) begin
			event_time      <= fifo_time;
			event_last_time <= event_time;
		end
	end

	// ===============================================================
	// 2 下一列是誰、讀位址(下一列是誰只看暫存器和 FIFO;讀取開關見下面)
	// ===============================================================
	// 上一次讀的列、下一列:下一列 = 上一次 + 1(或新事件的第 0 列),讀下一列時 上一次 ← 下一列。
	// y*n_col 跟 y 一起走,用累加不用乘法:下一列加 n_col,新事件歸 0(FC.md 第 4 節 ③)
	logic [ROW_INDEX_WIDTH-1:0]  last_read_row;         // 上一次讀的 y
	logic [OUT_NEURON_WIDTH-1:0] last_read_row_base;    // 上一次讀的 y*n_col
	logic [ROW_INDEX_WIDTH-1:0]  read_row;              // 下一列的 y
	logic [OUT_NEURON_WIDTH-1:0] read_row_base;         // 下一列的 y*n_col

	logic next_from_fifo;       // 下一列是 FIFO 最前面那筆事件的第 0 列
	logic next_row_available;   // 下一列有東西可做

	// 上一次是最後一列:下一列是 FIFO 那筆事件的第 0 列;否則是同一筆事件的下一列
	assign next_from_fifo     = (last_read_row == ROW_INDEX_WIDTH'(ROW_COUNT - 1));
	// 如果下一個不是從 fifo 來 (!next_from_fifo) 說明還在組裡同個事件，可以直接拿來算
	assign next_row_available = !next_from_fifo || fifo_read_valid;

	// 下一列要讀的那筆:新事件用 FIFO 最前面那筆,否則用事件暫存器。
	// t_last 也一樣:新事件的 t_last 是事件暫存器現在的 t(這拍結束才推進 event_last_time),否則是 event_last_time
	logic [IN_NEURON_WIDTH-1:0] read_src;         // src
	logic [TIME_WIDTH-1:0]      read_time;        // t
	logic [TIME_WIDTH-1:0]      read_last_time;   // t_last

	assign read_src    = next_from_fifo ? fifo_src : event_src;
	assign read_time      = next_from_fifo ? fifo_time : event_time;
	assign read_last_time = next_from_fifo ? event_time : event_last_time;
	assign read_row       = next_from_fifo ? '0 : ROW_INDEX_WIDTH'(last_read_row + 1'b1);
	// 最後一列的下一列一定是 next_from_fifo,所以加 n_col 只會落在 0..(n_row-1)*n_col,不會超出位寬
	assign read_row_base  = next_from_fifo ? '0 : OUT_NEURON_WIDTH'(last_read_row_base + NEURONS_PER_ROW);

	// 三顆 BRAM 共用的 enable:讀埠有讀下一列才開;R = 2 的輸出暫存器管線沒停住才開
	logic read_enable;         // BRAM 讀埠
	logic read_shift_enable;   // BRAM 輸出暫存器

	assign read_enable       = read_next_row;
	assign read_shift_enable = !stall;

	// reset 後當成上一次送讀位址的是一筆事件的最後一列,第一列就從 FIFO 拿
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			last_read_row       <= ROW_INDEX_WIDTH'(ROW_COUNT - 1);
			last_read_row_base  <= OUT_NEURON_WIDTH'((ROW_COUNT - 1) * NEURONS_PER_ROW);
		end else if (read_next_row) begin
			last_read_row       <= read_row;
			last_read_row_base  <= read_row_base;
		end
	end

	// ===============================================================
	// 3 管線位置 1..L:讀出的資料 R 拍後才出來,這一列的 y、y*n_col、t、t_last 跟著往後走,在位置 R、L 跟資料對齊
	// ===============================================================
	// 沒停住的拍子整排往後推一格,位置 1 放這一拍讀的列(沒讀就是空的);停住時全部不動。
	// 位置 R 用 t、t_last 算 Δt;位置 L 用其他的:寫回位址 y、空位置遮罩和送出用的 y*n_col、送出的 t。
	// t_last 也要跟著帶(conv 不用,conv 的 t_last 跟 V̂ 一起讀出來):列重疊時,時間暫存器可能已經換成下一筆事件(FC.md 第 5 節 ⑥)
	logic                        pipe_valid     [1:PIPELINE_DEPTH];   // 這個位置有列
	logic [ROW_INDEX_WIDTH-1:0]  pipe_row       [1:PIPELINE_DEPTH];   // y
	logic [OUT_NEURON_WIDTH-1:0] pipe_row_base  [1:PIPELINE_DEPTH];   // y*n_col
	logic [TIME_WIDTH-1:0]       pipe_time      [1:PIPELINE_DEPTH];   // t
	logic [TIME_WIDTH-1:0]       pipe_last_time [1:PIPELINE_DEPTH];   // t_last
	logic                        pipe_held;   // 上一拍停住:每個位置上的列跟上一拍相同

	always_ff @(posedge clk) begin
		if (!stall) begin
			pipe_row[1]       <= read_row;
			pipe_row_base[1]  <= read_row_base;
			pipe_time[1]      <= read_time;
			pipe_last_time[1] <= read_last_time;
			for (int position = 2; position <= PIPELINE_DEPTH; position++) begin
				pipe_row[position]       <= pipe_row[position-1];
				pipe_row_base[position]  <= pipe_row_base[position-1];
				pipe_time[position]      <= pipe_time[position-1];
				pipe_last_time[position] <= pipe_last_time[position-1];
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
				pipe_valid[1] <= read_next_row;
				for (int position = 2; position <= PIPELINE_DEPTH; position++) begin
					pipe_valid[position] <= pipe_valid[position-1];
				end
			end
		end
	end

	// 剛到的那一拍:停住的拍子位置上還是同一列,不算剛到
	logic compute_cycle;   // 位置 L 的列剛到:讀出的資料(C = 2 時是切點暫存器)是它的,算、寫回、挑 s

	assign compute_cycle = pipe_valid[PIPELINE_DEPTH] && !pipe_held;

	// ===============================================================
	// 4 讀出、算、寫回
	// ===============================================================
	// 權重:讀下一列的 (y, src),第 x 段在下面每行的 generate 區塊裡切
	logic [WEIGHT_WORD_WIDTH-1:0] weight_word;

	WeightMemory #(
		.IN_INDEX_WIDTH(IN_NEURON_WIDTH),
		.IN_COUNT      (IN_NEURONS),
		.OUT_COUNT     (ROW_COUNT),
		.WORD_WIDTH    (WEIGHT_WORD_WIDTH),
		.READ_LATENCY  (READ_LATENCY),
		.WEIGHT_FILE   (WEIGHT_FILE)
	) weight_memory (
		.clk         (clk),
		.read_enable (read_enable),
		.shift_enable(read_shift_enable),
		.out_index   (read_row),   // y
		.in_index    (read_src),   // src
		.read_word   (weight_word)
	);

	// V̂:讀下一列;寫位置 L 那一列,只在算的那一拍(最後一列空的位置也照寫,沒有意義)
	logic [MEMBRANE_WORD_WIDTH-1:0] membrane_word;
	logic [MEMBRANE_WORD_WIDTH-1:0] new_membrane_word;

	NeuronMemory #(
		.DEPTH       (ROW_COUNT),
		.WORD_WIDTH  (MEMBRANE_WORD_WIDTH),
		.READ_LATENCY(READ_LATENCY)
	) neuron_memory (
		.clk         (clk),
		.clearing    (clearing),
		.clear_addr  (clear_addr),
		.read_enable (read_enable),
		.shift_enable(read_shift_enable),
		.read_addr   (read_row),
		.read_word   (membrane_word),
		.write_enable(compute_cycle),
		.write_addr  (pipe_row[PIPELINE_DEPTH]),
		.write_word  (new_membrane_word)
	);

	// 門檻:spike 關掉時沒有;整層一個時是常數,每行接同一個;每顆一個時讀門檻 BRAM。
	// 門檻在計算第 2 級(位置 L)才比:C = 2 時比 V̂ 晚一拍讀,那一列到位置 1 才用 pipe_row[1] 讀,R 拍後剛好到位置 L;
	// 位置 1 沒有列、或停住時不讀,讀出暫存器保持。C = 1 時算、比同一拍,跟 V̂ 一起讀
	logic [MEMBRANE_WORD_WIDTH-1:0] threshold_word;

	if (!SPIKE_OUTPUT) begin : no_threshold
		assign threshold_word = '0;
	end else if (SHARED_THRESHOLD) begin : shared_threshold
		logic [MEMBRANE_WIDTH-1:0] layer_threshold [0:0];   // v̂_th

		initial begin
			$readmemh(THRESHOLD_FILE, layer_threshold);
		end

		assign threshold_word = {NEURONS_PER_ROW{layer_threshold[0]}};
	end else begin : threshold_rom
		logic                       threshold_read_enable;
		logic [ROW_INDEX_WIDTH-1:0] threshold_read_addr;

		if (COMPUTE_LATENCY == 2) begin : read_one_cycle_later
			assign threshold_read_enable = pipe_valid[1] && !stall;
			assign threshold_read_addr   = pipe_row[1];
		end else begin : read_with_membrane
			assign threshold_read_enable = read_enable;
			assign threshold_read_addr   = read_row;
		end

		ReadOnlyMemory #(
			.DEPTH       (ROW_COUNT),
			.WORD_WIDTH  (MEMBRANE_WORD_WIDTH),
			.READ_LATENCY(READ_LATENCY),
			.INIT_FILE   (THRESHOLD_FILE)
		) threshold_memory (
			.clk         (clk),
			.read_enable (threshold_read_enable),
			.shift_enable(read_shift_enable),
			.read_addr   (threshold_read_addr),
			.read_word   (threshold_word)
		);
	end

	// 衰減碼:整層共用 t_last,一列只要 1 份,n_col 行共用;用位置 R 那一列自己帶的 t、t_last
	logic [DECAY_FRAC_WIDTH:0] decay_code;   // A

	DecayLookup #(
		.TIME_WIDTH       (TIME_WIDTH),
		.DECAY_FRAC_WIDTH (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH(DECAY_TABLE_DEPTH),
		.DECAY_FILE       (DECAY_FILE)
	) decay_lookup (
		.last_time (pipe_last_time[READ_LATENCY]),
		.event_time(pipe_time[READ_LATENCY]),
		.decay_code(decay_code)
	);

	// 每行一份:切出第 x 段的 q、V̂、門檻,NeuronUpdate,V̂_new 接回寫入的寬字
	logic spike        [0:NEURONS_PER_ROW-1];   // s,最後一列空的位置也會算出來
	logic column_valid [0:NEURONS_PER_ROW-1];   // 位置 L 那一列的第 x 行是真的神經元(y*n_col + x < n_out)

	for (genvar column = 0; column < NEURONS_PER_ROW; column++) begin : columns
		logic signed [WEIGHT_WIDTH-1:0]   weight_code;    // q
		logic signed [MEMBRANE_WIDTH-1:0] membrane;       // V̂
		logic signed [MEMBRANE_WIDTH-1:0] threshold;      // v̂_th
		logic signed [MEMBRANE_WIDTH-1:0] new_membrane;   // V̂_new

		assign weight_code = weight_word[column * WEIGHT_WIDTH +: WEIGHT_WIDTH];
		assign membrane    = membrane_word[column * MEMBRANE_WIDTH +: MEMBRANE_WIDTH];
		assign threshold   = threshold_word[column * MEMBRANE_WIDTH +: MEMBRANE_WIDTH];

		NeuronUpdate #(
			.WEIGHT_WIDTH       (WEIGHT_WIDTH),
			.MEMBRANE_INT_WIDTH (MEMBRANE_INT_WIDTH),
			.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
			.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
			.ROUND              (ROUND),
			.SATURATE           (SATURATE),
			.SPIKE_OUTPUT       (SPIKE_OUTPUT),
			.COMPUTE_LATENCY    (COMPUTE_LATENCY)
		) neuron_update (
			.clk         (clk),
			.decay_code  (decay_code),
			.weight_code (weight_code),
			.membrane    (membrane),
			.threshold   (threshold),   // 計算第 2 級用
			.spike       (spike[column]),
			.new_membrane(new_membrane)
		);

		assign new_membrane_word[column * MEMBRANE_WIDTH +: MEMBRANE_WIDTH] = new_membrane;

		// 前 LAST_ROW_COLUMNS 行每一列都有神經元;後面的行只有最後一列是空的
		if (column < LAST_ROW_COLUMNS) begin : always_valid
			assign column_valid[column] = 1'b1;
		end else begin : empty_in_last_row
			assign column_valid[column] = (pipe_row[PIPELINE_DEPTH] != ROW_INDEX_WIDTH'(ROW_COUNT - 1));
		end
	end

	// ===============================================================
	// 5 送出、做完沒、換不換
	// ===============================================================
	// spike 關掉時不 fire,位置 L 那一列一定一拍送完,管線不會停;spike 輸出埠固定不送
	if (!SPIKE_OUTPUT) begin : no_spike_output
		assign stall      = 1'b0;
		assign out_valid  = 1'b0;
		assign out_neuron = '0;
		assign out_time   = '0;
	end else begin : spike_output
		// fire:這一拍要挑的、挑完剩下的、剩下的存起來下一拍再挑(FC.md 第 4 節 ①、第 5 節 ③④)
		logic [NEURONS_PER_ROW-1:0] pending;        // 這一拍還沒送出的 fire
		logic [NEURONS_PER_ROW-1:0] pending_left;   // 這一拍做完剩下的
		logic [NEURONS_PER_ROW-1:0] bitmask;        // 位置 L 的列之前的拍子沒送出的 fire

		// 算的那一拍挑 s && 真的神經元,之後挑 bitmask
		always_comb begin
			for (int unsigned column = 0; column < NEURONS_PER_ROW; column++) begin
				// 最後一列空的位置也算出 spike,要先排除
				pending[column] = compute_cycle ? (spike[column] && column_valid[column]) : bitmask[column];
			end
		end

		// 挑編號最小的
		logic                        found;
		logic [NEURONS_PER_ROW-1:0]  selected;
		logic [OUT_NEURON_WIDTH-1:0] selected_neuron;

		FCSpikeSelect #(
			.OUT_NEURONS    (OUT_NEURONS),
			.NEURONS_PER_ROW(NEURONS_PER_ROW)
		) spike_select (
			.pending        (pending),
			.row_base       (pipe_row_base[PIPELINE_DEPTH]),   // y*n_col
			.found          (found),
			.selected       (selected),
			.selected_neuron(selected_neuron)
		);

		// 送出;out_valid 不看 out_ready
		logic spike_sent;   // 這一拍有一個 fire 交出去

		assign out_valid  = pipe_valid[PIPELINE_DEPTH] && found;
		assign out_neuron = selected_neuron;
		assign out_time   = pipe_time[PIPELINE_DEPTH];
		assign spike_sent = out_valid && out_ready;

		// 剩下哪些:挑出的那個沒送出去(out_ready=0)就不清,留著;算的那一拍 out_ready=0,整份 s && valid 留下
		assign pending_left = pending & ~(selected & {NEURONS_PER_ROW{spike_sent}});

		// 送完還有沒有剩:有 fire,而且下游不收或不只一個(一拍最多送一個)。
		// 跟挑中哪一個無關,只看個數,不等 FCSpikeSelect,stall 不用跟著 pending_left 那條走
		logic pending_any;        // 這一拍要送的 fire 至少一個
		logic pending_multiple;   // 這一拍要送的 fire 至少兩個
		logic fires_left;         // 這一拍做完還有沒送出的 fire

		always_comb begin
			pending_any      = 1'b0;
			pending_multiple = 1'b0;
			for (int unsigned column = 0; column < NEURONS_PER_ROW; column++) begin
				if (pending[column]) begin
					if (pending_any) begin
						pending_multiple = 1'b1;
					end
					pending_any = 1'b1;
				end
			end
		end

		assign fires_left = pending_any && (!out_ready || pending_multiple);
		assign stall      = pipe_valid[PIPELINE_DEPTH] && fires_left;

		// 位置 L 沒有列時清成 0;reset 期間 pipe_valid=0,釋放後第一拍就是 0
		always_ff @(posedge clk) begin
			bitmask <= pending_left & {NEURONS_PER_ROW{pipe_valid[PIPELINE_DEPTH]}};
		end
	end

	// 不重疊:前一列還在位置 1..L-1 就要等它到位置 L
	logic wait_previous_row;

	if (!OVERLAP) begin : wait_previous_check
		always_comb begin
			wait_previous_row = 1'b0;
			for (int position = 1; position < PIPELINE_DEPTH; position++) begin
				if (pipe_valid[position]) begin
					wait_previous_row = 1'b1;
				end
			end
		end
	end else begin : no_wait_previous
		assign wait_previous_row = 1'b0;
	end

	// 讀寫衝突(n_row <= L):新事件的列跟上一筆事件同一列讀寫同一個位址,兩個要隔 L + 1 步(FC.md 第 5 節 ⑧)。
	// 同一筆事件的列一步接一步送,所以只要比第 0 列:上一筆的第 0 列還在管線裡(位置 1..L)就不送,
	// 位置 L 停住的拍子也算(n_row = 1 時那幾拍其實已經寫回,為了只留一套規則照樣等)
	logic read_conflict;

	if (ROW_COUNT <= PIPELINE_DEPTH) begin : read_conflict_check
		logic zero_row_too_close;   // 上一筆事件的第 0 列跟現在差不到 L + 1 步

		always_comb begin
			zero_row_too_close = 1'b0;
			for (int position = 1; position <= PIPELINE_DEPTH; position++) begin
				if (pipe_valid[position] && pipe_row[position] == '0) begin
					zero_row_too_close = 1'b1;
				end
			end
		end

		assign read_conflict = next_from_fifo && zero_row_too_close;
	end else begin : no_read_conflict
		assign read_conflict = 1'b0;
	end

	// 管線裡前面的列擋住下一列
	logic next_row_blocked;

	assign next_row_blocked = wait_previous_row || read_conflict;

	// 讀不讀下一列:管線沒停住、下一列有東西可做、沒被擋住
	assign read_next_row  = !stall && next_row_available && !next_row_blocked;
	// 下一列是新事件的第 0 列,就把那筆事件從 FIFO 拿走
	assign take_new_event = read_next_row && next_from_fifo;

endmodule
