`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_fsm_event_extractor.sv
// FsmEventExtractor 整合測試:透過 AXI-Lite 開啟模組,從 s_axis 灌一整段真實
// EVT2.1 封包序列(TIME_HIGH + 多筆 TD),下游卡住時確認 FIFO 滿了以後
// s_axis_tready 會正確被壓低(反壓有傳到最外層,不會悄悄掉包),
// 下游恢復後再確認 scoreboard 全部一筆不差地收到。
//////////////////////////////////////////////////////////////////////////////////

module tb_fsm_event_extractor;

	localparam integer TDATA_W = 64;
	localparam integer AXIL_DATA_W = 32;
	localparam integer AXIL_ADDR_W = 32;

	logic clk = 0;
	logic rstn = 0;

	// AXI4-Stream
	logic s_valid = 0;
	logic s_ready;
	logic [TDATA_W-1:0] s_data = '0;
	logic s_last = 0;

	logic m_valid;
	logic [TDATA_W-1:0] m_data;
	logic [(TDATA_W/8)-1:0] m_strb;
	logic m_last;
	logic m_ready = 0;

	// AXI4-Lite
	logic [AXIL_ADDR_W-1:0] awaddr;
	logic awvalid = 0;
	logic awready;
	logic [AXIL_DATA_W-1:0] wdata;
	logic [(AXIL_DATA_W/8)-1:0] wstrb;
	logic wvalid = 0;
	logic wready;
	logic [1:0] bresp;
	logic bvalid;
	logic bready = 0;
	logic [AXIL_ADDR_W-1:0] araddr;
	logic arvalid = 0;
	logic arready;
	logic [AXIL_DATA_W-1:0] rdata;
	logic [1:0] rresp;
	logic rvalid;
	logic rready = 0;

	FsmEventExtractor #(
		.C_S_AXIS_TDATA_WIDTH(TDATA_W),
		.C_M_AXIS_TDATA_WIDTH(TDATA_W),
		.C_S_AXI_DATA_WIDTH(AXIL_DATA_W),
		.C_S_AXI_ADDR_WIDTH(AXIL_ADDR_W)
	) dut (
		.AXIS_ACLK(clk),
		.AXIS_ARESETN(rstn),

		.S_AXIS_TREADY(s_ready),
		.S_AXIS_TDATA(s_data),
		.S_AXIS_TSTRB('1),
		.S_AXIS_TLAST(s_last),
		.S_AXIS_TVALID(s_valid),

		.M_AXIS_TVALID(m_valid),
		.M_AXIS_TDATA(m_data),
		.M_AXIS_TSTRB(m_strb),
		.M_AXIS_TLAST(m_last),
		.M_AXIS_TREADY(m_ready),

		.S_AXI_AWADDR(awaddr),
		.S_AXI_AWPROT('0),
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
		.S_AXI_ARPROT('0),
		.S_AXI_ARVALID(arvalid),
		.S_AXI_ARREADY(arready),
		.S_AXI_RDATA(rdata),
		.S_AXI_RRESP(rresp),
		.S_AXI_RVALID(rvalid),
		.S_AXI_RREADY(rready)
	);

	always #5 clk = ~clk;

	task automatic tick();
		@(posedge clk);
		#1;
	endtask

	int error_count = 0;

	/* ---------------- AXI4-Lite BFM ---------------- */
	task automatic axi_write(input logic [AXIL_ADDR_W-1:0] addr, input logic [AXIL_DATA_W-1:0] data);
		bit aw_done, w_done, b_done;
		awaddr = addr; awvalid = 1'b1;
		wdata  = data; wstrb = '1; wvalid = 1'b1;
		aw_done = 1'b0; w_done = 1'b0;
		while (!aw_done || !w_done) begin
			if (awvalid && awready) aw_done = 1'b1;
			if (wvalid && wready)   w_done  = 1'b1;
			tick();
			if (aw_done) awvalid = 1'b0;
			if (w_done)  wvalid  = 1'b0;
		end
		bready = 1'b1;
		b_done = 1'b0;
		while (!b_done) begin
			if (bvalid && bready) b_done = 1'b1;
			tick();
		end
		bready = 1'b0;
	endtask

	/* ---------------- AXI4-Stream 輸入端 ---------------- */
	task automatic send_word(input logic [TDATA_W-1:0] data);
		bit accepted;
		s_data  = data;
		s_valid = 1'b1;
		accepted = 1'b0;
		while (!accepted) begin
			accepted = s_ready;
			tick();
		end
		s_valid = 1'b0;
	endtask

	/* ---------------- scoreboard(跟 tb_event_processor 同一種做法,獨立重算)---------------- */
	typedef struct packed {
		logic [10:0] x;
		logic [10:0] y;
		logic        typ;
		logic [27:0] time_high;
		logic [5:0]  time_lo;
	} exp_evt_t;

	exp_evt_t exp_q[$];
	int checked_count = 0;
	logic [27:0] ref_time_high = '0;
	logic        ref_time_valid = 1'b0;

	task automatic push_td(input logic [3:0] typ, input logic [5:0] tlo,
	                        input logic [10:0] x, input logic [10:0] y,
	                        input logic [31:0] mask);
		exp_evt_t e;
		if (!ref_time_valid) return;
		for (int i = 0; i < 32; i++) begin
			if (mask[i]) begin
				e.x = x + i[10:0];
				e.y = y;
				e.typ = typ[0];
				e.time_high = ref_time_high;
				e.time_lo = tlo;
				exp_q.push_back(e);
			end
		end
	endtask

	task automatic send_time_high(input logic [27:0] th);
		send_word({4'h8, th, 32'd0});
		ref_time_high  = th;
		ref_time_valid = 1'b1;
	endtask

	task automatic send_td(input logic [3:0] typ, input logic [5:0] tlo,
	                        input logic [10:0] x, input logic [10:0] y,
	                        input logic [31:0] mask);
		push_td(typ, tlo, x, y, mask);
		send_word({typ, tlo, x, y, mask});
	endtask

	always @(posedge clk) begin
		#1;
		if (rstn && m_valid && m_ready) begin
			exp_evt_t e;
			logic [TDATA_W-1:0] exp_data;
			checked_count++;
			if (exp_q.size() == 0) begin
				$error("[%0t] 收到未預期的事件: data=%h", $time, m_data);
				error_count++;
			end else begin
				e = exp_q.pop_front();
				exp_data = {e.x, e.y, e.typ, e.time_high, e.time_lo};
				if (m_data !== exp_data) begin
					$error("[%0t] 事件內容不對: got=%h expect=%h", $time, m_data, exp_data);
					error_count++;
				end
			end
		end
	end

	task automatic wait_drain();
		int guard;
		guard = 0;
		while (exp_q.size() != 0 && guard < 5000) begin
			tick();
			guard++;
		end
		if (exp_q.size() != 0) begin
			$error("wait_drain 逾時,queue 還剩 %0d 筆", exp_q.size());
			error_count++;
		end
	endtask

	/* ---------------- 主測試流程 ---------------- */
	initial begin
		int i;
		bit saw_backpressure;

		rstn = 0;
		repeat (5) tick();
		rstn = 1;
		tick();

		// 開啟模組:REG_CONTROL.enable=1,REG_TLAST_TIMEOUT 隨便給個大值
		axi_write(32'h00, 32'h0000_0001);
		axi_write(32'h08, 32'h0000_FFFF);

		send_time_high(28'h7);

		// 下游卡住,burst 送 20 筆單一 bit 的 TD,觀察 s_ready 有沒有在 FIFO 滿了以後被壓低。
		// 送資料的 process 一旦 FIFO 滿了會真的卡住等 s_ready,所以要另開一個 process
		// 專門看情況、等看到反壓後再放開下游,不能等 20 筆全送完才放(會卡死,因為
		// 20 筆全送完這件事本身要靠放開下游才能達成)。
		m_ready = 1'b0;
		saw_backpressure = 1'b0;
		fork
			begin : burst_sender
				for (i = 0; i < 20; i++) begin
					send_td(4'(i % 2), 6'(i), 11'(i*2), 11'(i), 32'(1 << (i % 32)));
				end
			end
			begin : backpressure_watcher
				int guard;
				guard = 0;
				while (!saw_backpressure && guard < 200) begin
					if (!s_ready) saw_backpressure = 1'b1;
					tick();
					guard++;
				end
				repeat (5) tick(); // 多撐幾拍,確定不是剛好取樣到單一空拍
				m_ready = 1'b1;
			end
		join

		if (!saw_backpressure) begin
			$error("burst 20 筆、下游卡住的情況下,s_axis_tready 應該要出現過 0(FIFO 滿),但整段期間都是 1");
			error_count++;
		end

		// 下游已經恢復,確認全部一筆不差收到
		wait_drain();

		if (error_count == 0)
			$display("=== ALL PASS (%0d events checked) ===", checked_count);
		else
			$display("=== FAIL: %0d errors, %0d events checked ===", error_count, checked_count);

		$finish;
	end

endmodule
