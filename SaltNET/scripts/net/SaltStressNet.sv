`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltStressNet
// Description:
//   極限測試(SaltFC Part 12)用的量測頂層,只合成、布局繞線,不模擬,也沒有訓練端的模型:
//   BRAM 用到約 84 顆(xck26 的 144 顆裡假設 60 顆給別的電路)時,4.8 ns 還剩多少餘裕。
//   權重、門檻是 scripts/net/gen_salt_stress_net_mem.py 產生的亂數,網路形狀、位寬也由那支腳本寫進 generics.txt,
//   synth_salt_stress_net.tcl 讀進來帶入這裡的參數。不在 sources_1/new 底下,不加進 Vivado 專案。
//
//   conv1 → conv2 → conv3 → 轉接模組 → FC1 → FC2 → FC3(輸出層)→ 膜電位暫存器。
//   conv 接 conv、FC 接 FC 欄位同名直接接線;conv3 → FC1 經 ConvToFCAdapter 換成 src。
//   FC1、FC2 是隱藏層:fire(SPIKE_OUTPUT = 1)、每顆一個門檻(門檻 BRAM)、不送膜電位。
//   FC3 是輸出層:不 fire、每寫回一列送出膜電位,FCMembraneRegister 存每顆最新的 V̂(同 SaltConvFCNet)。
//   幾何只給網路輸入大小、每層 conv 的 K、S、P、OC,跟每層 FC 的 n_out;各層輸出大小、FC 的 n_in、
//   層與層之間的位寬都在這裡推出來(公式同 SaltConvFCNet)。
//   參數分兩種:每層各自一份的加 CONV1_ ~ CONV3_、FC1_ ~ FC3_ 前綴;整個網路共用的不加前綴。
//
//   檔案照事件的流程由上往下排:
//     1 conv1、「現在」(conv1 最新收進的事件時間,接給每一層)
//     2 conv2
//     3 conv3
//     4 conv3 → FC1 轉接
//     5 FC1
//     6 FC2
//     7 FC3(輸出層)
//     8 膜電位暫存器
//////////////////////////////////////////////////////////////////////////////////

module SaltStressNet #(
	// 網路輸入(conv1 的輸入)
	parameter integer IN_CHANNELS = 2,
	parameter integer IN_ROWS     = 34,
	parameter integer IN_COLS     = 34,

	// conv1
	parameter integer CONV1_OUT_CHANNELS       = 8,
	parameter integer CONV1_KERNEL_SIZE        = 3,
	parameter integer CONV1_STRIDE             = 2,
	parameter integer CONV1_PADDING            = 1,
	parameter integer CONV1_MEMBRANE_INT_WIDTH = 9,
	parameter integer CONV1_DECAY_TABLE_DEPTH  = 75,
	parameter integer CONV1_FIFO_DEPTH         = 16,
	parameter CONV1_WEIGHT_FILE    = "conv1_weight.mem",
	parameter CONV1_THRESHOLD_FILE = "conv1_threshold.mem",
	parameter CONV1_DECAY_FILE     = "conv1_decay.mem",

	// conv2(輸入就是 conv1 的輸出)
	parameter integer CONV2_OUT_CHANNELS       = 16,
	parameter integer CONV2_KERNEL_SIZE        = 3,
	parameter integer CONV2_STRIDE             = 2,
	parameter integer CONV2_PADDING            = 1,
	parameter integer CONV2_MEMBRANE_INT_WIDTH = 11,
	parameter integer CONV2_DECAY_TABLE_DEPTH  = 75,
	parameter integer CONV2_FIFO_DEPTH         = 16,
	parameter CONV2_WEIGHT_FILE    = "conv2_weight.mem",
	parameter CONV2_THRESHOLD_FILE = "conv2_threshold.mem",
	parameter CONV2_DECAY_FILE     = "conv2_decay.mem",

	// conv3(輸入就是 conv2 的輸出)
	parameter integer CONV3_OUT_CHANNELS       = 16,
	parameter integer CONV3_KERNEL_SIZE        = 3,
	parameter integer CONV3_STRIDE             = 2,
	parameter integer CONV3_PADDING            = 0,
	parameter integer CONV3_MEMBRANE_INT_WIDTH = 11,
	parameter integer CONV3_DECAY_TABLE_DEPTH  = 75,
	parameter integer CONV3_FIFO_DEPTH         = 16,
	parameter CONV3_WEIGHT_FILE    = "conv3_weight.mem",
	parameter CONV3_THRESHOLD_FILE = "conv3_threshold.mem",
	parameter CONV3_DECAY_FILE     = "conv3_decay.mem",

	// FC1(隱藏層,輸入是 conv3 的輸出攤平)
	parameter integer FC1_OUT_NEURONS        = 512,
	parameter integer FC1_NEURONS_PER_ROW    = 4,
	parameter integer FC1_MEMBRANE_INT_WIDTH = 11,
	parameter integer FC1_DECAY_TABLE_DEPTH  = 75,
	parameter integer FC1_FIFO_DEPTH         = 16,
	parameter FC1_WEIGHT_FILE    = "fc1_weight.mem",
	parameter FC1_THRESHOLD_FILE = "fc1_threshold.mem",
	parameter FC1_DECAY_FILE     = "fc1_decay.mem",

	// FC2(隱藏層,輸入是 FC1 的 spike)
	parameter integer FC2_OUT_NEURONS        = 256,
	parameter integer FC2_NEURONS_PER_ROW    = 4,
	parameter integer FC2_MEMBRANE_INT_WIDTH = 11,
	parameter integer FC2_DECAY_TABLE_DEPTH  = 75,
	parameter integer FC2_FIFO_DEPTH         = 16,
	parameter FC2_WEIGHT_FILE    = "fc2_weight.mem",
	parameter FC2_THRESHOLD_FILE = "fc2_threshold.mem",
	parameter FC2_DECAY_FILE     = "fc2_decay.mem",

	// FC3(輸出層,輸入是 FC2 的 spike;不 fire,沒有門檻檔)
	parameter integer FC3_OUT_NEURONS        = 10,
	parameter integer FC3_NEURONS_PER_ROW    = 4,
	parameter integer FC3_MEMBRANE_INT_WIDTH = 11,
	parameter integer FC3_DECAY_TABLE_DEPTH  = 75,
	parameter integer FC3_FIFO_DEPTH         = 16,
	parameter FC3_WEIGHT_FILE = "fc3_weight.mem",
	parameter FC3_DECAY_FILE  = "fc3_decay.mem",

	// 整個網路共用
	parameter integer TIME_WIDTH          = 16,   // 單位:整數 ms
	parameter integer WEIGHT_WIDTH        = 7,    // b
	parameter integer MEMBRANE_FRAC_WIDTH = 0,    // f_V
	parameter integer DECAY_FRAC_WIDTH    = 6,    // f_a
	parameter bit     ROUND               = 1,    // 1:round,0:truncate
	parameter bit     SATURATE            = 1,    // 1:飽和,0:繞回
	parameter integer READ_LATENCY        = 2,    // R
	parameter integer COMPUTE_LATENCY     = 2,    // C
	parameter bit     OVERLAP             = 1,
	parameter bit     STALE_CLEAR         = 0,    // 1:conv 掃描神經元記憶體,太久沒更新的寫 0(時間戳記繞回)
	parameter integer SCAN_CELLS_PER_TICK = 1,    // conv 每個刻度掃幾格

	// 輸出大小:(H_in + 2P - K) / S + 1,跟訓練端相同
	localparam integer CONV1_OUT_ROWS = (IN_ROWS + 2 * CONV1_PADDING - CONV1_KERNEL_SIZE) / CONV1_STRIDE + 1,
	localparam integer CONV1_OUT_COLS = (IN_COLS + 2 * CONV1_PADDING - CONV1_KERNEL_SIZE) / CONV1_STRIDE + 1,
	localparam integer CONV2_OUT_ROWS = (CONV1_OUT_ROWS + 2 * CONV2_PADDING - CONV2_KERNEL_SIZE) / CONV2_STRIDE + 1,
	localparam integer CONV2_OUT_COLS = (CONV1_OUT_COLS + 2 * CONV2_PADDING - CONV2_KERNEL_SIZE) / CONV2_STRIDE + 1,
	localparam integer CONV3_OUT_ROWS = (CONV2_OUT_ROWS + 2 * CONV3_PADDING - CONV3_KERNEL_SIZE) / CONV3_STRIDE + 1,
	localparam integer CONV3_OUT_COLS = (CONV2_OUT_COLS + 2 * CONV3_PADDING - CONV3_KERNEL_SIZE) / CONV3_STRIDE + 1,
	localparam integer FC1_IN_NEURONS = CONV3_OUT_CHANNELS * CONV3_OUT_ROWS * CONV3_OUT_COLS,   // FC1 的 n_in
	localparam integer FC2_IN_NEURONS = FC1_OUT_NEURONS,
	localparam integer FC3_IN_NEURONS = FC2_OUT_NEURONS,

	// 位寬:跟 SaltConv、SaltFC、FCMembraneRegister 的 localparam 同一套公式
	localparam integer IN_X_WIDTH          = (IN_COLS > 1) ? $clog2(IN_COLS) : 1,
	localparam integer IN_Y_WIDTH          = (IN_ROWS > 1) ? $clog2(IN_ROWS) : 1,
	localparam integer IN_CHANNEL_WIDTH    = (IN_CHANNELS > 1) ? $clog2(IN_CHANNELS) : 1,
	localparam integer CONV1_X_WIDTH       = (CONV1_OUT_COLS > 1) ? $clog2(CONV1_OUT_COLS) : 1,
	localparam integer CONV1_Y_WIDTH       = (CONV1_OUT_ROWS > 1) ? $clog2(CONV1_OUT_ROWS) : 1,
	localparam integer CONV1_CHANNEL_WIDTH = (CONV1_OUT_CHANNELS > 1) ? $clog2(CONV1_OUT_CHANNELS) : 1,
	localparam integer CONV2_X_WIDTH       = (CONV2_OUT_COLS > 1) ? $clog2(CONV2_OUT_COLS) : 1,
	localparam integer CONV2_Y_WIDTH       = (CONV2_OUT_ROWS > 1) ? $clog2(CONV2_OUT_ROWS) : 1,
	localparam integer CONV2_CHANNEL_WIDTH = (CONV2_OUT_CHANNELS > 1) ? $clog2(CONV2_OUT_CHANNELS) : 1,
	localparam integer CONV3_X_WIDTH       = (CONV3_OUT_COLS > 1) ? $clog2(CONV3_OUT_COLS) : 1,
	localparam integer CONV3_Y_WIDTH       = (CONV3_OUT_ROWS > 1) ? $clog2(CONV3_OUT_ROWS) : 1,
	localparam integer CONV3_CHANNEL_WIDTH = (CONV3_OUT_CHANNELS > 1) ? $clog2(CONV3_OUT_CHANNELS) : 1,
	localparam integer FC1_IN_NEURON_WIDTH = (FC1_IN_NEURONS > 1) ? $clog2(FC1_IN_NEURONS) : 1,
	localparam integer FC1_OUT_NEURON_WIDTH = (FC1_OUT_NEURONS > 1) ? $clog2(FC1_OUT_NEURONS) : 1,   // 也是 FC2 的 src 位寬
	localparam integer FC2_OUT_NEURON_WIDTH = (FC2_OUT_NEURONS > 1) ? $clog2(FC2_OUT_NEURONS) : 1,   // 也是 FC3 的 src 位寬
	localparam integer FC3_OUT_NEURON_WIDTH = (FC3_OUT_NEURONS > 1) ? $clog2(FC3_OUT_NEURONS) : 1,
	localparam integer FC3_MEMBRANE_WIDTH   = FC3_MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH         // FC3 的 w
)(
	input  logic clk,
	input  logic rst_n,   // active-low;in_ready 等 conv1 清完

	// 網路輸入事件(conv1 的輸入)
	input  logic                        in_valid,
	output logic                        in_ready,
	input  logic [IN_X_WIDTH-1:0]       in_x,
	input  logic [IN_Y_WIDTH-1:0]       in_y,
	input  logic [IN_CHANNEL_WIDTH-1:0] in_channel,
	input  logic [TIME_WIDTH-1:0]       in_time,

	// 網路輸出:輸出層每顆最新的 V̂(FCMembraneRegister)
	output logic [FC3_OUT_NEURONS*FC3_MEMBRANE_WIDTH-1:0] membranes,     // 第 i 顆的 V̂ 在第 i*w 到 (i+1)*w-1 位元
	output logic                                          update_done,   // 這一拍 membranes 全是同一筆事件更新完的值
	output logic [TIME_WIDTH-1:0]                         update_time    // 那筆事件的 t;update_done=1 那一拍才有意義
);

	// ===============================================================
	// 1 conv1、「現在」
	// ===============================================================
	// 「現在」:conv1 最新收進的事件時間,每一層都拿來判斷神經元多久沒更新。
	// 跟 conv1 互相依賴(conv1 用它,它看 conv1 的 in_ready),放同一段
	logic [TIME_WIDTH-1:0] current_time;

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			current_time <= '0;
		end else if (in_valid && in_ready) begin
			current_time <= in_time;
		end
	end

	logic                           conv1_out_valid;
	logic                           conv1_out_ready;
	logic [CONV1_X_WIDTH-1:0]       conv1_out_x;
	logic [CONV1_Y_WIDTH-1:0]       conv1_out_y;
	logic [CONV1_CHANNEL_WIDTH-1:0] conv1_out_channel;
	logic [TIME_WIDTH-1:0]          conv1_out_time;

	SaltConv #(
		.X_WIDTH            (IN_X_WIDTH),
		.Y_WIDTH            (IN_Y_WIDTH),
		.IN_CHANNEL_WIDTH   (IN_CHANNEL_WIDTH),
		.IN_CHANNELS        (IN_CHANNELS),
		.OUT_CHANNELS       (CONV1_OUT_CHANNELS),
		.OUT_ROWS           (CONV1_OUT_ROWS),
		.OUT_COLS           (CONV1_OUT_COLS),
		.KERNEL_SIZE        (CONV1_KERNEL_SIZE),
		.STRIDE             (CONV1_STRIDE),
		.PADDING            (CONV1_PADDING),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (CONV1_MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (CONV1_DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.WEIGHT_FILE        (CONV1_WEIGHT_FILE),
		.THRESHOLD_FILE     (CONV1_THRESHOLD_FILE),
		.DECAY_FILE         (CONV1_DECAY_FILE),
		.FIFO_DEPTH         (CONV1_FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP),
		.STALE_CLEAR        (STALE_CLEAR),
		.SCAN_CELLS_PER_TICK(SCAN_CELLS_PER_TICK)
	) conv1 (
		.clk         (clk),
		.rst_n       (rst_n),
		.current_time(current_time),
		.in_valid    (in_valid),
		.in_ready    (in_ready),
		.in_x        (in_x),
		.in_y        (in_y),
		.in_channel  (in_channel),
		.in_time     (in_time),
		.out_valid   (conv1_out_valid),
		.out_ready   (conv1_out_ready),
		.out_x       (conv1_out_x),
		.out_y       (conv1_out_y),
		.out_channel (conv1_out_channel),
		.out_time    (conv1_out_time)
	);

	// ===============================================================
	// 2 conv2
	// ===============================================================
	logic                           conv2_out_valid;
	logic                           conv2_out_ready;
	logic [CONV2_X_WIDTH-1:0]       conv2_out_x;
	logic [CONV2_Y_WIDTH-1:0]       conv2_out_y;
	logic [CONV2_CHANNEL_WIDTH-1:0] conv2_out_channel;
	logic [TIME_WIDTH-1:0]          conv2_out_time;

	SaltConv #(
		.X_WIDTH            (CONV1_X_WIDTH),
		.Y_WIDTH            (CONV1_Y_WIDTH),
		.IN_CHANNEL_WIDTH   (CONV1_CHANNEL_WIDTH),
		.IN_CHANNELS        (CONV1_OUT_CHANNELS),
		.OUT_CHANNELS       (CONV2_OUT_CHANNELS),
		.OUT_ROWS           (CONV2_OUT_ROWS),
		.OUT_COLS           (CONV2_OUT_COLS),
		.KERNEL_SIZE        (CONV2_KERNEL_SIZE),
		.STRIDE             (CONV2_STRIDE),
		.PADDING            (CONV2_PADDING),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (CONV2_MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (CONV2_DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.WEIGHT_FILE        (CONV2_WEIGHT_FILE),
		.THRESHOLD_FILE     (CONV2_THRESHOLD_FILE),
		.DECAY_FILE         (CONV2_DECAY_FILE),
		.FIFO_DEPTH         (CONV2_FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP),
		.STALE_CLEAR        (STALE_CLEAR),
		.SCAN_CELLS_PER_TICK(SCAN_CELLS_PER_TICK)
	) conv2 (
		.clk         (clk),
		.rst_n       (rst_n),
		.current_time(current_time),
		.in_valid    (conv1_out_valid),
		.in_ready    (conv1_out_ready),
		.in_x        (conv1_out_x),
		.in_y        (conv1_out_y),
		.in_channel  (conv1_out_channel),
		.in_time     (conv1_out_time),
		.out_valid   (conv2_out_valid),
		.out_ready   (conv2_out_ready),
		.out_x       (conv2_out_x),
		.out_y       (conv2_out_y),
		.out_channel (conv2_out_channel),
		.out_time    (conv2_out_time)
	);

	// ===============================================================
	// 3 conv3
	// ===============================================================
	logic                           conv3_out_valid;
	logic                           conv3_out_ready;
	logic [CONV3_X_WIDTH-1:0]       conv3_out_x;
	logic [CONV3_Y_WIDTH-1:0]       conv3_out_y;
	logic [CONV3_CHANNEL_WIDTH-1:0] conv3_out_channel;
	logic [TIME_WIDTH-1:0]          conv3_out_time;

	SaltConv #(
		.X_WIDTH            (CONV2_X_WIDTH),
		.Y_WIDTH            (CONV2_Y_WIDTH),
		.IN_CHANNEL_WIDTH   (CONV2_CHANNEL_WIDTH),
		.IN_CHANNELS        (CONV2_OUT_CHANNELS),
		.OUT_CHANNELS       (CONV3_OUT_CHANNELS),
		.OUT_ROWS           (CONV3_OUT_ROWS),
		.OUT_COLS           (CONV3_OUT_COLS),
		.KERNEL_SIZE        (CONV3_KERNEL_SIZE),
		.STRIDE             (CONV3_STRIDE),
		.PADDING            (CONV3_PADDING),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (CONV3_MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (CONV3_DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.WEIGHT_FILE        (CONV3_WEIGHT_FILE),
		.THRESHOLD_FILE     (CONV3_THRESHOLD_FILE),
		.DECAY_FILE         (CONV3_DECAY_FILE),
		.FIFO_DEPTH         (CONV3_FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP),
		.STALE_CLEAR        (STALE_CLEAR),
		.SCAN_CELLS_PER_TICK(SCAN_CELLS_PER_TICK)
	) conv3 (
		.clk         (clk),
		.rst_n       (rst_n),
		.current_time(current_time),
		.in_valid    (conv2_out_valid),
		.in_ready    (conv2_out_ready),
		.in_x        (conv2_out_x),
		.in_y        (conv2_out_y),
		.in_channel  (conv2_out_channel),
		.in_time     (conv2_out_time),
		.out_valid   (conv3_out_valid),
		.out_ready   (conv3_out_ready),
		.out_x       (conv3_out_x),
		.out_y       (conv3_out_y),
		.out_channel (conv3_out_channel),
		.out_time    (conv3_out_time)
	);

	// ===============================================================
	// 4 conv3 → FC1 轉接
	// ===============================================================
	logic                           fc1_in_valid;
	logic                           fc1_in_ready;
	logic [FC1_IN_NEURON_WIDTH-1:0] fc1_in_neuron;   // src
	logic [TIME_WIDTH-1:0]          fc1_in_time;

	ConvToFCAdapter #(
		.IN_CHANNELS(CONV3_OUT_CHANNELS),
		.IN_ROWS    (CONV3_OUT_ROWS),
		.IN_COLS    (CONV3_OUT_COLS),
		.TIME_WIDTH (TIME_WIDTH)
	) conv_to_fc (
		.clk       (clk),
		.rst_n     (rst_n),
		.in_valid  (conv3_out_valid),
		.in_ready  (conv3_out_ready),
		.in_x      (conv3_out_x),
		.in_y      (conv3_out_y),
		.in_channel(conv3_out_channel),
		.in_time   (conv3_out_time),
		.out_valid (fc1_in_valid),
		.out_ready (fc1_in_ready),
		.out_neuron(fc1_in_neuron),
		.out_time  (fc1_in_time)
	);

	// ===============================================================
	// 5 FC1(隱藏層:fire,不送膜電位)
	// ===============================================================
	logic                            fc1_out_valid;
	logic                            fc1_out_ready;
	logic [FC1_OUT_NEURON_WIDTH-1:0] fc1_out_neuron;
	logic [TIME_WIDTH-1:0]           fc1_out_time;

	SaltFC #(
		.IN_NEURONS         (FC1_IN_NEURONS),
		.OUT_NEURONS        (FC1_OUT_NEURONS),
		.NEURONS_PER_ROW    (FC1_NEURONS_PER_ROW),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (FC1_MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (FC1_DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.SHARED_THRESHOLD   (0),
		.SPIKE_OUTPUT       (1),
		.MEMBRANE_OUTPUT    (0),
		.WEIGHT_FILE        (FC1_WEIGHT_FILE),
		.THRESHOLD_FILE     (FC1_THRESHOLD_FILE),
		.DECAY_FILE         (FC1_DECAY_FILE),
		.FIFO_DEPTH         (FC1_FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP)
	) fc1 (
		.clk              (clk),
		.rst_n            (rst_n),
		.current_time     (current_time),
		.in_valid         (fc1_in_valid),
		.in_ready         (fc1_in_ready),
		.in_neuron        (fc1_in_neuron),
		.in_time          (fc1_in_time),
		.out_valid        (fc1_out_valid),
		.out_ready        (fc1_out_ready),
		.out_neuron       (fc1_out_neuron),
		.out_time         (fc1_out_time),
		.membrane_valid   (),
		.membrane_row_base(),
		.membrane_values  (),
		.membrane_time    ()
	);

	// ===============================================================
	// 6 FC2(隱藏層:fire,不送膜電位;FC 接 FC,src 就是 FC1 的 out_neuron)
	// ===============================================================
	logic                            fc2_out_valid;
	logic                            fc2_out_ready;
	logic [FC2_OUT_NEURON_WIDTH-1:0] fc2_out_neuron;
	logic [TIME_WIDTH-1:0]           fc2_out_time;

	SaltFC #(
		.IN_NEURONS         (FC2_IN_NEURONS),
		.OUT_NEURONS        (FC2_OUT_NEURONS),
		.NEURONS_PER_ROW    (FC2_NEURONS_PER_ROW),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (FC2_MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (FC2_DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.SHARED_THRESHOLD   (0),
		.SPIKE_OUTPUT       (1),
		.MEMBRANE_OUTPUT    (0),
		.WEIGHT_FILE        (FC2_WEIGHT_FILE),
		.THRESHOLD_FILE     (FC2_THRESHOLD_FILE),
		.DECAY_FILE         (FC2_DECAY_FILE),
		.FIFO_DEPTH         (FC2_FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP)
	) fc2 (
		.clk              (clk),
		.rst_n            (rst_n),
		.current_time     (current_time),
		.in_valid         (fc1_out_valid),
		.in_ready         (fc1_out_ready),
		.in_neuron        (fc1_out_neuron),
		.in_time          (fc1_out_time),
		.out_valid        (fc2_out_valid),
		.out_ready        (fc2_out_ready),
		.out_neuron       (fc2_out_neuron),
		.out_time         (fc2_out_time),
		.membrane_valid   (),
		.membrane_row_base(),
		.membrane_values  (),
		.membrane_time    ()
	);

	// ===============================================================
	// 7 FC3(輸出層:不 fire,每寫回一列送出膜電位;沒有門檻檔)
	// ===============================================================
	logic                                              membrane_valid;
	logic [FC3_OUT_NEURON_WIDTH-1:0]                   membrane_row_base;
	logic [FC3_NEURONS_PER_ROW*FC3_MEMBRANE_WIDTH-1:0] membrane_values;
	logic [TIME_WIDTH-1:0]                             membrane_time;

	SaltFC #(
		.IN_NEURONS         (FC3_IN_NEURONS),
		.OUT_NEURONS        (FC3_OUT_NEURONS),
		.NEURONS_PER_ROW    (FC3_NEURONS_PER_ROW),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (FC3_MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (FC3_DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.SHARED_THRESHOLD   (0),
		.SPIKE_OUTPUT       (0),
		.MEMBRANE_OUTPUT    (1),
		.WEIGHT_FILE        (FC3_WEIGHT_FILE),
		.DECAY_FILE         (FC3_DECAY_FILE),
		.FIFO_DEPTH         (FC3_FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP)
	) fc3 (
		.clk              (clk),
		.rst_n            (rst_n),
		.current_time     (current_time),
		.in_valid         (fc2_out_valid),
		.in_ready         (fc2_out_ready),
		.in_neuron        (fc2_out_neuron),
		.in_time          (fc2_out_time),
		.out_valid        (),
		.out_ready        (1'b1),
		.out_neuron       (),
		.out_time         (),
		.membrane_valid   (membrane_valid),
		.membrane_row_base(membrane_row_base),
		.membrane_values  (membrane_values),
		.membrane_time    (membrane_time)
	);

	// ===============================================================
	// 8 膜電位暫存器
	// ===============================================================
	FCMembraneRegister #(
		.OUT_NEURONS    (FC3_OUT_NEURONS),
		.NEURONS_PER_ROW(FC3_NEURONS_PER_ROW),
		.MEMBRANE_WIDTH (FC3_MEMBRANE_WIDTH),
		.TIME_WIDTH     (TIME_WIDTH)
	) membrane_register (
		.clk              (clk),
		.rst_n            (rst_n),
		.membrane_valid   (membrane_valid),
		.membrane_row_base(membrane_row_base),
		.membrane_values  (membrane_values),
		.membrane_time    (membrane_time),
		.membranes        (membranes),
		.update_done      (update_done),
		.update_time      (update_time)
	);

endmodule
