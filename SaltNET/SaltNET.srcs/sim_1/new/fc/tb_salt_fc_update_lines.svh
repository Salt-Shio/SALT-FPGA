//////////////////////////////////////////////////////////////////////////////////
// tb_salt_fc_update_lines.svh
//   讀 gen_salt_fc_ref.py 答案檔的 update 行,在 module 裡 `include,不單獨編譯。
//   用到的:tb_salt_fc_membrane_check.svh(整層 SaltFC 的膜電位輸出)、tb_fc_membrane_register_common.svh。
//   每筆輸入事件一行:update <t> <V̂_0> ... <V̂_{n_out-1}>,處理完這筆事件之後全部 n_out 顆的 V̂。
//
//   include 這個檔案的 module 要先定義 parameter OUT_NEURONS。
//////////////////////////////////////////////////////////////////////////////////

	int expected_update_t[$];          // 第 e 筆事件的 t
	int expected_update_membrane[$];   // 第 e 筆事件之後第 i 顆的 V̂ 在 [e*n_out + i]

	// 讀一筆樣本的 update 行,event_count 行(= 這筆樣本的輸入事件數)
	function automatic void read_update_lines(int fd, int sample_index, int event_count);
		string kind;
		int    scan_count;
		int    t, membrane;
		expected_update_t.delete();
		expected_update_membrane.delete();
		for (int event_index = 0; event_index < event_count; event_index++) begin
			scan_count = $fscanf(fd, "%s %d", kind, t);
			if (scan_count != 2 || kind != "update") $fatal(1, "樣本 %0d 第 %0d 個 update 行格式不對", sample_index, event_index);
			expected_update_t.push_back(t);
			for (int neuron = 0; neuron < OUT_NEURONS; neuron++) begin
				scan_count = $fscanf(fd, "%d", membrane);
				if (scan_count != 1) $fatal(1, "樣本 %0d 第 %0d 個 update 行少了第 %0d 顆", sample_index, event_index, neuron);
				expected_update_membrane.push_back(membrane);
			end
		end
	endfunction
