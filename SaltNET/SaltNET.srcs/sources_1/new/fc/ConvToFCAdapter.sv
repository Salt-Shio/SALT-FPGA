`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ConvToFCAdapter
// Description:
//   conv 層接 FC 層的轉接模組(FC.md 第 1 節「src 從哪裡來」),放在層外,由上層例化:
//   conv 的 spike 輸出 → 事件暫存器 → 換算 → SaltFC 的輸入(寫進 SaltFC 的輸入 FIFO)。
//   conv 送出座標 (o_c, o_y, o_x, t),FC 收攤平編號 (src, t):src = o_c*H_out*W_out + o_y*W_out + o_x,t 原封不動。
//   port 照同名直接接:輸入用 conv 輸入的名字(in_x、in_y、in_channel),接 conv 的 out_x、out_y、out_channel;
//   輸出用 FC 輸出的名字(out_neuron),接 SaltFC 的 in_neuron。
//   參數只給 conv 的輸出形狀;座標位寬、n_in、src 位寬跟 SaltConv、SaltFC 用同一套公式推出來,
//   上層把同一組形狀傳給三個模組,位寬就對得上。
//
//   給 conv 的 in_ready = 暫存器空的,或下游這一拍收走:每拍收得下一筆,每筆晚 1 拍。
//   座標、t 只在收進一筆的那拍寫,其他拍保持。
//
//   檔案照一筆事件的流程由上往下排:
//     1 事件進來:事件暫存器、給 conv 的 ready
//     2 換算、送出
//   排列規則:變數的宣告跟設定它的邏輯放在同一段;要用到的變數,設定它的那段排在前面。
//////////////////////////////////////////////////////////////////////////////////

module ConvToFCAdapter #(
	// conv 的輸出形狀
	parameter integer IN_CHANNELS = 16,   // OC
	parameter integer IN_ROWS     = 9,    // H_out
	parameter integer IN_COLS     = 9,    // W_out

	parameter integer TIME_WIDTH = 16,   // 單位:整數 ms

	// 推導出來的位寬($clog2(1)=0 時至少保留 1 bit);座標位寬跟 SaltConv 的 OUT_*_WIDTH、
	// OUT_NEURONS 跟 SaltFC 的 IN_NEURONS、OUT_NEURON_WIDTH 跟 SaltFC 的 IN_NEURON_WIDTH 同一套公式,port 位寬要對上才能接
	localparam integer IN_CHANNEL_WIDTH = (IN_CHANNELS > 1) ? $clog2(IN_CHANNELS) : 1,
	localparam integer IN_Y_WIDTH       = (IN_ROWS > 1) ? $clog2(IN_ROWS) : 1,
	localparam integer IN_X_WIDTH       = (IN_COLS > 1) ? $clog2(IN_COLS) : 1,
	localparam integer OUT_NEURONS      = IN_CHANNELS * IN_ROWS * IN_COLS,   // FC 的 n_in
	localparam integer OUT_NEURON_WIDTH = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1
)(
	input  logic clk,
	input  logic rst_n,   // active-low,非同步觸發、同步釋放

	// conv 的 spike 輸出,同名接上
	input  logic                        in_valid,
	output logic                        in_ready,
	input  logic [IN_X_WIDTH-1:0]       in_x,         // o_x
	input  logic [IN_Y_WIDTH-1:0]       in_y,         // o_y
	input  logic [IN_CHANNEL_WIDTH-1:0] in_channel,   // o_c
	input  logic [TIME_WIDTH-1:0]       in_time,

	// 接 SaltFC 的輸入
	output logic                        out_valid,
	input  logic                        out_ready,
	output logic [OUT_NEURON_WIDTH-1:0] out_neuron,   // src
	output logic [TIME_WIDTH-1:0]       out_time
);

	// ===============================================================
	// 1 事件進來
	// ===============================================================
	// 事件暫存器:conv 送來、還沒被下游收走的那筆。event_valid 跟 in_ready 互相依賴,放同一段
	logic                        event_valid;     // 暫存器裡有一筆
	logic [IN_X_WIDTH-1:0]       event_x;         // o_x
	logic [IN_Y_WIDTH-1:0]       event_y;         // o_y
	logic [IN_CHANNEL_WIDTH-1:0] event_channel;   // o_c
	logic [TIME_WIDTH-1:0]       event_time;      // t

	assign in_ready = !event_valid || out_ready;

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			event_valid <= 1'b0;
		end else if (in_ready) begin
			event_valid <= in_valid;
		end
	end

	// 座標、t 沒有 reset:event_valid = 0 時不會被送出去
	always_ff @(posedge clk) begin
		if (in_valid && in_ready) begin
			event_x       <= in_x;
			event_y       <= in_y;
			event_channel <= in_channel;
			event_time    <= in_time;
		end
	end

	// ===============================================================
	// 2 換算、送出
	// ===============================================================
	localparam integer PLANE_SIZE = IN_ROWS * IN_COLS;   // H_out*W_out

	assign out_valid  = event_valid;
	assign out_neuron = OUT_NEURON_WIDTH'(event_channel * PLANE_SIZE + event_y * IN_COLS + event_x);
	assign out_time   = event_time;

endmodule
