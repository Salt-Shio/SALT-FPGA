`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: MicrosecondToMillisecond
// Description:
//   事件時間從 µs 換成整數 ms:t_ms = floor(t_us / 1000),跟訓練端讀 N-MNIST 相同(data/src/nmnist.py)。
//   接相機時放在 EvtDecoder 和 conv1 之間:輸入是 EvtDecoder 的 34 位元 µs,輸出只留低 TIME_WIDTH 位,
//   跟網路的時間位寬相同(完整的商最大 17179869,25 位元)。
//   做法(docs/SNN/Todo「待決事項 → 系統整合」µs 換 ms,2026-11-15 定案):乘倒數。
//     先右移 3 位(÷8)得 x',再乘 RECIPROCAL = ceil(2^35/125) = 274877907,取乘積第 35 位起(÷125)。
//     125·RECIPROCAL = 2^35 + 7,常數多出來的誤差是 7x'/(125·2^35);x' < 2^31 時 7x' < 2^35,誤差小於 1/125,
//     x'/125 的小數最多 124/125,加起來不到 1,所以 34 位元的每個輸入都等於 floor(t_us/1000)。
//   管線:輸入暫存器(存 x')→ 乘法 → PRODUCT_STAGES 級乘積暫存器,延遲 1 + PRODUCT_STAGES 拍,每拍收一筆。
//     乘法放 DSP;乘積暫存器 3 級以上時 Vivado 推進 DSP、在 DSP 之間串接相加(2026-11-15 單獨量測)。
//   同一筆事件的其他欄位(payload,例如 x、y、極性)不算,跟著時間一級一級往後推,
//     出來時跟 out_time 是同一筆事件;外面不用知道裡面有幾級。沒有其他欄位時 PAYLOAD_WIDTH 給 1、接 0。
//   交握:下游不收(out_valid && !out_ready)時整條管線停住,每一級都保持;
//     給上游的 in_ready = 管線沒停住,從 out_ready 經過 1 級 LUT。
//
//   檔案照一筆事件的流程由上往下排:
//     0 共用控制:管線往後推不推(第 3 段才算出來,前面就要用)
//     1 事件進來:輸入暫存器(x'、payload)
//     2 乘法、乘積暫存器
//     3 送出、停不停
//   排列規則:變數的宣告跟設定它的邏輯放在同一段;要用到的變數,設定它的那段排在前面。
//   例外只有第 0 段的控制訊號:要等第 3 段算完才知道,第 1 段起就要用。
//////////////////////////////////////////////////////////////////////////////////

module MicrosecondToMillisecond #(
	parameter integer TIME_WIDTH     = 16,   // 輸出的整數 ms 位寬,跟網路的 TIME_WIDTH 相同;最多 25
	parameter integer PAYLOAD_WIDTH  = 1,    // 跟著走的其他欄位總寬,至少 1
	parameter integer PRODUCT_STAGES = 3,    // 乘法後幾級暫存器,至少 1

	// EvtDecoder 的時間欄位(M_AXIS_TDATA 位元 33~0)
	localparam integer IN_TIME_WIDTH = 34
)(
	input  logic clk,
	input  logic rst_n,   // active-low,非同步觸發、同步釋放

	// 輸入事件(valid/ready 握手)
	input  logic                     in_valid,
	output logic                     in_ready,
	input  logic [IN_TIME_WIDTH-1:0] in_time_us,
	input  logic [PAYLOAD_WIDTH-1:0] in_payload,

	// 輸出事件(valid/ready 握手)
	output logic                     out_valid,
	input  logic                     out_ready,
	output logic [TIME_WIDTH-1:0]    out_time,      // floor(in_time_us / 1000) 的低 TIME_WIDTH 位
	output logic [PAYLOAD_WIDTH-1:0] out_payload    // 跟 out_time 同一筆事件的 in_payload
);

	localparam integer SHIFT_BITS       = 3;                            // ÷8
	localparam integer SCALED_WIDTH     = IN_TIME_WIDTH - SHIFT_BITS;   // x' 的位寬,31
	localparam integer RECIPROCAL_WIDTH = 29;                           // 2^28 < RECIPROCAL < 2^29
	localparam logic [RECIPROCAL_WIDTH-1:0] RECIPROCAL = 29'd274877907;  // ceil(2^35/125)
	localparam integer PRODUCT_WIDTH    = SCALED_WIDTH + RECIPROCAL_WIDTH;   // 60
	localparam integer QUOTIENT_LSB     = 35;                           // 乘積第 35 位起是 floor(x'/125)

	initial begin
		if (TIME_WIDTH < 1 || TIME_WIDTH > PRODUCT_WIDTH - QUOTIENT_LSB) begin
			$fatal(1, "MicrosecondToMillisecond: TIME_WIDTH=%0d not in 1..%0d", TIME_WIDTH, PRODUCT_WIDTH - QUOTIENT_LSB);
		end
		if (PAYLOAD_WIDTH < 1) begin
			$fatal(1, "MicrosecondToMillisecond: PAYLOAD_WIDTH=%0d, at least 1", PAYLOAD_WIDTH);
		end
		if (PRODUCT_STAGES < 1) begin
			$fatal(1, "MicrosecondToMillisecond: PRODUCT_STAGES=%0d, at least 1", PRODUCT_STAGES);
		end
	end

	// ===============================================================
	// 0 共用控制:第 3 段算,第 1 段起就要用
	// ===============================================================
	logic advance;   // 這一拍整條管線往後推一格(下游收走最後一級,或最後一級是空的)

	// ===============================================================
	// 1 事件進來
	// ===============================================================
	// 輸入暫存器:右移完的 x' 跟 payload。資料沒有 reset:input_valid = 0 時不會被送出去
	logic                     input_valid;
	logic [SCALED_WIDTH-1:0]  scaled_time;     // x' = floor(t_us / 8)
	logic [PAYLOAD_WIDTH-1:0] input_payload;

	assign in_ready = advance;

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			input_valid <= 1'b0;
		end else if (advance) begin
			input_valid <= in_valid;
		end
	end

	// 管線往後推的拍子都存(不看 in_valid),每一級的開關都是 advance,乘積暫存器才併得進 DSP
	always_ff @(posedge clk) begin
		if (advance) begin
			scaled_time   <= in_time_us[IN_TIME_WIDTH-1:SHIFT_BITS];
			input_payload <= in_payload;
		end
	end

	// ===============================================================
	// 2 乘法、乘積暫存器
	// ===============================================================
	// 乘法一律放 DSP(UG901 use_dsp),31 x 29 位元拆成 4 顆
	(* use_dsp = "yes" *) logic [PRODUCT_WIDTH-1:0] product;   // x' · RECIPROCAL

	assign product = scaled_time * RECIPROCAL;

	// 第 1 級存乘法結果,第 k 級存第 k-1 級;payload 跟著一起推
	logic                     product_valid   [1:PRODUCT_STAGES];
	logic [PRODUCT_WIDTH-1:0] product_stage   [1:PRODUCT_STAGES];
	logic [PAYLOAD_WIDTH-1:0] product_payload [1:PRODUCT_STAGES];

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			for (int stage = 1; stage <= PRODUCT_STAGES; stage++) begin
				product_valid[stage] <= 1'b0;
			end
		end else if (advance) begin
			product_valid[1] <= input_valid;
			for (int stage = 2; stage <= PRODUCT_STAGES; stage++) begin
				product_valid[stage] <= product_valid[stage-1];
			end
		end
	end

	always_ff @(posedge clk) begin
		if (advance) begin
			product_stage[1]   <= product;
			product_payload[1] <= input_payload;
			for (int stage = 2; stage <= PRODUCT_STAGES; stage++) begin
				product_stage[stage]   <= product_stage[stage-1];
				product_payload[stage] <= product_payload[stage-1];
			end
		end
	end

	// ===============================================================
	// 3 送出、停不停
	// ===============================================================
	assign out_valid   = product_valid[PRODUCT_STAGES];
	assign out_time    = product_stage[PRODUCT_STAGES][QUOTIENT_LSB +: TIME_WIDTH];
	assign out_payload = product_payload[PRODUCT_STAGES];

	// 最後一級送不出去才停;停住時每一級都保持,前面空的級也不補(每拍收一筆只靠下游一直收)
	assign advance = !out_valid || out_ready;

endmodule
