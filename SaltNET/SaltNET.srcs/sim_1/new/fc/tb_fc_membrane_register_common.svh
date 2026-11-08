//////////////////////////////////////////////////////////////////////////////////
// tb_fc_membrane_register_common.svh
//   tb_fc_membrane_register_*.sv 兩支共用的部分,在各自的 module 裡 `include,不單獨編譯。
//   單獨測 FCMembraneRegister,不接 SaltFC:照 SaltFC 膜電位輸出的順序自己送列(第 0 筆事件第 0 列 … 第 n_row-1 列,
//   第 1 筆事件第 0 列 …),每列的值取答案檔 update 行(gen_salt_fc_ref.py,每筆事件之後全部 n_out 顆的 V̂)。
//   最後一列空的位置、membrane_valid=0 的拍子,值、y*n_col、t 都送亂數:寫進去或拉了脈衝就會被抓到。
//   每一拍(posedge 之前)檢查:
//     membranes 每一格等於 testbench 照「收到第 y 列就蓋掉那 n_col 格」記的值(reset 後全 0),
//     寫錯格、valid=0 也寫、沒寫進去都在那一拍抓到;
//     update_done 只在收到最後一列的下一拍是 1,那一拍 membranes 等於那筆事件的 update 行(上一項已經比),
//     update_time 等於那筆事件的 t;
//     update_done、membranes 不是 X。
//   每筆樣本跑一次,開始前用 rst_n 重來。
//   只用一個 initial 流程:negedge 驅動輸入、#1 取樣檢查,posedge 後 #1 照這一拍送的東西更新記的值。
//
//   include 這個檔案的 module 要在 include 之後(或之前)定義:
//     function automatic int idle_cycles_before_row();   送下一列之前空幾拍
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入;
//   答案檔是 <REF_DIR>/<REF_STEM>.txt,REF_STEM 跟 gen_salt_fc_ref.py 的 ParamSet.stem 相同。
//////////////////////////////////////////////////////////////////////////////////

	// 預設值是人工參數組 n_col = 3、會 fire、每顆一個門檻
	parameter integer OUT_NEURONS     = 10;
	parameter integer NEURONS_PER_ROW = 3;
	parameter integer MEMBRANE_WIDTH  = 6;
	parameter integer TIME_WIDTH      = 11;
	parameter REF_STEM = "salt_fc_IN7_OUT10_COL3_IV6_FV0_RD1_SAT0_SPK1_SH0";

	// 跟 FCMembraneRegister 的 localparam 同一套公式
	localparam integer ROW_COUNT        = (OUT_NEURONS + NEURONS_PER_ROW - 1) / NEURONS_PER_ROW;
	localparam integer OUT_NEURON_WIDTH = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1;

	localparam integer CLOCK_PERIOD = 10;
	localparam integer RESET_CYCLES = 3;
	localparam integer MAX_PRINTED  = 20;   // 錯誤訊息最多印幾筆,之後只計數
	// 答案檔 sample 行的拍數個數(這裡不用,跳過),跟 gen_salt_conv_ref.py 的 CYCLE_CONFIGS 相同
	localparam integer CYCLE_CONFIG_COUNT = 8;

	logic clk;
	logic rst_n;
	logic                                      membrane_valid;
	logic [OUT_NEURON_WIDTH-1:0]               membrane_row_base;
	logic [NEURONS_PER_ROW*MEMBRANE_WIDTH-1:0] membrane_values;
	logic [TIME_WIDTH-1:0]                     membrane_time;
	logic [OUT_NEURONS*MEMBRANE_WIDTH-1:0]     membranes;
	logic                                      update_done;
	logic [TIME_WIDTH-1:0]                     update_time;

	FCMembraneRegister #(
		.OUT_NEURONS    (OUT_NEURONS),
		.NEURONS_PER_ROW(NEURONS_PER_ROW),
		.MEMBRANE_WIDTH (MEMBRANE_WIDTH),
		.TIME_WIDTH     (TIME_WIDTH)
	) dut (.*);

	initial clk = 1'b0;
	always #(CLOCK_PERIOD / 2) clk = ~clk;

	// 統計
	int error_count       = 0;
	int run_count         = 0;
	int event_total       = 0;   // 送過的事件數(全部樣本)
	int cycle_check_count = 0;   // 比過 membranes 的拍數
	int done_check_count  = 0;   // 比過 update_time 的脈衝數

	function automatic string parameter_text();
		return $sformatf("OUT_NEURONS=%0d NEURONS_PER_ROW=%0d MEMBRANE_WIDTH=%0d TIME_WIDTH=%0d REF_STEM=%s",
		                 OUT_NEURONS, NEURONS_PER_ROW, MEMBRANE_WIDTH, TIME_WIDTH, REF_STEM);
	endfunction

	function automatic void report_error(string message);
		if (error_count < MAX_PRINTED) begin
			$display("MISMATCH t=%0t %s", $time, message);
		end
		error_count++;
	endfunction

	`include "tb_salt_fc_update_lines.svh"

	// 讀一筆樣本,只留 update 行;讀到 end 回傳 0。event_count 是這筆樣本的輸入事件數
	function automatic bit read_sample(int fd, int sample_index, output int event_count);
		string kind;
		int    scan_count;
		int    out_count, state_count, a, b;
		scan_count = $fscanf(fd, "%s", kind);
		if (scan_count != 1) $fatal(1, "答案檔第 %0d 筆樣本之前讀不到資料", sample_index);
		// 會 fire 的層第一行是 coverage,這裡用不到
		if (kind == "coverage") begin
			for (int i = 0; i < 5; i++) begin
				if ($fscanf(fd, "%d", a) != 1) $fatal(1, "coverage 行格式不對");
			end
			scan_count = $fscanf(fd, "%s", kind);
			if (scan_count != 1) $fatal(1, "coverage 行之後讀不到資料");
		end
		if (kind == "end") begin
			scan_count = $fscanf(fd, "%d", a);
			if (scan_count != 1 || a != sample_index) $fatal(1, "答案檔 end 行的樣本數 %0d,實際讀到 %0d 筆", a, sample_index);
			return 1'b0;
		end
		if (kind != "sample") $fatal(1, "答案檔第 %0d 筆樣本開頭不是 sample,是 %s", sample_index, kind);
		scan_count = $fscanf(fd, "%d %d %d", event_count, out_count, state_count);
		if (scan_count != 3) $fatal(1, "sample 行格式不對");
		for (int i = 0; i < CYCLE_CONFIG_COUNT; i++) begin
			if ($fscanf(fd, "%d", a) != 1) $fatal(1, "sample 行少了第 %0d 組的拍數", i);
		end
		for (int i = 0; i < event_count + out_count; i++) begin
			scan_count = $fscanf(fd, "%s %d %d", kind, a, b);
			if (scan_count != 3 || (kind != "in" && kind != "out")) $fatal(1, "樣本 %0d 的 in/out 行格式不對", sample_index);
		end
		read_update_lines(fd, sample_index, event_count);
		for (int i = 0; i < state_count; i++) begin
			scan_count = $fscanf(fd, "%s %d %d", kind, a, b);
			if (scan_count != 3 || kind != "state") $fatal(1, "樣本 %0d 第 %0d 個 state 行格式不對", sample_index, i);
		end
		return 1'b1;
	endfunction

	// testbench 記的每一格:收到第 y 列就蓋掉那 n_col 格
	logic [MEMBRANE_WIDTH-1:0] expected_membrane [0:OUT_NEURONS-1];
	bit                        expect_done;        // 這一拍 update_done 應該是 1(上一拍送的是最後一列)
	logic [TIME_WIDTH-1:0]     expected_done_time;

	task automatic apply_reset();
		@(negedge clk);
		rst_n          = 1'b0;
		membrane_valid = 1'b0;
		repeat (RESET_CYCLES) @(negedge clk);
		rst_n = 1'b1;
		for (int neuron = 0; neuron < OUT_NEURONS; neuron++) expected_membrane[neuron] = '0;
		expect_done = 1'b0;
	endtask

	// 一拍:negedge 驅動 → 檢查 → posedge → 照這一拍送的東西更新記的值。
	// send=1 時送第 event_index 筆事件的第 row 列;send=0 時 valid=0、其他亂數
	task automatic run_cycle(bit send, int event_index, int row, string where);
		// ---------------- negedge:驅動輸入 ----------------
		membrane_valid    = send;
		membrane_row_base = OUT_NEURON_WIDTH'($urandom);
		membrane_time     = TIME_WIDTH'($urandom);
		for (int column = 0; column < NEURONS_PER_ROW; column++) begin
			membrane_values[column * MEMBRANE_WIDTH +: MEMBRANE_WIDTH] = MEMBRANE_WIDTH'($urandom);
		end
		if (send) begin
			membrane_row_base = OUT_NEURON_WIDTH'(row * NEURONS_PER_ROW);
			membrane_time     = TIME_WIDTH'(expected_update_t[event_index]);
			for (int column = 0; column < NEURONS_PER_ROW; column++) begin
				int neuron;
				neuron = row * NEURONS_PER_ROW + column;
				if (neuron >= OUT_NEURONS) break;   // 最後一列空的位置留著亂數
				membrane_values[column * MEMBRANE_WIDTH +: MEMBRANE_WIDTH] =
					MEMBRANE_WIDTH'(expected_update_membrane[event_index * OUT_NEURONS + neuron]);
			end
		end
		#1;

		// ---------------- posedge 之前:檢查 ----------------
		if ($isunknown(update_done) || $isunknown(membranes)) begin
			report_error($sformatf("%s update_done=%b 或 membranes 是 X", where, update_done));
		end
		for (int neuron = 0; neuron < OUT_NEURONS; neuron++) begin
			logic [MEMBRANE_WIDTH-1:0] membrane;
			membrane = membranes[neuron * MEMBRANE_WIDTH +: MEMBRANE_WIDTH];
			if (membrane !== expected_membrane[neuron]) begin
				report_error($sformatf("%s neuron=%0d:expected=%0d actual=%0d", where, neuron,
				                       $signed(expected_membrane[neuron]), $signed(membrane)));
			end
		end
		cycle_check_count++;
		if (update_done !== expect_done) begin
			report_error($sformatf("%s update_done:expected=%b actual=%b", where, expect_done, update_done));
		end else if (expect_done) begin
			if (update_time !== expected_done_time) begin
				report_error($sformatf("%s update_time:expected=%0d actual=%0d", where, expected_done_time, update_time));
			end
			done_check_count++;
		end

		// ---------------- posedge ----------------
		@(posedge clk);
		#1;
		expect_done = send && row == ROW_COUNT - 1;
		if (send) begin
			for (int column = 0; column < NEURONS_PER_ROW; column++) begin
				int neuron;
				neuron = row * NEURONS_PER_ROW + column;
				if (neuron >= OUT_NEURONS) break;
				expected_membrane[neuron] = membrane_values[column * MEMBRANE_WIDTH +: MEMBRANE_WIDTH];
			end
			expected_done_time = membrane_time;
		end
	endtask

	// 一筆樣本:每筆事件照順序送 n_row 列,每列之前空 idle_cycles_before_row() 拍;最後再空 2 拍,看最後一個脈衝
	task automatic run_sample(int sample_index, int event_count);
		apply_reset();
		for (int event_index = 0; event_index < event_count; event_index++) begin
			for (int row = 0; row < ROW_COUNT; row++) begin
				int idle_cycles;
				idle_cycles = idle_cycles_before_row();
				for (int i = 0; i < idle_cycles; i++) begin
					run_cycle(1'b0, 0, 0, $sformatf("sample=%0d event=%0d row=%0d idle", sample_index, event_index, row));
				end
				run_cycle(1'b1, event_index, row, $sformatf("sample=%0d event=%0d row=%0d", sample_index, event_index, row));
			end
		end
		repeat (2) run_cycle(1'b0, 0, 0, $sformatf("sample=%0d end", sample_index));
		event_total += event_count;
		run_count++;
	endtask

	initial begin
		string ref_dir;
		string ref_path;
		int    ref_fd;
		int    sample_index;
		int    event_count;
		string verdict;

		// 亂數不另外設種子:xsim 不支援 $urandom(seed),用預設的 -sv_seed,每次跑都是同一串
		rst_n             = 1'b0;
		membrane_valid    = 1'b0;
		membrane_row_base = '0;
		membrane_values   = '0;
		membrane_time     = '0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/%s.txt", ref_dir, REF_STEM);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0) $fatal(1, "打不開答案檔 %s", ref_path);

		sample_index = 0;
		while (read_sample(ref_fd, sample_index, event_count)) begin
			run_sample(sample_index, event_count);
			sample_index++;
		end
		$fclose(ref_fd);

		// 每筆事件的最後一列之後都要有一拍 update_done
		if (done_check_count != event_total) begin
			report_error($sformatf("update_done %0d 次,事件 %0d 筆", done_check_count, event_total));
		end
		if (error_count == 0 && run_count > 0) verdict = "ALL PASS";
		else verdict = "FAIL";
		$display("%s: sample_count=%0d run_count=%0d event_count=%0d cycle_check_count=%0d done_check_count=%0d error_count=%0d %s",
		         parameter_text(), sample_index, run_count, event_total, cycle_check_count, done_check_count,
		         error_count, verdict);
		$finish;
	end
