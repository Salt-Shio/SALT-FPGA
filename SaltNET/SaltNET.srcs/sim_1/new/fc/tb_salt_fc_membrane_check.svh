//////////////////////////////////////////////////////////////////////////////////
// tb_salt_fc_membrane_check.svh
//   整層 SaltFC testbench(tb_salt_fc_no_spike.sv、tb_salt_fc_common.svh)共用的膜電位輸出檢查,
//   在 module 裡 `include,不單獨編譯。
//   答案檔每筆輸入事件一行 update:處理完這筆事件之後全部 n_out 顆的 V̂(gen_salt_fc_ref.py)。
//   SaltFC 每寫回一列送一筆(FC.md 第 6 節 ③),所以預期的順序是:第 0 筆事件第 0 列 … 第 n_row-1 列,第 1 筆事件第 0 列 …;
//   第 e 筆事件第 y 列那一筆的值是 update 行第 y*n_col 到 y*n_col + n_col - 1 顆,最後一列空的位置不比。
//   每拍(posedge 之前)檢查:membrane_valid 不是 X;MEMBRANE_OUTPUT = 0 時一直是 0;
//   有 valid 時 membrane_row_base、這一列真的神經元的值、membrane_time 等於下一筆預期的。
//   停住的拍子多送一次、少送一列,後面整串都會錯開,樣本結束時筆數也對不上。
//
//   include 這個檔案的 module 要先定義:
//     parameter OUT_NEURONS、NEURONS_PER_ROW、TIME_WIDTH、MEMBRANE_OUTPUT;localparam MEMBRANE_WIDTH、ROW_COUNT、OUT_NEURON_WIDTH
//     訊號 membrane_valid、membrane_row_base、membrane_values、membrane_time
//     int in_count(這筆樣本的輸入事件數)、function report_error(string)
//     先 include tb_salt_fc_update_lines.svh(預期值 expected_update_*),read_sample 讀完 out 行之後呼叫 read_update_lines
//////////////////////////////////////////////////////////////////////////////////

	int membrane_sent_count;        // 這筆樣本已經送出幾筆(事件, 列)
	int membrane_check_count = 0;   // 檢查過的筆數(全部樣本)

	// 每筆樣本開始前
	function automatic void start_membrane_check();
		membrane_sent_count = 0;
	endfunction

	// 每拍 posedge 之前呼叫
	function automatic void check_membrane_output(string where);
		int event_index, row;
		if ($isunknown(membrane_valid)) begin
			report_error($sformatf("%s membrane_valid=%b 是 X", where, membrane_valid));
			return;
		end
		if (!membrane_valid) return;
		if (!MEMBRANE_OUTPUT) begin
			report_error($sformatf("%s MEMBRANE_OUTPUT=0,membrane_valid=1", where));
			return;
		end
		if (membrane_sent_count >= in_count * ROW_COUNT) begin
			report_error($sformatf("%s 膜電位輸出多送了一筆:row_base=%0d t=%0d", where, membrane_row_base, membrane_time));
			membrane_sent_count++;
			return;
		end
		event_index = membrane_sent_count / ROW_COUNT;
		row         = membrane_sent_count % ROW_COUNT;
		if (membrane_row_base != OUT_NEURON_WIDTH'(row * NEURONS_PER_ROW) ||
		    membrane_time != TIME_WIDTH'(expected_update_t[event_index])) begin
			report_error($sformatf("%s 第 %0d 筆事件第 %0d 列:expected (row_base, t)=(%0d,%0d) actual=(%0d,%0d)", where,
			                       event_index, row, row * NEURONS_PER_ROW, expected_update_t[event_index],
			                       membrane_row_base, membrane_time));
		end
		for (int column = 0; column < NEURONS_PER_ROW; column++) begin
			int neuron;
			logic [MEMBRANE_WIDTH-1:0] membrane;
			neuron = row * NEURONS_PER_ROW + column;
			if (neuron >= OUT_NEURONS) break;   // 最後一列空的位置沒有意義
			membrane = membrane_values[column * MEMBRANE_WIDTH +: MEMBRANE_WIDTH];
			if (membrane !== MEMBRANE_WIDTH'(expected_update_membrane[event_index * OUT_NEURONS + neuron])) begin
				report_error($sformatf("%s 第 %0d 筆事件 neuron=%0d:expected=%0d actual=%0d", where, event_index, neuron,
				                       expected_update_membrane[event_index * OUT_NEURONS + neuron], $signed(membrane)));
			end
		end
		membrane_sent_count++;
		membrane_check_count++;
	endfunction

	// 樣本結束時:每筆事件送 n_row 筆;MEMBRANE_OUTPUT = 0 時一筆都沒有
	function automatic void check_membrane_count(int sample_index);
		int expected_count = MEMBRANE_OUTPUT ? in_count * ROW_COUNT : 0;
		if (membrane_sent_count != expected_count) begin
			report_error($sformatf("sample=%0d 膜電位輸出 %0d 筆,答案 %0d 筆", sample_index, membrane_sent_count,
			                       expected_count));
		end
	endfunction
