`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SaltConvNet
// Description:
//   訓練端網路的 conv 部分:conv1 → conv2 兩層 SaltConv 直接串接。
//   conv 接 conv 時欄位一一對應(o_c → c、o_y → y、o_x → x、t → t,model_operation_quant.md 第 5 節),
//   conv1 的 out_ 直接接 conv2 的 in_,中間不加東西:
//     conv1 往下送的那條在 conv2 的 FIFO 寫入結束(寫入下一拍才讀得到,沒有直通);
//     conv2 往上擋的那條從 conv2 的暫存器開始(in_ready = !full && !clearing)。
//     所以沒有一條組合邏輯同時穿過兩層。
//   幾何只給輸入大小和每層的 K、S、P、OC,各層的輸出大小、層與層之間的位寬都在這裡推出來,
//   不另外給參數,上下層對不上的組合寫不出來。
//   參數分兩種(model_operation_quant.md 第 1 節「粒度」):
//     每層各自一份的加 CONV1_、CONV2_ 前綴:幾何、i_V、衰減表深度、FIFO 深度、三個資料檔
//     整個網路共用一份的不加前綴:時間位寬、b、f_V、f_a、捨入、溢位處理、管線設定
//   rst_n 兩層共用,兩層各自清自己的神經元記憶體;conv1 先清完時輸出會被 conv2 的 in_ready=0 擋住。
//////////////////////////////////////////////////////////////////////////////////

module SaltConvNet #(
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

	// 位寬:跟 SaltConv 的 OUT_*_WIDTH 同一套公式;conv1 的輸出位寬就是 conv2 的輸入位寬
	localparam integer IN_X_WIDTH          = (IN_COLS > 1) ? $clog2(IN_COLS) : 1,
	localparam integer IN_Y_WIDTH          = (IN_ROWS > 1) ? $clog2(IN_ROWS) : 1,
	localparam integer IN_CHANNEL_WIDTH    = (IN_CHANNELS > 1) ? $clog2(IN_CHANNELS) : 1,
	localparam integer CONV1_X_WIDTH       = (CONV1_OUT_COLS > 1) ? $clog2(CONV1_OUT_COLS) : 1,
	localparam integer CONV1_Y_WIDTH       = (CONV1_OUT_ROWS > 1) ? $clog2(CONV1_OUT_ROWS) : 1,
	localparam integer CONV1_CHANNEL_WIDTH = (CONV1_OUT_CHANNELS > 1) ? $clog2(CONV1_OUT_CHANNELS) : 1,
	localparam integer OUT_X_WIDTH         = (CONV2_OUT_COLS > 1) ? $clog2(CONV2_OUT_COLS) : 1,
	localparam integer OUT_Y_WIDTH         = (CONV2_OUT_ROWS > 1) ? $clog2(CONV2_OUT_ROWS) : 1,
	localparam integer OUT_CHANNEL_WIDTH   = (CONV2_OUT_CHANNELS > 1) ? $clog2(CONV2_OUT_CHANNELS) : 1
)(
	input  logic clk,
	input  logic rst_n,   // active-low;in_ready 等 conv1 清完,conv2 還沒清完時 conv1 的輸出被擋住

	// 網路輸入事件(conv1 的輸入)
	input  logic                        in_valid,
	output logic                        in_ready,
	input  logic [IN_X_WIDTH-1:0]       in_x,
	input  logic [IN_Y_WIDTH-1:0]       in_y,
	input  logic [IN_CHANNEL_WIDTH-1:0] in_channel,
	input  logic [TIME_WIDTH-1:0]       in_time,

	// 網路輸出事件(conv2 的輸出)
	output logic                         out_valid,
	input  logic                         out_ready,
	output logic [OUT_X_WIDTH-1:0]       out_x,         // o_x
	output logic [OUT_Y_WIDTH-1:0]       out_y,         // o_y
	output logic [OUT_CHANNEL_WIDTH-1:0] out_channel,   // o_c
	output logic [TIME_WIDTH-1:0]        out_time
);

	// conv1 → conv2
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
		.clk        (clk),
		.rst_n      (rst_n),
		.in_valid   (in_valid),
		.in_ready   (in_ready),
		.in_x       (in_x),
		.in_y       (in_y),
		.in_channel (in_channel),
		.in_time    (in_time),
		.out_valid  (conv1_out_valid),
		.out_ready  (conv1_out_ready),
		.out_x      (conv1_out_x),
		.out_y      (conv1_out_y),
		.out_channel(conv1_out_channel),
		.out_time   (conv1_out_time)
	);

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
		.clk        (clk),
		.rst_n      (rst_n),
		.in_valid   (conv1_out_valid),
		.in_ready   (conv1_out_ready),
		.in_x       (conv1_out_x),
		.in_y       (conv1_out_y),
		.in_channel (conv1_out_channel),
		.in_time    (conv1_out_time),
		.out_valid  (out_valid),
		.out_ready  (out_ready),
		.out_x      (out_x),
		.out_y      (out_y),
		.out_channel(out_channel),
		.out_time   (out_time)
	);

endmodule
