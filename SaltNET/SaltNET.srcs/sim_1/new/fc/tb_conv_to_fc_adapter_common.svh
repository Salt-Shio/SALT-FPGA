//////////////////////////////////////////////////////////////////////////////////
// tb_conv_to_fc_adapter_common.svh
//   tb_conv_to_fc_adapter_*.sv 兩支共用的部分,在各自的 module 裡 `include,不單獨編譯。
//   單獨測 ConvToFCAdapter,上游(conv)、下游(SaltFC 的輸入)都是 testbench:
//   照答案檔的順序送座標 (o_x, o_y, o_c, t),送出去的那筆沒被收下就維持不變;沒送的拍子 in_valid=0、座標送亂數。
//   testbench 記一份「已經收進來、還沒送出去」的清單,每一拍(posedge 之前)檢查:
//     out_valid = 清單不是空的(收進來的下一拍就要送,送走了就要放掉);
//     out_valid=1 時 out_neuron、out_time 等於清單第一筆的 src、t(下游不收的拍子也比,值不能變);
//     in_ready = 清單是空的,或下游這一拍收(寫在 FC.md 第 1 節的規則);
//     in_ready、out_valid 不是 X。
//   清單就是事件的順序:掉資料、重複送、順序錯、換算錯都會在某一拍對不上。全部送完、清單空了之後再跑 3 拍,不能多送。
//   只用一個 initial 流程:negedge 驅動輸入、#1 取樣檢查,posedge 後 #1 照這一拍的交握更新清單。
//
//   include 這個檔案的 module 要定義:
//     function automatic bit upstream_sends();     沒有卡住的那筆時,這一拍上游要不要送下一筆
//     function automatic bit downstream_ready();   這一拍下游收不收
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入;
//   答案檔是 <REF_DIR>/<REF_STEM>.txt,REF_STEM 跟 gen_conv_to_fc_adapter_ref.py 的 ref_file_stem 相同。
//////////////////////////////////////////////////////////////////////////////////

	// 預設值是人工參數組:都不是 2 的次方、列數跟行數不同
	parameter integer IN_CHANNELS = 3;
	parameter integer IN_ROWS     = 5;
	parameter integer IN_COLS     = 7;
	parameter integer TIME_WIDTH  = 16;
	parameter REF_STEM = "conv_to_fc_adapter_C3_H5_W7_T16";

	// 跟 ConvToFCAdapter 的 localparam 同一套公式
	localparam integer IN_CHANNEL_WIDTH = (IN_CHANNELS > 1) ? $clog2(IN_CHANNELS) : 1;
	localparam integer IN_Y_WIDTH       = (IN_ROWS > 1) ? $clog2(IN_ROWS) : 1;
	localparam integer IN_X_WIDTH       = (IN_COLS > 1) ? $clog2(IN_COLS) : 1;
	localparam integer OUT_NEURONS      = IN_CHANNELS * IN_ROWS * IN_COLS;
	localparam integer OUT_NEURON_WIDTH = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1;

	localparam integer CLOCK_PERIOD = 10;
	localparam integer RESET_CYCLES = 3;
	localparam integer END_CYCLES   = 3;    // 全部送完之後多跑幾拍,看有沒有多送
	localparam integer MAX_PRINTED  = 20;   // 錯誤訊息最多印幾筆,之後只計數

	logic clk;
	logic rst_n;
	logic                        in_valid;
	logic                        in_ready;
	logic [IN_X_WIDTH-1:0]       in_x;
	logic [IN_Y_WIDTH-1:0]       in_y;
	logic [IN_CHANNEL_WIDTH-1:0] in_channel;
	logic [TIME_WIDTH-1:0]       in_time;
	logic                        out_valid;
	logic                        out_ready;
	logic [OUT_NEURON_WIDTH-1:0] out_neuron;
	logic [TIME_WIDTH-1:0]       out_time;

	ConvToFCAdapter #(
		.IN_CHANNELS(IN_CHANNELS),
		.IN_ROWS    (IN_ROWS),
		.IN_COLS    (IN_COLS),
		.TIME_WIDTH (TIME_WIDTH)
	) dut (.*);

	initial clk = 1'b0;
	always #(CLOCK_PERIOD / 2) clk = ~clk;

	// 統計
	int error_count  = 0;
	int cycle_count  = 0;   // reset 之後跑了幾拍
	int output_count = 0;   // 下游收到幾筆

	function automatic string parameter_text();
		return $sformatf("IN_CHANNELS=%0d IN_ROWS=%0d IN_COLS=%0d TIME_WIDTH=%0d REF_STEM=%s",
		                 IN_CHANNELS, IN_ROWS, IN_COLS, TIME_WIDTH, REF_STEM);
	endfunction

	function automatic void report_error(string message);
		if (error_count < MAX_PRINTED) begin
			$display("MISMATCH t=%0t %s", $time, message);
		end
		error_count++;
	endfunction

	// 答案檔:第 i 筆事件的座標、t 跟預期的 src
	int expected_x[$];
	int expected_y[$];
	int expected_channel[$];
	int expected_time[$];
	int expected_source[$];

	function automatic void read_reference(int fd);
		string kind;
		int    x, y, channel, event_time, source, count;
		forever begin
			if ($fscanf(fd, "%s", kind) != 1) $fatal(1, "答案檔第 %0d 筆之後讀不到資料", expected_source.size());
			if (kind == "end") begin
				if ($fscanf(fd, "%d", count) != 1 || count != expected_source.size())
					$fatal(1, "答案檔 end 行的筆數 %0d,實際讀到 %0d 筆", count, expected_source.size());
				return;
			end
			if (kind != "event" || $fscanf(fd, "%d %d %d %d %d", x, y, channel, event_time, source) != 5)
				$fatal(1, "答案檔第 %0d 筆格式不對", expected_source.size());
			expected_x.push_back(x);
			expected_y.push_back(y);
			expected_channel.push_back(channel);
			expected_time.push_back(event_time);
			expected_source.push_back(source);
		end
	endfunction

	// 已經收進來、還沒送出去的事件編號,第一筆是下一個要送的
	int pending_events[$];
	int next_event = 0;   // 下一筆要送進去的事件編號
	bit holding    = 0;   // 上一拍送出的那筆沒被收下,這一拍要維持

	task automatic apply_reset();
		@(negedge clk);
		rst_n     = 1'b0;
		in_valid  = 1'b0;
		out_ready = 1'b0;
		repeat (RESET_CYCLES) @(negedge clk);
		rst_n = 1'b1;
	endtask

	// 一拍:negedge 驅動 → 檢查 → posedge → 照這一拍的交握更新清單
	task automatic run_cycle();
		bit input_taken;
		bit output_taken;
		string where;
		where = $sformatf("cycle=%0d next_event=%0d", cycle_count, next_event);

		// ---------------- negedge:驅動輸入 ----------------
		if (!holding) begin
			in_valid   = next_event < expected_source.size() && upstream_sends();
			in_x       = IN_X_WIDTH'($urandom);
			in_y       = IN_Y_WIDTH'($urandom);
			in_channel = IN_CHANNEL_WIDTH'($urandom);
			in_time    = TIME_WIDTH'($urandom);
			if (in_valid) begin
				in_x       = IN_X_WIDTH'(expected_x[next_event]);
				in_y       = IN_Y_WIDTH'(expected_y[next_event]);
				in_channel = IN_CHANNEL_WIDTH'(expected_channel[next_event]);
				in_time    = TIME_WIDTH'(expected_time[next_event]);
			end
		end
		out_ready = downstream_ready();
		#1;

		// ---------------- posedge 之前:檢查 ----------------
		if ($isunknown(in_ready) || $isunknown(out_valid)) begin
			report_error($sformatf("%s in_ready=%b out_valid=%b 是 X", where, in_ready, out_valid));
		end
		if (out_valid !== (pending_events.size() > 0)) begin
			report_error($sformatf("%s out_valid:expected=%b actual=%b(還沒送出去的 %0d 筆)", where,
			                       pending_events.size() > 0, out_valid, pending_events.size()));
		end else if (out_valid) begin
			int event_index;
			event_index = pending_events[0];
			if (out_neuron !== OUT_NEURON_WIDTH'(expected_source[event_index]) ||
			    out_time !== TIME_WIDTH'(expected_time[event_index])) begin
				report_error($sformatf("%s event=%0d (o_x,o_y,o_c)=(%0d,%0d,%0d):expected src=%0d t=%0d actual src=%0d t=%0d",
				                       where, event_index, expected_x[event_index], expected_y[event_index],
				                       expected_channel[event_index], expected_source[event_index],
				                       expected_time[event_index], out_neuron, out_time));
			end
		end
		if (in_ready !== (pending_events.size() == 0 || out_ready)) begin
			report_error($sformatf("%s in_ready:expected=%b actual=%b(還沒送出去的 %0d 筆,out_ready=%b)", where,
			                       pending_events.size() == 0 || out_ready, in_ready, pending_events.size(), out_ready));
		end
		input_taken  = in_valid && in_ready;
		output_taken = out_valid && out_ready;

		// ---------------- posedge ----------------
		@(posedge clk);
		#1;
		if (output_taken && pending_events.size() > 0) begin
			void'(pending_events.pop_front());
			output_count++;
		end
		if (input_taken) begin
			pending_events.push_back(next_event);
			next_event++;
		end
		holding = in_valid && !input_taken;
		cycle_count++;
	endtask

	initial begin
		string ref_dir;
		string ref_path;
		int    ref_fd;
		int    cycle_limit;
		string verdict;

		// 亂數不另外設種子:xsim 不支援 $urandom(seed),用預設的 -sv_seed,每次跑都是同一串
		rst_n      = 1'b0;
		in_valid   = 1'b0;
		in_x       = '0;
		in_y       = '0;
		in_channel = '0;
		in_time    = '0;
		out_ready  = 1'b0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/%s.txt", ref_dir, REF_STEM);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0) $fatal(1, "打不開答案檔 %s", ref_path);
		read_reference(ref_fd);
		$fclose(ref_fd);

		apply_reset();
		// 隨機的上下游最壞一筆也要幾拍才過得去,給足夠的上限,超過就當成卡死
		cycle_limit = 20 * expected_source.size() + 100;
		while ((next_event < expected_source.size() || pending_events.size() > 0) && cycle_count < cycle_limit) begin
			run_cycle();
		end
		if (cycle_count >= cycle_limit) begin
			report_error($sformatf("%0d 拍內沒送完:送進去 %0d 筆、下游收到 %0d 筆", cycle_limit, next_event, output_count));
		end
		repeat (END_CYCLES) run_cycle();

		if (output_count != expected_source.size()) begin
			report_error($sformatf("下游收到 %0d 筆,答案 %0d 筆", output_count, expected_source.size()));
		end
		if (error_count == 0 && output_count > 0) verdict = "ALL PASS";
		else verdict = "FAIL";
		$display("%s: event_count=%0d output_count=%0d cycle_count=%0d error_count=%0d %s",
		         parameter_text(), expected_source.size(), output_count, cycle_count, error_count, verdict);
		$finish;
	end
