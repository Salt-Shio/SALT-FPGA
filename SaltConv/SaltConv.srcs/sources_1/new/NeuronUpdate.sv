`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: NeuronUpdate
// Description:
//   一顆神經元收到一筆事件後的膜電位更新(Conv.md 第 3 節 ①~④),純組合邏輯。
//   上層一拍要算 M x M 顆候選,就例化 M x M 份;門檻、寫不寫回、送不送出 spike 都由上層決定。
//     ① Δt = t - t_last:Δt=0 不衰減;1 <= Δt <= Δt_max 查衰減表 A[Δt];Δt > Δt_max 時 A=0。
//     ② D = r(A·V̂),r 是 round(先加半格)或 truncate,都是算術右移 f_a 位。
//     ③ U = D + (q << f_V),位寬 max(w, b+f_V)+1,不會在這一步溢位。
//     ④ V̂' = fit_w(U),繞回取低 w 位、飽和夾在 w 位元範圍;V̂' >= v̂_th 時 fire,V̂_new=0,否則 V̂_new=V̂'。
//   新的 t_last 就是 event_time,上層直接接到 NeuronMemory 的寫 port,這裡不輸出。
//   Δt 用 TIME_WIDTH 位元無號減法:event_time < last_time 只會在時間戳記繞回時發生,
//   繞回怎麼處理還沒定,這時 Δt 是 mod 2^TIME_WIDTH 的值。
//   衰減表用 $readmemh 從 DECAY_FILE 載入,檔案格式見 Conv.md 第 3 節 ① 的「檔案格式」;
//   每一份 NeuronUpdate 各有一份,讀取是組合邏輯。
//   DECAY_FRAC_WIDTH 至少 1(round 要加 2^(f_a-1)),MEMBRANE_WIDTH 至少 2。
//////////////////////////////////////////////////////////////////////////////////

module NeuronUpdate #(
	parameter integer TIME_WIDTH          = 16,   // 單位:整數 ms
	parameter integer WEIGHT_WIDTH        = 7,    // b,權重碼位元寬
	parameter integer MEMBRANE_INT_WIDTH  = 9,    // i_V,膜電位暫存器整數位元(含符號位)
	parameter integer MEMBRANE_FRAC_WIDTH = 0,    // f_V,膜電位暫存器小數位元
	parameter integer DECAY_FRAC_WIDTH    = 6,    // f_a,衰減碼小數位元
	parameter integer DECAY_TABLE_DEPTH   = 75,   // Δt_max,衰減表深度

	// 量化行為(兩種都要能合成,由例化端選)
	parameter bit ROUND    = 1,   // 1:round,0:truncate
	parameter bit SATURATE = 1,   // 1:飽和,0:繞回

	// 不寫型別:Vivado 不支援 SystemVerilog string 型別參數,也不支援空字串參數(UG901)
	parameter DECAY_FILE = "decay.mem",   // 衰減表,位址 Δt-1,每字 DECAY_FRAC_WIDTH bits 無號

	// 推導出來的位寬
	localparam integer MEMBRANE_WIDTH = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH,   // w
	// A·V̂:f_a 位元無號乘 w 位元有號,f_a+w 位元有號放得下,round 加半格之後也放得下(Conv.md 第 3 節 ②)
	localparam integer PRODUCT_WIDTH  = DECAY_FRAC_WIDTH + MEMBRANE_WIDTH,
	// U = D + (q << f_V):D 是 w 位元、q << f_V 是 b+f_V 位元,都有號,相加多 1 位(Conv.md 第 3 節 ③)
	localparam integer SUM_WIDTH      = ((MEMBRANE_WIDTH > WEIGHT_WIDTH + MEMBRANE_FRAC_WIDTH)
	                                     ? MEMBRANE_WIDTH : WEIGHT_WIDTH + MEMBRANE_FRAC_WIDTH) + 1
)(
	input  logic signed [WEIGHT_WIDTH-1:0]   weight_code,    // q
	input  logic signed [MEMBRANE_WIDTH-1:0] membrane,       // V̂
	input  logic        [TIME_WIDTH-1:0]     last_time,      // t_last
	input  logic        [TIME_WIDTH-1:0]     event_time,     // t
	input  logic signed [MEMBRANE_WIDTH-1:0] threshold,      // v̂_th[o_c]
	output logic                             spike,          // s
	output logic signed [MEMBRANE_WIDTH-1:0] new_membrane    // V̂_new
);

	// 一律用 LUT,讀取是組合邏輯,同一拍 M x M 份各查各的位址
	(* rom_style = "distributed" *) logic [DECAY_FRAC_WIDTH-1:0] decay_table [0:DECAY_TABLE_DEPTH-1];

	initial begin
		$readmemh(DECAY_FILE, decay_table);
	end

	// ① 時間間隔、查衰減碼
	/* reviewer: 
		1. 是否有考慮透過 DECAY_TABLE_DEPTH 來判斷 delta_time 的位寬 ? 因為 delta_time 太大根本沒用
	*/
	logic [TIME_WIDTH-1:0]       delta_time;
	logic                        is_same_time;   // Δt=0,不衰減
	logic [DECAY_FRAC_WIDTH-1:0] decay_code;     // A[Δt]

	assign delta_time   = event_time - last_time;
	assign is_same_time = (delta_time == '0);

	always_comb begin
		// Δt=0 不查表(用不到),Δt > Δt_max 時 A=0
		if (is_same_time || delta_time > DECAY_TABLE_DEPTH) begin
			decay_code = '0;
		end else begin
			decay_code = decay_table[delta_time - 1'b1];
		end
	end

	// ② 衰減乘法,再捨回暫存器格式
	logic signed [PRODUCT_WIDTH-1:0]  decay_product;    // A·V̂,小數 f_a + f_V 位
	logic signed [PRODUCT_WIDTH-1:0]  rounded_product;
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
	// D 一定落在 0 跟 V̂ 之間,取低 w 位不會丟資料;Δt=0 時直接用 V̂
	assign decayed = is_same_time ? membrane : shifted_product[MEMBRANE_WIDTH-1:0];

	// ③ 加權重碼
	logic signed [SUM_WIDTH-1:0] decayed_extended;
	logic signed [SUM_WIDTH-1:0] weight_extended;
	logic signed [SUM_WIDTH-1:0] unfitted;   // U,溢位處理之前的真實值

	// 有號數指定到較寬的變數會做符號延伸
	assign decayed_extended = decayed;
	assign weight_extended  = weight_code;
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

	assign spike        = (fitted >= threshold);
	assign new_membrane = spike ? '0 : fitted;

endmodule
