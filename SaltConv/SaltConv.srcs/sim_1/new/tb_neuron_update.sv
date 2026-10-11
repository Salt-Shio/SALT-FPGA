`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_neuron_update
// Description:
//   NeuronUpdate 驗證:每個向量的 (spike, new_membrane) 要等於訓練端整數更新(process_event)算出的答案。
//   答案是 scripts/gen_neuron_update_ref.py 產生的,格式見那支腳本;NeuronUpdate 是純組合邏輯,
//   一個向量送進輸入、#1 後比對輸出。
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   答案檔名照參數組出來,規則跟 gen_neuron_update_ref.py 的 stem、ref_file_name 相同。
//////////////////////////////////////////////////////////////////////////////////

module tb_neuron_update;

	// 預設值是訓練端 conv1 繞回版(round、繞回)
	parameter integer TIME_WIDTH          = 16;
	parameter integer WEIGHT_WIDTH        = 7;
	parameter integer MEMBRANE_INT_WIDTH  = 12;
	parameter integer MEMBRANE_FRAC_WIDTH = 0;
	parameter integer DECAY_FRAC_WIDTH    = 6;
	parameter integer DECAY_TABLE_DEPTH   = 75;
	parameter bit     ROUND               = 1;
	parameter bit     SATURATE            = 0;
	// 預設相對路徑是從 GUI 模擬的工作目錄 SaltConv.sim/<simset>/behav/xsim 算起
	parameter DECAY_FILE = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1/conv1_decay.mem";

	localparam integer MEMBRANE_WIDTH = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;

	logic signed [WEIGHT_WIDTH-1:0]   weight_code;
	logic signed [MEMBRANE_WIDTH-1:0] membrane;
	logic        [TIME_WIDTH-1:0]     last_time;
	logic        [TIME_WIDTH-1:0]     event_time;
	logic signed [MEMBRANE_WIDTH-1:0] threshold;
	logic                             spike;
	logic signed [MEMBRANE_WIDTH-1:0] new_membrane;

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
	) dut (
		.weight_code (weight_code),
		.membrane    (membrane),
		.last_time   (last_time),
		.event_time  (event_time),
		.threshold   (threshold),
		.spike       (spike),
		.new_membrane(new_membrane)
	);

	initial begin
		string ref_dir;
		string ref_path;
		string kind;
		int    ref_fd;
		int    scan_count;
		int    line_number;
		int    vector_count;
		int    expected_vector_count;
		int    error_count;
		int    vector_weight;
		int    vector_membrane;
		int    vector_last_time;
		int    vector_event_time;
		int    vector_threshold;
		int    expected_spike;
		int    expected_membrane;

		line_number  = 0;
		vector_count = 0;
		error_count  = 0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/neuron_update_B%0d_IV%0d_FV%0d_FA%0d_D%0d_T%0d_R%0d_S%0d.txt",
		                     ref_dir, WEIGHT_WIDTH, MEMBRANE_INT_WIDTH, MEMBRANE_FRAC_WIDTH, DECAY_FRAC_WIDTH,
		                     DECAY_TABLE_DEPTH, TIME_WIDTH, ROUND, SATURATE);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0)
			$fatal(1, "打不開答案檔 %s", ref_path);
		$display("DECAY_FILE=%s", DECAY_FILE);

		forever begin
			line_number++;
			scan_count = $fscanf(ref_fd, "%s", kind);
			if (scan_count != 1)
				$fatal(1, "答案檔第 %0d 行讀不到種類欄位,檔案沒有 end 行", line_number);

			if (kind == "end") begin
				scan_count = $fscanf(ref_fd, "%d", expected_vector_count);
				if (scan_count != 1)
					$fatal(1, "答案檔第 %0d 行 end 欄位不足", line_number);
				break;
			end
			if (kind != "vector")
				$fatal(1, "答案檔第 %0d 行種類 '%s' 不認得", line_number, kind);

			scan_count = $fscanf(ref_fd, "%d %d %d %d %d %d %d", vector_weight, vector_membrane, vector_last_time,
			                     vector_event_time, vector_threshold, expected_spike, expected_membrane);
			if (scan_count != 7)
				$fatal(1, "答案檔第 %0d 行 vector 欄位不足", line_number);

			weight_code = WEIGHT_WIDTH'(vector_weight);
			membrane    = MEMBRANE_WIDTH'(vector_membrane);
			last_time   = TIME_WIDTH'(vector_last_time);
			event_time  = TIME_WIDTH'(vector_event_time);
			threshold   = MEMBRANE_WIDTH'(vector_threshold);
			#1;
			if ($isunknown(spike) || $isunknown(new_membrane)
			    || spike != 1'(expected_spike) || int'(new_membrane) != expected_membrane) begin
				error_count++;
				$display("MISMATCH line=%0d q=%0d V=%0d t_last=%0d t=%0d v_th=%0d: expected=(spike %0d, V_new %0d) actual=(spike %0d, V_new %0d)",
				         line_number, vector_weight, vector_membrane, vector_last_time, vector_event_time,
				         vector_threshold, expected_spike, expected_membrane, spike, new_membrane);
			end
			vector_count++;
		end
		$fclose(ref_fd);

		if (vector_count != expected_vector_count) begin
			error_count++;
			$display("MISMATCH vector_count=%0d, end 行要 %0d", vector_count, expected_vector_count);
		end

		$display("TIME_WIDTH=%0d WEIGHT_WIDTH=%0d MEMBRANE_INT_WIDTH=%0d MEMBRANE_FRAC_WIDTH=%0d DECAY_FRAC_WIDTH=%0d DECAY_TABLE_DEPTH=%0d ROUND=%0d SATURATE=%0d: vector_count=%0d error_count=%0d %s",
		         TIME_WIDTH, WEIGHT_WIDTH, MEMBRANE_INT_WIDTH, MEMBRANE_FRAC_WIDTH, DECAY_FRAC_WIDTH, DECAY_TABLE_DEPTH,
		         ROUND, SATURATE, vector_count, error_count, (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
