`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltConvFCNet
// Description:
//   訓練端整個網路:conv1 → conv2 → 轉接模組 → FC(輸出層)→ 膜電位暫存器。
//   conv1 → conv2:欄位一一對應(o_c → c、o_y → y、o_x → x、t → t,model_operation_quant.md 第 5 節),直接接線。
//   conv2 → FC:ConvToFCAdapter 存一級暫存器,換成 src = o_c*H_out*W_out + o_y*W_out + o_x(FC.md 第 1 節)。
//   FC 是輸出層:不 fire(SPIKE_OUTPUT = 0),每寫回一列送出膜電位(MEMBRANE_OUTPUT = 1);
//   FCMembraneRegister 存每顆最新的 V̂,一筆事件更新完拉 update_done(FC.md 第 6 節 ⑥)。
//   每一層往下送的那條都停在下一層的暫存器或 FIFO 寫入端,往上擋的那條都從下一層的暫存器開始,
//   沒有一條組合邏輯穿過兩層(轉接模組給 conv2 的 ready 經過 1 級 LUT,FC.md 第 1 節)。
//   幾何只給網路輸入大小、每層 conv 的 K、S、P、OC,跟 FC 的 n_out;各層輸出大小、FC 的 n_in、
//   層與層之間的位寬都在這裡推出來,上下層對不上的組合寫不出來。
//   參數分兩種(model_operation_quant.md 第 1 節「粒度」):
//     每層各自一份的加 CONV1_、CONV2_、FC_ 前綴:幾何、i_V、衰減表深度、FIFO 深度、資料檔
//     整個網路共用一份的不加前綴:時間位寬、b、f_V、f_a、捨入、溢位處理、管線設定
//   rst_n 全部共用,各層各自清自己的神經元記憶體;上一層先清完時,輸出會被下一層的 in_ready=0 擋住。
//
//   檔案照事件的流程由上往下排:
//     1 conv1、「現在」(conv1 最新收進的事件時間,接給每一層)
//     2 conv2
//     3 conv2 → FC 轉接
//     4 FC
//     5 膜電位暫存器
//////////////////////////////////////////////////////////////////////////////////

module SaltConvFCNet #(
	// 網路輸入(conv1 的輸入)
	parameter integer IN_CHANNELS = 2,    // conv1 的 C
	parameter integer IN_ROWS     = 34,   // conv1 的 H_in
	parameter integer IN_COLS     = 34,   // conv1 的 W_in

	// conv1
	parameter integer CONV1_OUT_CHANNELS       = 8,    // OC
	parameter integer CONV1_KERNEL_SIZE        = 3,    // K
	parameter integer CONV1_STRIDE             = 2,    // S
	parameter integer CONV1_PADDING            = 1,    // P
	parameter integer CONV1_MEMBRANE_INT_WIDTH = 9,    // i_V
	parameter integer CONV1_DECAY_TABLE_DEPTH  = 75,   // Δt_max
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

	// FC(輸出層,輸入是 conv2 的輸出攤平;不 fire,沒有門檻檔)
	parameter integer FC_OUT_NEURONS        = 10,   // n_out
	parameter integer FC_NEURONS_PER_ROW    = 4,    // n_col
	parameter integer FC_MEMBRANE_INT_WIDTH = 11,
	parameter integer FC_DECAY_TABLE_DEPTH  = 75,
	parameter integer FC_FIFO_DEPTH         = 16,
	parameter FC_WEIGHT_FILE = "out_weight.mem",
	parameter FC_DECAY_FILE  = "out_decay.mem",

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

	// 輸出大小:(H_in + 2P - K) / S + 1,跟訓練端相同
	localparam integer CONV1_OUT_ROWS = (IN_ROWS + 2 * CONV1_PADDING - CONV1_KERNEL_SIZE) / CONV1_STRIDE + 1,
	localparam integer CONV1_OUT_COLS = (IN_COLS + 2 * CONV1_PADDING - CONV1_KERNEL_SIZE) / CONV1_STRIDE + 1,
	localparam integer CONV2_OUT_ROWS = (CONV1_OUT_ROWS + 2 * CONV2_PADDING - CONV2_KERNEL_SIZE) / CONV2_STRIDE + 1,
	localparam integer CONV2_OUT_COLS = (CONV1_OUT_COLS + 2 * CONV2_PADDING - CONV2_KERNEL_SIZE) / CONV2_STRIDE + 1,
	localparam integer FC_IN_NEURONS  = CONV2_OUT_CHANNELS * CONV2_OUT_ROWS * CONV2_OUT_COLS,   // n_in

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
	localparam integer FC_IN_NEURON_WIDTH  = (FC_IN_NEURONS > 1) ? $clog2(FC_IN_NEURONS) : 1,
	localparam integer FC_OUT_NEURON_WIDTH = (FC_OUT_NEURONS > 1) ? $clog2(FC_OUT_NEURONS) : 1,
	localparam integer FC_MEMBRANE_WIDTH   = FC_MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH   // FC 的 w
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
	output logic [FC_OUT_NEURONS*FC_MEMBRANE_WIDTH-1:0] membranes,     // 第 i 顆的 V̂ 在第 i*w 到 (i+1)*w-1 位元
	output logic                                        update_done,   // 這一拍 membranes 全是同一筆事件更新完的值
	output logic [TIME_WIDTH-1:0]                       update_time    // 那筆事件的 t;update_done=1 那一拍才有意義
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
		.OVERLAP            (OVERLAP)
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
		.OVERLAP            (OVERLAP)
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
	// 3 conv2 → FC 轉接
	// ===============================================================
	logic                          fc_in_valid;
	logic                          fc_in_ready;
	logic [FC_IN_NEURON_WIDTH-1:0] fc_in_neuron;   // src
	logic [TIME_WIDTH-1:0]         fc_in_time;

	ConvToFCAdapter #(
		.IN_CHANNELS(CONV2_OUT_CHANNELS),
		.IN_ROWS    (CONV2_OUT_ROWS),
		.IN_COLS    (CONV2_OUT_COLS),
		.TIME_WIDTH (TIME_WIDTH)
	) conv_to_fc (
		.clk       (clk),
		.rst_n     (rst_n),
		.in_valid  (conv2_out_valid),
		.in_ready  (conv2_out_ready),
		.in_x      (conv2_out_x),
		.in_y      (conv2_out_y),
		.in_channel(conv2_out_channel),
		.in_time   (conv2_out_time),
		.out_valid (fc_in_valid),
		.out_ready (fc_in_ready),
		.out_neuron(fc_in_neuron),
		.out_time  (fc_in_time)
	);

	// ===============================================================
	// 4 FC
	// ===============================================================
	logic                                            membrane_valid;
	logic [FC_OUT_NEURON_WIDTH-1:0]                  membrane_row_base;
	logic [FC_NEURONS_PER_ROW*FC_MEMBRANE_WIDTH-1:0] membrane_values;
	logic [TIME_WIDTH-1:0]                           membrane_time;

	// 輸出層不 fire:spike 輸出固定 0,不接;沒有門檻檔(SPIKE_OUTPUT = 0 時 SaltFC 不讀 THRESHOLD_FILE)
	SaltFC #(
		.IN_NEURONS         (FC_IN_NEURONS),
		.OUT_NEURONS        (FC_OUT_NEURONS),
		.NEURONS_PER_ROW    (FC_NEURONS_PER_ROW),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (FC_MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (FC_DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.SHARED_THRESHOLD   (0),
		.SPIKE_OUTPUT       (0),
		.MEMBRANE_OUTPUT    (1),
		.WEIGHT_FILE        (FC_WEIGHT_FILE),
		.DECAY_FILE         (FC_DECAY_FILE),
		.FIFO_DEPTH         (FC_FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP)
	) fc (
		.clk              (clk),
		.rst_n            (rst_n),
		.current_time     (current_time),
		.in_valid         (fc_in_valid),
		.in_ready         (fc_in_ready),
		.in_neuron        (fc_in_neuron),
		.in_time          (fc_in_time),
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
	// 5 膜電位暫存器
	// ===============================================================
	FCMembraneRegister #(
		.OUT_NEURONS    (FC_OUT_NEURONS),
		.NEURONS_PER_ROW(FC_NEURONS_PER_ROW),
		.MEMBRANE_WIDTH (FC_MEMBRANE_WIDTH),
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
