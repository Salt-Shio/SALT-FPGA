`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_fsm_config_setter.sv
// FsmConfigSetter 單元測試。
//
// 這份取代了原本「master 行為固定死板(每次都循序、單筆做完才做下一筆)」的版本——
// 前一版就是因為 master 永遠不會提前送下一筆請求,才漏掉了 AR/AW/W 三個 channel
// 的 ready 產生邏輯沒有跟 RVALID/BVALID 互鎖這個 bug。這版的 master 行為改成:
//   - 送 AR/AW/W 之前的延遲隨機
//   - AW 跟 W 同一拍到齊 / AW 先到 / W 先到,三種隨機挑
//   - RREADY/BREADY 收東西前故意拖幾拍(backpressure)隨機
//   - 讀寫位址、順序隨機交錯
// 另外加一個全程平行監看的 protocol checker(RVALID 跟 ARREADY 互斥、BVALID 跟
// AWREADY/WREADY 互斥),不管 master 這輪隨機出來的行為有沒有剛好踩到那個情境,
// 只要規則被打破就報錯,不能只靠隨機碰運氣。
//
// 跟其他 testbench 一樣,所有取樣/驅動都對齊到 tick()(posedge 後 1ns),
// 避開跟 DUT 自己的 always_ff 在同一個 edge 上競爭。
//////////////////////////////////////////////////////////////////////////////////

module tb_fsm_config_setter;

	localparam integer DATA_W = 32;
	localparam integer ADDR_W = 32;

	logic clk = 0;
	logic rstn = 0;

	logic [ADDR_W-1:0] awaddr;
	logic [2:0]         awprot = '0;
	logic                awvalid = 0;
	logic                awready;
	logic [DATA_W-1:0]  wdata;
	logic [(DATA_W/8)-1:0] wstrb;
	logic                wvalid = 0;
	logic                wready;
	logic [1:0]          bresp;
	logic                bvalid;
	logic                bready = 0;
	logic [ADDR_W-1:0]  araddr;
	logic [2:0]          arprot = '0;
	logic                arvalid = 0;
	logic                arready;
	logic [DATA_W-1:0]  rdata;
	logic [1:0]          rresp;
	logic                rvalid;
	logic                rready = 0;

	logic cfg_enable, cfg_enable_pattern, cfg_tlast_timeout_enable, cfg_soft_reset, cfg_fifo_clear;
	logic [15:0] cfg_tlast_timeout;

	FsmConfigSetter #(
		.C_S_AXI_DATA_WIDTH(DATA_W),
		.C_S_AXI_ADDR_WIDTH(ADDR_W)
	) dut (
		.S_AXI_ACLK(clk),
		.S_AXI_ARESETN(rstn),
		.S_AXI_AWADDR(awaddr),
		.S_AXI_AWPROT(awprot),
		.S_AXI_AWVALID(awvalid),
		.S_AXI_AWREADY(awready),
		.S_AXI_WDATA(wdata),
		.S_AXI_WSTRB(wstrb),
		.S_AXI_WVALID(wvalid),
		.S_AXI_WREADY(wready),
		.S_AXI_BRESP(bresp),
		.S_AXI_BVALID(bvalid),
		.S_AXI_BREADY(bready),
		.S_AXI_ARADDR(araddr),
		.S_AXI_ARPROT(arprot),
		.S_AXI_ARVALID(arvalid),
		.S_AXI_ARREADY(arready),
		.S_AXI_RDATA(rdata),
		.S_AXI_RRESP(rresp),
		.S_AXI_RVALID(rvalid),
		.S_AXI_RREADY(rready),
		.cfg_enable(cfg_enable),
		.cfg_enable_pattern(cfg_enable_pattern),
		.cfg_tlast_timeout(cfg_tlast_timeout),
		.cfg_tlast_timeout_enable(cfg_tlast_timeout_enable),
		.cfg_soft_reset(cfg_soft_reset),
		.cfg_fifo_clear(cfg_fifo_clear)
	);

	always #5 clk = ~clk;

	task automatic tick();
		@(posedge clk);
		#1;
	endtask

	int error_count = 0;

	// ---------------- 單一 channel 的 handshake building block ----------------
	// 條件一定要在跨過 edge 之前檢查(這代表「即將到來的這個 edge 會不會成立握手」),
	// 檢查完不管成不成立都跨過一次 edge——成立的話,這次 tick() 就是真正發生握手的
	// 那個 edge;不能反過來在 tick() 之後才檢查,那樣看到的是 DUT 已經反應過的新值
	// (ready 剛被收下去掉回 0),會誤判成「還沒握手」,永遠等不到。
	task automatic aw_handshake(input logic [ADDR_W-1:0] addr);
		bit done;
		awaddr = addr; awvalid = 1'b1;
		done = 1'b0;
		while (!done) begin
			if (awvalid && awready) done = 1'b1;
			tick();
		end
		awvalid = 1'b0;
	endtask

	task automatic w_handshake(input logic [DATA_W-1:0] data);
		bit done;
		wdata = data; wstrb = '1; wvalid = 1'b1;
		done = 1'b0;
		while (!done) begin
			if (wvalid && wready) done = 1'b1;
			tick();
		end
		wvalid = 1'b0;
	endtask

	task automatic b_handshake();
		bit done;
		bready = 1'b1;
		done = 1'b0;
		while (!done) begin
			if (bvalid && bready) done = 1'b1;
			tick();
		end
		bready = 1'b0;
	endtask

	task automatic ar_handshake(input logic [ADDR_W-1:0] addr);
		bit done;
		araddr = addr; arvalid = 1'b1;
		done = 1'b0;
		while (!done) begin
			if (arvalid && arready) done = 1'b1;
			tick();
		end
		arvalid = 1'b0;
	endtask

	task automatic r_handshake(output logic [DATA_W-1:0] data);
		bit done;
		rready = 1'b1;
		done = 1'b0;
		while (!done) begin
			if (rvalid && rready) begin
				data = rdata;
				done = 1'b1;
			end
			tick();
		end
		rready = 1'b0;
	endtask

	// ---------------- 軟體端獨立追蹤的參考狀態(shadow model) ----------------
	logic [DATA_W-1:0] shadow [0:15];

	// ---------------- 組合出一次完整的 write / read,行為(順序、延遲)由參數決定 ----------------
	// order: 0 = AW、W 同一拍到齊(fork 平行送出);1 = AW 先到;2 = W 先到
	task automatic do_write(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] data,
	                         input int order, input int gap, input int post_delay);
		if (order == 0) begin
			fork
				aw_handshake(addr);
				w_handshake(data);
			join
		end else if (order == 1) begin
			aw_handshake(addr);
			repeat (gap) tick();
			w_handshake(data);
		end else begin
			w_handshake(data);
			repeat (gap) tick();
			aw_handshake(addr);
		end
		repeat (post_delay) tick();
		b_handshake();
		shadow[addr[5:2]] = data;
	endtask

	task automatic do_read(input logic [ADDR_W-1:0] addr, output logic [DATA_W-1:0] data,
	                        input int pre_delay, input int post_delay);
		repeat (pre_delay) tick();
		ar_handshake(addr);
		repeat (post_delay) tick();
		r_handshake(data);
	endtask

	// 給「有明確預期值」的直接測試用,行為固定(不隨機),方便對照
	task automatic axi_write(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] data);
		do_write(addr, data, 0, 0, 0);
	endtask

	task automatic axi_read(input logic [ADDR_W-1:0] addr, output logic [DATA_W-1:0] data);
		do_read(addr, data, 0, 0);
	endtask

	// 給隨機迴圈用:延遲、AW/W 順序、backpressure 全部隨機
	task automatic rand_write(input logic [3:0] idx);
		logic [ADDR_W-1:0] addr;
		logic [DATA_W-1:0] data;
		addr = {26'd0, idx, 2'd0};
		data = $urandom();
		do_write(addr, data, $urandom_range(0, 2), $urandom_range(0, 3), $urandom_range(0, 4));
	endtask

	task automatic rand_read_check(input logic [3:0] idx);
		logic [ADDR_W-1:0] addr;
		logic [DATA_W-1:0] data;
		addr = {26'd0, idx, 2'd0};
		do_read(addr, data, $urandom_range(0, 3), $urandom_range(0, 4));
		if (data !== shadow[idx]) begin
			$error("[%0t] 隨機測試:idx=%0d read-back 不對,got=%h expect=%h", $time, idx, data, shadow[idx]);
			error_count++;
		end
	endtask

	task automatic check_eq(input string name, input logic [DATA_W-1:0] got, input logic [DATA_W-1:0] exp);
		if (got !== exp) begin
			$error("%s 不對: got=%h expect=%h", name, got, exp);
			error_count++;
		end
	endtask

	// ---------------- protocol checker:全程平行監看,不管 master 這輪剛好做了什麼 ----------------
	// 這是防止「master 剛好都沒測到那個情境」的關鍵——不靠隨機碰運氣,規則被打破就直接報錯。
	always @(posedge clk) begin
		#1;
		if (rstn) begin
			if (rvalid && arready && !rready) begin
				$error("[%0t] 違反 protocol:RVALID=1、RREADY=0(舊資料沒被拿走)的時候 ARREADY 不該是 1", $time);
				error_count++;
			end
			if (bvalid && (awready || wready)) begin
				$error("[%0t] 違反 protocol:BVALID=1 的時候 AWREADY/WREADY 不該是 1(busy 卻還說可以收新請求)", $time);
				error_count++;
			end
		end
	end

	// ---------------- 明確重現「第二筆請求在第一筆還沒收完就送出」的情境 ----------------
	// 現在預期:第二筆會被正確擋住(ready 不拉高),等第一筆收完之後,不用重送,
	// 直接就能繼續完成——不會像修之前那樣永久卡死。
	task automatic stress_read_overlap();
		logic [DATA_W-1:0] d1, d2;
		int guard;

		axi_write(32'h00, 32'hAAAA_0001);
		axi_write(32'h04, 32'hBBBB_0002);

		ar_handshake(32'h00); // read1 的位址先被接受
		// 故意不理 read1,馬上嘗試送 read2 的位址(這時候 read1 的資料還卡著)
		araddr = 32'h04; arvalid = 1'b1;
		repeat (10) tick(); // 撐著,protocol checker 全程盯著 RVALID/ARREADY 互斥有沒有被打破

		r_handshake(d1); // 現在才把 read1 的資料收走

		// read1 收完之後,read2(還撐著沒收回)應該能繼續正常完成,不用重送
		guard = 0;
		while (!(rvalid && rready) && guard < 50) begin
			rready = 1'b1;
			tick();
			guard++;
		end
		if (guard >= 50) begin
			$error("[%0t] === 卡死重現:read2(0x04) 在 read1 收完之後,等了 50 拍還是沒有 RVALID ===", $time);
			error_count++;
		end else begin
			d2 = rdata;
		end
		arvalid = 1'b0;
		tick();
		rready = 1'b0;

		check_eq("stress_read_overlap read1", d1, shadow[0]);
		if (guard < 50) check_eq("stress_read_overlap read2", d2, shadow[1]);
	endtask

	task automatic stress_write_overlap();
		logic [DATA_W-1:0] d;
		int guard;

		fork
			aw_handshake(32'h08);
			w_handshake(32'h1111_2222);
		join
		shadow[2] = 32'h1111_2222;

		// 故意不理 write1 的 BVALID,馬上嘗試送 write2 的 AW/W
		awaddr = 32'h0C; awvalid = 1'b1;
		wdata  = 32'h3333_4444; wstrb = '1; wvalid = 1'b1;
		repeat (10) tick(); // 撐著,protocol checker 全程盯著 BVALID/AWREADY/WREADY 互斥有沒有被打破

		b_handshake(); // 現在才把 write1 的回應收走

		// write1 收完之後,write2(還撐著沒收回)應該能繼續正常完成,不用重送。
		// 注意:aw_hs/w_hs 一定要在 tick() 之前先取樣(跨過 edge 之前的值),
		// 清 awvalid/wvalid 則要等 tick() 真的跨過那個 edge 之後才能做——
		// 不能在跨過 edge 之前就把 valid 收回,不然 DUT 那個 edge 根本沒看到 valid=1。
		guard = 0;
		while (!(bvalid && bready) && guard < 50) begin
			automatic bit aw_hs = (awvalid && awready);
			automatic bit w_hs  = (wvalid && wready);
			bready = 1'b1;
			tick();
			if (aw_hs) awvalid = 1'b0;
			if (w_hs)  wvalid  = 1'b0;
			guard++;
		end
		if (guard >= 50) begin
			$error("[%0t] === 卡死重現:write2(0x0C) 在 write1 收完之後,等了 50 拍還是沒有 BVALID ===", $time);
			error_count++;
		end else begin
			shadow[3] = 32'h3333_4444;
		end
		awvalid = 1'b0; wvalid = 1'b0;
		tick();
		bready = 1'b0;

		axi_read(32'h08, d);
		check_eq("stress_write_overlap write1 read-back", d, shadow[2]);
		if (guard < 50) begin
			axi_read(32'h0C, d);
			check_eq("stress_write_overlap write2 read-back", d, shadow[3]);
		end
	endtask

	task automatic do_reset();
		int i;
		rstn = 0;
		repeat (5) tick();
		rstn = 1;
		tick();
		for (i = 0; i < 16; i++) shadow[i] = '0;
	endtask

	initial begin
		logic [DATA_W-1:0] rd;
		int i, idx;

		do_reset();

		// --- reset 後的預設值:REG_CONFIG.tlast_timeout_enable 應該是 0(關閉),
		//     REG_TLAST_TIMEOUT 應該是非 0 的安全預設值,兩者是雙重防線,
		//     不能讓 reset 完、PS 還沒設定前就發生「每筆都掛 tlast」的空窗期 ---
		if (cfg_tlast_timeout_enable !== 1'b0) begin
			$error("reset 後 cfg_tlast_timeout_enable 應該為 0(關閉)");
			error_count++;
		end
		if (cfg_tlast_timeout === 16'h0) begin
			$error("reset 後 cfg_tlast_timeout 不應該是 0(需要非 0 安全預設值)");
			error_count++;
		end

		// --- 具名暫存器 write 後 read-back ---
		axi_write(32'h00, 32'h0000_0001); // REG_CONTROL.enable=1
		axi_read(32'h00, rd);
		check_eq("REG_CONTROL read-back", rd, 32'h0000_0001);
		if (cfg_enable !== 1'b1) begin
			$error("cfg_enable 應該為 1");
			error_count++;
		end

		axi_write(32'h04, 32'h0000_0003); // REG_CONFIG.enable_pattern=1, tlast_timeout_enable=1
		axi_read(32'h04, rd);
		check_eq("REG_CONFIG read-back", rd, 32'h0000_0003);
		if (cfg_enable_pattern !== 1'b1) begin
			$error("cfg_enable_pattern 應該為 1");
			error_count++;
		end
		if (cfg_tlast_timeout_enable !== 1'b1) begin
			$error("cfg_tlast_timeout_enable 應該為 1");
			error_count++;
		end

		axi_write(32'h08, 32'h0000_1234); // REG_TLAST_TIMEOUT
		axi_read(32'h08, rd);
		check_eq("REG_TLAST_TIMEOUT read-back", rd, 32'h0000_1234);
		if (cfg_tlast_timeout !== 16'h1234) begin
			$error("cfg_tlast_timeout 應該為 0x1234");
			error_count++;
		end

		// --- 除錯後門:任意未具名位址讀寫 ---
		axi_write(32'h20, 32'hDEAD_BEEF);
		axi_read(32'h20, rd);
		check_eq("除錯後門 0x20 read-back", rd, 32'hDEAD_BEEF);

		axi_write(32'h3C, 32'hCAFE_F00D); // 最後一個 index(15)
		axi_read(32'h3C, rd);
		check_eq("除錯後門 0x3C read-back", rd, 32'hCAFE_F00D);

		// --- REG_CONTROL.soft_reset / fifo_clear ---
		axi_write(32'h00, 32'h0000_0007); // enable=1, soft_reset=1, fifo_clear=1
		tick();
		if (cfg_soft_reset !== 1'b1 || cfg_fifo_clear !== 1'b1) begin
			$error("cfg_soft_reset/cfg_fifo_clear 應該同時為 1,實際 soft_reset=%b fifo_clear=%b", cfg_soft_reset, cfg_fifo_clear);
			error_count++;
		end
		axi_write(32'h00, 32'h0000_0001); // 軟體自己把 reset/clear 寫回 0,只留 enable
		tick();
		if (cfg_soft_reset !== 1'b0 || cfg_fifo_clear !== 1'b0) begin
			$error("cfg_soft_reset/cfg_fifo_clear 應該已經回到 0");
			error_count++;
		end

		// --- 明確重現「第二筆請求提前送出」的情境,證明現在不會卡死 ---
		stress_read_overlap();
		stress_write_overlap();

		// --- 大量隨機讀寫:延遲、AW/W 順序、backpressure、位址全部隨機交錯 ---
		for (i = 0; i < 200; i++) begin
			idx = $urandom_range(0, 15);
			if ($urandom_range(0, 1)) rand_write(idx);
			else rand_read_check(idx);
		end

		repeat (10) tick();

		if (error_count == 0)
			$display("=== ALL PASS ===");
		else
			$display("=== FAIL: %0d errors ===", error_count);

		$finish;
	end

endmodule
