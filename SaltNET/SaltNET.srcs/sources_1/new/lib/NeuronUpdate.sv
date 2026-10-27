`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: NeuronUpdate
// Description:
//   一顆神經元收到一筆事件後的膜電位更新(Conv.md、FC.md 第 3 節 ②~④);① 的衰減碼 A 由 DecayLookup 算好接進來。
//   COMPUTE_LATENCY(C)= 1:純組合邏輯。
//   COMPUTE_LATENCY = 2:② 之後切一排暫存器(存 D、q),② 是計算第 1 級,③④ 是計算第 2 級,
//     第 2 級在輸入的下一拍出 spike、new_membrane。切點暫存器每拍都存,不接開關:
//     第 2 級的結果上層只在算的那一拍用,之後停住的拍子用的是 bitmask(SaltConv 第 6 段)。
//     decay_code 在第 1 級用(上層的 DecayLookup 接第 1 級的時間),threshold 在第 2 級用,上層各接那一級的值。
//   上層一拍要算幾顆神經元就例化幾份(conv M x M 份,FC n_col 份);門檻、寫不寫回、送不送出 spike 都由上層決定。
//     ② D = r(A·V̂),r 是 round(先加半格)或 truncate,都是算術右移 f_a 位。
//     ③ U = D + (q << f_V),位寬 max(w, b+f_V)+1,不會在這一步溢位。
//     ④ V̂' = fit_w(U),繞回取低 w 位、飽和夾在 w 位元範圍。
//       SPIKE_OUTPUT = 1:V̂' >= v̂_th 時 fire,V̂_new=0,否則 V̂_new=V̂'。
//       SPIKE_OUTPUT = 0:不 fire(spike 固定 0),V̂_new=V̂';threshold 用不到,例化端接 0,比較器合成時修剪。
//   新的 t_last 就是這筆事件的 t,由上層處理,這裡不輸出。
//   DECAY_FRAC_WIDTH 至少 1(round 要加 2^(f_a-1)),MEMBRANE_WIDTH 至少 2。
//////////////////////////////////////////////////////////////////////////////////

module NeuronUpdate #(
	parameter integer WEIGHT_WIDTH        = 7,    // b,權重碼位元寬
	parameter integer MEMBRANE_INT_WIDTH  = 9,    // i_V,膜電位暫存器整數位元(含符號位)
	parameter integer MEMBRANE_FRAC_WIDTH = 0,    // f_V,膜電位暫存器小數位元
	parameter integer DECAY_FRAC_WIDTH    = 6,    // f_a,衰減碼小數位元

	// 量化行為(兩種都要能合成,由例化端選)
	parameter bit ROUND    = 1,   // 1:round,0:truncate
	parameter bit SATURATE = 1,   // 1:飽和,0:繞回

	parameter bit SPIKE_OUTPUT = 1,   // 1:判斷 fire,fire 時寫回 0;0:不 fire,寫回 V̂'

	parameter integer COMPUTE_LATENCY = 1,   // C:1 或 2

	// 推導出來的位寬
	localparam integer MEMBRANE_WIDTH = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH,   // w
	// A·V̂:A 在 0~1.0(0~2^f_a),乘 w 位元有號,f_a+w 位元有號放得下,round 加半格之後也放得下(Conv.md 第 3 節 ②);
	// 最負 -2^(f_a+w-1) 剛好是下限,最正 (2^(w-1)-1)·2^f_a + 2^(f_a-1) 比上限小
	localparam integer PRODUCT_WIDTH  = DECAY_FRAC_WIDTH + MEMBRANE_WIDTH,
	// U = D + (q << f_V):D 是 w 位元、q << f_V 是 b+f_V 位元,都有號,相加多 1 位(Conv.md 第 3 節 ③)
	localparam integer SUM_WIDTH      = ((MEMBRANE_WIDTH > WEIGHT_WIDTH + MEMBRANE_FRAC_WIDTH)
	                                     ? MEMBRANE_WIDTH : WEIGHT_WIDTH + MEMBRANE_FRAC_WIDTH) + 1
)(
	input  logic                             clk,            // C = 1 時用不到
	input  logic        [DECAY_FRAC_WIDTH:0] decay_code,     // A,DecayLookup 的輸出
	input  logic signed [WEIGHT_WIDTH-1:0]   weight_code,    // q
	input  logic signed [MEMBRANE_WIDTH-1:0] membrane,       // V̂
	input  logic signed [MEMBRANE_WIDTH-1:0] threshold,      // v̂_th;SPIKE_OUTPUT = 0 時用不到
	output logic                             spike,          // s
	output logic signed [MEMBRANE_WIDTH-1:0] new_membrane    // V̂_new
);

	initial begin
		if (COMPUTE_LATENCY != 1 && COMPUTE_LATENCY != 2) begin
			$fatal(1, "NeuronUpdate: COMPUTE_LATENCY=%0d not supported", COMPUTE_LATENCY);
		end
	end

	// ② 衰減乘法,再捨回暫存器格式
	// 乘法、加半格一律放 DSP(UG901 use_dsp):不指定時 Vivado 依位寬自己選,w=9 選 LUT,
	// 計算第 1 級反而比 DSP 長(C = 2 時切點暫存器併進 DSP 的 PREG),而且各層資源類型不一致
	(* use_dsp = "yes" *) logic signed [PRODUCT_WIDTH-1:0] decay_product;     // A·V̂,小數 f_a + f_V 位
	(* use_dsp = "yes" *) logic signed [PRODUCT_WIDTH-1:0] rounded_product;
	logic signed [PRODUCT_WIDTH-1:0]  shifted_product;
	logic signed [MEMBRANE_WIDTH-1:0] decayed;          // D

	// A 前面補 0 當成(正)有號數,乘積才是有號乘法
	assign decay_product = $signed({1'b0, decay_code}) * membrane;

	if (ROUND) begin : round_half
		assign rounded_product = decay_product + PRODUCT_WIDTH'(1 << (DECAY_FRAC_WIDTH - 1));
	end else begin : truncate
		assign rounded_product = decay_product;
	end

	assign shifted_product = rounded_product >>> DECAY_FRAC_WIDTH;
	// D 一定落在 0 跟 V̂ 之間(A=1.0 時就是 V̂),取低 w 位不會丟資料
	assign decayed = shifted_product[MEMBRANE_WIDTH-1:0];

	// ③ 用的 D、q:C = 2 時是切點暫存器,C = 1 時直連
	logic signed [MEMBRANE_WIDTH-1:0] stage_decayed;
	logic signed [WEIGHT_WIDTH-1:0]   stage_weight_code;

	if (COMPUTE_LATENCY == 2) begin : cut_after_step2
		always_ff @(posedge clk) begin
			stage_decayed     <= decayed;
			stage_weight_code <= weight_code;
		end
	end else begin : no_cut
		assign stage_decayed     = decayed;
		assign stage_weight_code = weight_code;
	end

	// ③ 加權重碼
	logic signed [SUM_WIDTH-1:0] decayed_extended;
	logic signed [SUM_WIDTH-1:0] weight_extended;
	logic signed [SUM_WIDTH-1:0] unfitted;   // U,溢位處理之前的真實值

	// 有號數指定到較寬的變數會做符號延伸
	assign decayed_extended = stage_decayed;
	assign weight_extended  = stage_weight_code;
	assign unfitted         = decayed_extended + (weight_extended <<< MEMBRANE_FRAC_WIDTH);

	// ④ 放回 w 位元,再判斷 fire
	logic signed [MEMBRANE_WIDTH-1:0] fitted;   // V̂'

	if (SATURATE) begin : saturate
		// U 在 w 位元範圍內 ⇔ 第 w-1 位以上全部相同
		logic [SUM_WIDTH-MEMBRANE_WIDTH:0] upper_bits;
		logic                              in_range;

		assign upper_bits = unfitted[SUM_WIDTH-1:MEMBRANE_WIDTH-1];
		assign in_range   = (&upper_bits) || !(|upper_bits); // 全 1 or 全 0 表示 in range

		always_comb begin
			if (in_range) begin
				fitted = unfitted[MEMBRANE_WIDTH-1:0];
			end else if (unfitted[SUM_WIDTH-1]) begin
				fitted = {1'b1, {(MEMBRANE_WIDTH - 1){1'b0}}};   // -2^(w-1)
			end else begin
				fitted = {1'b0, {(MEMBRANE_WIDTH - 1){1'b1}}};   // 2^(w-1) - 1
			end
		end
	end else begin : wrap
		// 兩補數取低 w 位,超出範圍時翻號
		assign fitted = unfitted[MEMBRANE_WIDTH-1:0];
	end

	if (SPIKE_OUTPUT) begin : fire
		assign spike        = (fitted >= threshold);
		assign new_membrane = spike ? '0 : fitted;
	end else begin : no_fire
		assign spike        = 1'b0;
		assign new_membrane = fitted;
	end

endmodule
