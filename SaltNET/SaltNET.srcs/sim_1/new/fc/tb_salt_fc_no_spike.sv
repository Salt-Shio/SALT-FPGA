`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_fc_no_spike
// Description:
//   整層 SaltFC,情況:不 fire(SPIKE_OUTPUT = 0)、上游一直有事件。答案由 scripts/fc/gen_salt_fc_ref.py 產生。
//   比對:
//     樣本結束時 n_out 顆神經元的 V̂,直接從 NeuronMemory 的記憶體內容讀出來比(最後一列空的位置不比);
//     時間暫存器 event_time 等於最後一筆事件的 t;
//     膜電位輸出(MEMBRANE_OUTPUT = 1)逐筆照「事件、列」的順序比,MEMBRANE_OUTPUT = 0 時一直不送,見 tb_salt_fc_membrane_check.svh;
//     拍數:第一列算的那一拍到最後一列送完那一拍,要等於答案(FC.md 第 5 節 ⑦⑧,中途多等、少等都會被抓到)。
//   每一拍檢查:
//     in_ready、out_valid 不是 X;out_valid 一直是 0(不 fire);清除期間 in_ready=0,FIFO 也沒有收進任何事件。
//     讀出的資料出來那一拍(位置 R 剛到),V̂ 寬字等於 NeuronMemory 陣列裡那一列(這一拍寫入之前),
//     權重寬字等於權重 ROM 裡 (y, src) 那一格;(y, src) 在讀下一列那一拍記下來,照順序對。
//     讀到還沒寫回的舊值(讀寫衝突沒擋住)時,陣列已經是新值,這一項在那一拍就抓到。
//   上游照 valid/ready 的規則:in_valid 拉高後資料不變,直到 in_ready=1 收走;清除期間也會拉高 in_valid。
//   每筆樣本跑一次,開始前用 rst_n 重來(清除神經元記憶體、時間暫存器)。
//   只用一個 initial 流程:negedge 驅動輸入、#1 等組合邏輯穩定後取樣,posedge 後 #1 依取樣結果判斷。
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   檔名照參數組出來,規則跟 gen_salt_fc_ref.py 的 ParamSet.stem 相同。
//   READ_LATENCY(R)、COMPUTE_LATENCY(C)、OVERLAP 不影響答案,只影響拍數:答案檔的 sample 行列出每組
//   (R, C, OVERLAP) 的拍數(順序見 gen_salt_conv_ref.py 的 CYCLE_CONFIGS),照自己的參數挑一個比。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_fc_no_spike;

	// 預設值是訓練端 out 層繞回版,n_col = 4
	parameter integer IN_NEURONS          = 1296;
	parameter integer OUT_NEURONS         = 10;
	parameter integer NEURONS_PER_ROW     = 4;
	parameter integer TIME_WIDTH          = 16;
	parameter integer WEIGHT_WIDTH        = 7;
	parameter integer MEMBRANE_INT_WIDTH  = 14;
	parameter integer MEMBRANE_FRAC_WIDTH = 0;
	parameter integer DECAY_FRAC_WIDTH    = 6;
	parameter integer DECAY_TABLE_DEPTH   = 75;
	parameter bit     ROUND               = 1;
	parameter bit     SATURATE            = 0;
	parameter integer FIFO_DEPTH          = 16;
	parameter integer READ_LATENCY        = 1;
	parameter integer COMPUTE_LATENCY     = 1;
	parameter bit     OVERLAP             = 0;
	parameter bit     MEMBRANE_OUTPUT     = 1;
	parameter WEIGHT_FILE = "../../../../SaltNET.srcs/sim_1/new/fc/ref/salt_fc_IN1296_OUT10_COL4_IV14_FV0_RD1_SAT0_SPK0_weight.mem";
	parameter DECAY_FILE  = "../../../../SaltNET.srcs/sim_1/new/fc/ref/salt_fc_IN1296_OUT10_COL4_IV14_FV0_RD1_SAT0_SPK0_decay.mem";

	// 跟 SaltFC 的 localparam 同一套公式
	localparam integer MEMBRANE_WIDTH      = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;
	localparam integer ROW_COUNT           = (OUT_NEURONS + NEURONS_PER_ROW - 1) / NEURONS_PER_ROW;
	localparam integer IN_NEURON_WIDTH     = (IN_NEURONS > 1) ? $clog2(IN_NEURONS) : 1;
	localparam integer OUT_NEURON_WIDTH    = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1;
	localparam integer WEIGHT_WORD_WIDTH   = NEURONS_PER_ROW * WEIGHT_WIDTH;
	localparam integer MEMBRANE_WORD_WIDTH = NEURONS_PER_ROW * MEMBRANE_WIDTH;
	localparam integer PIPELINE_DEPTH      = READ_LATENCY + COMPUTE_LATENCY - 1;

	localparam integer CLOCK_PERIOD = 10;
	localparam integer RESET_CYCLES = 3;
	localparam integer MAX_PRINTED  = 20;   // 錯誤訊息最多印幾筆,之後只計數
	// 答案檔 sample 行的拍數:R、C 各 1~2、OVERLAP 0~1,共 8 個,順序 ((R-1)*2 + (C-1))*2 + OVERLAP,
	// 跟 gen_salt_conv_ref.py 的 CYCLE_CONFIGS 相同
	localparam integer CYCLE_CONFIG_COUNT = 8;

	logic clk;
	logic rst_n;
	logic                                      in_valid;
	logic                                      in_ready;
	logic [IN_NEURON_WIDTH-1:0]                in_neuron;
	logic [TIME_WIDTH-1:0]                     in_time;
	logic                                      out_valid;
	logic                                      out_ready;
	logic [OUT_NEURON_WIDTH-1:0]               out_neuron;
	logic [TIME_WIDTH-1:0]                     out_time;
	logic                                      membrane_valid;
	logic [OUT_NEURON_WIDTH-1:0]               membrane_row_base;
	logic [NEURONS_PER_ROW*MEMBRANE_WIDTH-1:0] membrane_values;
	logic [TIME_WIDTH-1:0]                     membrane_time;

	SaltFC #(
		.IN_NEURONS         (IN_NEURONS),
		.OUT_NEURONS        (OUT_NEURONS),
		.NEURONS_PER_ROW    (NEURONS_PER_ROW),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.SPIKE_OUTPUT       (1'b0),
		.MEMBRANE_OUTPUT    (MEMBRANE_OUTPUT),
		.WEIGHT_FILE        (WEIGHT_FILE),
		.DECAY_FILE         (DECAY_FILE),
		.FIFO_DEPTH         (FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP)
	) dut (.*);

	initial clk = 1'b0;
	always #(CLOCK_PERIOD / 2) clk = ~clk;

	// ---------------------------------------------------------------
	// 一筆樣本的答案
	// ---------------------------------------------------------------
	int in_count, out_count, state_count, expected_cycle_count;
	int expected_in_src[$], expected_in_t[$];
	int state_neuron[$], state_membrane[$];
	int sent_row[$], sent_src[$];   // 讀過、資料還沒出來的 (y, src),照讀的順序

	// 統計
	int error_count       = 0;
	int run_count         = 0;
	int state_check_count = 0;
	int cycle_check_count = 0;
	int read_check_count  = 0;   // 檢查過讀出值的拍數(位置 R 剛到)

	function automatic string parameter_text();
		return $sformatf({"IN_NEURONS=%0d OUT_NEURONS=%0d NEURONS_PER_ROW=%0d TIME_WIDTH=%0d WEIGHT_WIDTH=%0d ",
		                  "MEMBRANE_INT_WIDTH=%0d MEMBRANE_FRAC_WIDTH=%0d DECAY_FRAC_WIDTH=%0d DECAY_TABLE_DEPTH=%0d ",
		                  "ROUND=%0d SATURATE=%0d FIFO_DEPTH=%0d READ_LATENCY=%0d COMPUTE_LATENCY=%0d OVERLAP=%0d ",
		                  "MEMBRANE_OUTPUT=%0d"},
		                 IN_NEURONS, OUT_NEURONS, NEURONS_PER_ROW, TIME_WIDTH, WEIGHT_WIDTH, MEMBRANE_INT_WIDTH,
		                 MEMBRANE_FRAC_WIDTH, DECAY_FRAC_WIDTH, DECAY_TABLE_DEPTH, ROUND, SATURATE, FIFO_DEPTH,
		                 READ_LATENCY, COMPUTE_LATENCY, OVERLAP, MEMBRANE_OUTPUT);
	endfunction

	function automatic void report_error(string message);
		if (error_count < MAX_PRINTED) begin
			$display("MISMATCH t=%0t %s", $time, message);
		end
		error_count++;
	endfunction

	`include "tb_salt_fc_update_lines.svh"
	`include "tb_salt_fc_membrane_check.svh"

	// 讀一筆樣本;讀到 end 回傳 0
	function automatic bit read_sample(int fd, int sample_index);
		string kind;
		int scan_count;
		int a, b;
		scan_count = $fscanf(fd, "%s", kind);
		if (scan_count != 1) begin
			$fatal(1, "答案檔第 %0d 筆樣本之前讀不到資料", sample_index);
		end
		if (kind == "end") begin
			scan_count = $fscanf(fd, "%d", a);
			if (scan_count != 1 || a != sample_index) begin
				$fatal(1, "答案檔 end 行的樣本數 %0d,實際讀到 %0d 筆", a, sample_index);
			end
			return 1'b0;
		end
		if (kind != "sample") begin
			$fatal(1, "答案檔第 %0d 筆樣本開頭不是 sample,是 %s", sample_index, kind);
		end
		scan_count = $fscanf(fd, "%d %d %d", in_count, out_count, state_count);
		if (scan_count != 3) $fatal(1, "sample 行格式不對");
		if (out_count != 0) $fatal(1, "樣本 %0d 的答案有 %0d 筆輸出,這支 testbench 只測不 fire", sample_index, out_count);
		if (state_count != OUT_NEURONS) $fatal(1, "樣本 %0d 的 state 數 %0d,n_out=%0d", sample_index, state_count, OUT_NEURONS);
		// 拍數:每組 (R, C, OVERLAP) 一個,挑自己那一組
		if (READ_LATENCY < 1 || READ_LATENCY > 2 || COMPUTE_LATENCY < 1 || COMPUTE_LATENCY > 2) begin
			$fatal(1, "READ_LATENCY=%0d COMPUTE_LATENCY=%0d,答案檔只有 R、C 各 1~2 的拍數", READ_LATENCY, COMPUTE_LATENCY);
		end
		for (int config_index = 0; config_index < CYCLE_CONFIG_COUNT; config_index++) begin
			scan_count = $fscanf(fd, "%d", a);
			if (scan_count != 1) $fatal(1, "sample 行少了第 %0d 組的拍數", config_index);
			if (config_index == ((READ_LATENCY - 1) * 2 + (COMPUTE_LATENCY - 1)) * 2 + OVERLAP) expected_cycle_count = a;
		end

		expected_in_src.delete(); expected_in_t.delete();
		for (int i = 0; i < in_count; i++) begin
			scan_count = $fscanf(fd, "%s %d %d", kind, a, b);
			if (scan_count != 3 || kind != "in") $fatal(1, "樣本 %0d 第 %0d 個 in 行格式不對", sample_index, i);
			expected_in_src.push_back(a); expected_in_t.push_back(b);
		end
		read_update_lines(fd, sample_index, in_count);
		state_neuron.delete(); state_membrane.delete();
		for (int i = 0; i < state_count; i++) begin
			scan_count = $fscanf(fd, "%s %d %d", kind, a, b);
			if (scan_count != 3 || kind != "state") $fatal(1, "樣本 %0d 第 %0d 個 state 行格式不對", sample_index, i);
			state_neuron.push_back(a); state_membrane.push_back(b);
		end
		return 1'b1;
	endfunction

	// 管線位置 1..L 有沒有列
	function automatic bit pipe_occupied();
		for (int position = 1; position <= PIPELINE_DEPTH; position++) begin
			if (dut.pipe_valid[position]) return 1'b1;
		end
		return 1'b0;
	endfunction

	// 讀出的資料出來那一拍:位置 R 的列剛到(停住的拍子位置上還是同一列,不算剛到)
	function automatic bit read_data_arrived();
		return dut.pipe_valid[READ_LATENCY] && !dut.pipe_held;
	endfunction

	// SaltFC 整個空下來:管線裡沒有列,FIFO 也沒有事件
	function automatic bit dut_idle();
		return !pipe_occupied() && !dut.fifo_read_valid && !dut.clearing;
	endfunction

	// 位置 R 剛到:讀出值要等於記憶體裡的內容;posedge 之前呼叫,記憶體還沒被這一拍寫入
	function automatic void check_read_data(string where);
		int row_sent, src_sent;
		logic [MEMBRANE_WORD_WIDTH-1:0] membrane_truth;
		logic [WEIGHT_WORD_WIDTH-1:0]   weight_truth;
		if (sent_row.size() == 0) begin
			report_error($sformatf("%s 資料出來了,可是沒有讀過", where));
			return;
		end
		row_sent = sent_row.pop_front();
		src_sent = sent_src.pop_front();
		if (row_sent != dut.pipe_row[READ_LATENCY]) begin
			report_error($sformatf("%s 位置 R 的列 y=%0d,讀的順序是 y=%0d", where, dut.pipe_row[READ_LATENCY], row_sent));
		end
		membrane_truth = dut.neuron_memory.memory_array.bank[row_sent];
		weight_truth   = dut.weight_memory.memory_array.rom[row_sent * IN_NEURONS + src_sent];
		if (dut.membrane_word !== membrane_truth) begin
			report_error($sformatf("%s V̂ 讀錯:y=%0d used=%h truth=%h", where, row_sent, dut.membrane_word, membrane_truth));
		end
		if (dut.weight_word !== weight_truth) begin
			report_error($sformatf("%s 權重讀錯:y=%0d src=%0d used=%h truth=%h", where, row_sent, src_sent,
			                       dut.weight_word, weight_truth));
		end
		read_check_count++;
	endfunction

	task automatic apply_reset();
		@(negedge clk);
		rst_n    = 1'b0;
		in_valid = 1'b0;
		repeat (RESET_CYCLES) @(negedge clk);
		rst_n = 1'b1;
	endtask

	// 一筆樣本
	task automatic run_sample(int sample_index);
		int  in_index            = 0;
		bit  presenting          = 1'b0;
		int  cycle               = 0;
		int  first_compute_cycle = -1;
		int  last_done_cycle     = -1;
		int  max_cycles;
		bit  sampled_in_handshake;
		string where;

		max_cycles = 4 * (expected_cycle_count + in_count) + ROW_COUNT + 1000;
		sent_row.delete();
		sent_src.delete();
		start_membrane_check();
		apply_reset();

		forever begin
			where = $sformatf("sample=%0d cycle=%0d", sample_index, cycle);

			// ---------------- negedge:驅動輸入(上游一直有事件) ----------------
			if (!presenting && in_index < in_count) begin
				presenting = 1'b1;
				in_neuron  = IN_NEURON_WIDTH'(expected_in_src[in_index]);
				in_time    = TIME_WIDTH'(expected_in_t[in_index]);
			end
			in_valid = presenting;
			#1;

			// ---------------- posedge 之前:取樣、檢查 ----------------
			if ($isunknown(out_valid) || $isunknown(in_ready)) begin
				report_error($sformatf("%s out_valid=%b in_ready=%b 是 X", where, out_valid, in_ready));
			end
			if (out_valid) report_error($sformatf("%s 不 fire 的層 out_valid=1", where));
			if (dut.clearing) begin
				if (in_ready) report_error($sformatf("%s 清除期間 in_ready=1", where));
				if (dut.fifo_read_valid) report_error($sformatf("%s 清除期間 FIFO 有事件", where));
			end

			if (dut.compute_cycle && first_compute_cycle < 0) first_compute_cycle = cycle;
			// 位置 L 的列這一拍送完
			if (dut.pipe_valid[PIPELINE_DEPTH] && !dut.stall) last_done_cycle = cycle;
			sampled_in_handshake = in_valid && in_ready;

			if (dut.read_next_row) begin
				sent_row.push_back(dut.read_row);
				sent_src.push_back(dut.read_src);
			end
			if (read_data_arrived()) check_read_data(where);
			check_membrane_output(where);

			// ---------------- posedge ----------------
			@(posedge clk);
			#1;
			cycle++;
			if (sampled_in_handshake) begin
				presenting = 1'b0;
				in_index++;
			end

			// 膜電位輸出暫存器晚 1 拍:最後一列寫回之後,下一拍才送出
			if (in_index == in_count && !presenting && dut_idle() && !membrane_valid) break;
			if (cycle > max_cycles) begin
				report_error($sformatf("%s 跑了 %0d 拍還沒結束:in %0d/%0d", where, cycle, in_index, in_count));
				break;
			end
			@(negedge clk);
		end

		check_membrane_count(sample_index);

		// 拍數:第一列算的那一拍到最後一列送完那一拍;中途多等、少等都會被抓到
		begin
			int measured = (first_compute_cycle < 0) ? 0 : last_done_cycle - first_compute_cycle + 1;
			if (measured != expected_cycle_count) begin
				report_error($sformatf("sample=%0d 拍數:expected=%0d actual=%0d", sample_index,
				                       expected_cycle_count, measured));
			end
			cycle_check_count++;
		end

		// 時間暫存器:最後一筆事件的 t(沒有事件時維持 reset 的 0)
		begin
			int expected_time = (in_count > 0) ? expected_in_t[in_count - 1] : 0;
			if (dut.event_time != TIME_WIDTH'(expected_time)) begin
				report_error($sformatf("sample=%0d event_time:expected=%0d actual=%0d", sample_index,
				                       expected_time, dut.event_time));
			end
		end

		// 神經元狀態:第 i 顆在第 i / n_col 列、第 i % n_col 段
		for (int i = 0; i < state_count; i++) begin
			logic [MEMBRANE_WORD_WIDTH-1:0]   word;
			logic signed [MEMBRANE_WIDTH-1:0] membrane;
			word     = dut.neuron_memory.memory_array.bank[state_neuron[i] / NEURONS_PER_ROW];
			membrane = word[(state_neuron[i] % NEURONS_PER_ROW) * MEMBRANE_WIDTH +: MEMBRANE_WIDTH];
			if (membrane != MEMBRANE_WIDTH'(state_membrane[i])) begin
				report_error($sformatf("sample=%0d neuron=%0d:expected=%0d actual=%0d", sample_index,
				                       state_neuron[i], state_membrane[i], membrane));
			end
			state_check_count++;
		end
		run_count++;
	endtask

	initial begin
		string ref_dir;
		string ref_path;
		int    ref_fd;
		int    sample_index;
		string verdict;

		rst_n     = 1'b0;
		in_valid  = 1'b0;
		out_ready = 1'b1;
		in_neuron = '0; in_time = '0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/salt_fc_IN%0d_OUT%0d_COL%0d_IV%0d_FV%0d_RD%0d_SAT%0d_SPK0.txt",
		                     ref_dir, IN_NEURONS, OUT_NEURONS, NEURONS_PER_ROW, MEMBRANE_INT_WIDTH,
		                     MEMBRANE_FRAC_WIDTH, ROUND, SATURATE);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0) $fatal(1, "打不開答案檔 %s", ref_path);

		sample_index = 0;
		while (read_sample(ref_fd, sample_index)) begin
			run_sample(sample_index);
			sample_index++;
		end
		$fclose(ref_fd);

		if (error_count == 0 && run_count > 0) verdict = "ALL PASS";
		else verdict = "FAIL";
		$display("%s: sample_count=%0d run_count=%0d membrane_check_count=%0d state_check_count=%0d cycle_check_count=%0d read_check_count=%0d error_count=%0d %s",
		         parameter_text(), sample_index, run_count, membrane_check_count, state_check_count, cycle_check_count,
		         read_check_count, error_count, verdict);
		$finish;
	end

endmodule
