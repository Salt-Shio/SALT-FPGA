---
name: vivado-usage
description: 本專案(CSNN-FPGA/EvtDecoder)實測過的 Vivado 2025.2 操作注意事項與已知陷阱。任何要跑 synth_design、xsim/xelab、IP 管理、或懷疑 sim/synth 行為不一致時,先讀這份。
license: MIT
---

# Vivado 使用注意事項(本專案實測)

來源:EvtDecoder 開發過程中實際踩過的坑,每一條都經過 Vivado 2025.2 (part `xck26-sfvc784-2LV-c`) 實測驗證,不是網路上抄來的通則。

## 1. 查 Vivado 指令用法,先查官方 `-help`/文件,不要側面猜

**錯誤示範(本專案真實發生過)**:想找 GUI「RTL ANALYSIS → Run Linter」按鈕背後的指令,用 `info commands *lint*` / `info commands *rule*` 這種在 Tcl 環境裡反查指令名稱的方式找,結果找錯(誤把 `lint_files` 當成 RTL linter,其實那是 Tcl 腳本檢查器,跟 RTL 無關),最後靠使用者自己在 GUI 點按鈕、看 Tcl console 回顯,才找到正確答案。

**正確作法**:
- 任何「Vivado 有沒有 XXX 功能」的問題,先跑 `<command> -help`(例如 `synth_design -help`),或查 Command Reference Guide (UG835)。
- GUI 按鈕背後一定對應某個指令的具名參數,不是獨立指令——`-lint` 就是 `synth_design` 的一個 flag,不是另外一個指令。

## 2. `synth_design` 的 lint 檢查,一定要加 `-lint`,不能只跑預設合成

```tcl
synth_design -top <top> -part xck26-sfvc784-2LV-c -lint
```

**已驗證的差異**:同一份有問題的 RTL(`logic [3:0] fetch_evt_type = S_AXIS_TDATA[63:60];`,module-scope 一次性初始化寫法),

| 跑法 | 結果 |
|---|---|
| `synth_design -top <top> -part <part> -mode out_of_context`(不含 `-lint`) | 0 warning,完全沒抓到 |
| `synth_design -top <top> -part <part> -lint` | `[ASSIGN-5] Some bits in 'fetch_evt_type' are not set` |

不加 `-lint` 的完整合成不能當作「有沒有寫法問題」的判斷依據,只能看出「能不能合成出硬體」。這兩件事是分開的。

## 3. sim 語意 vs synth 語意可能不一致,不能只看合成有沒有警告

`logic x = expr;`(module-scope 帶初始值的宣告)在 **XSim 模擬**裡是「時間 0 執行一次的初始化」,之後 `expr` 改變不會讓 `x` 跟著變——這跟 `wire x = expr;`(連續追蹤)完全不同語意,是很多人會搞混的陷阱。

**實測結果**:
- 這個寫法在 XSim 模擬下,`x` 真的不會跟著更新(驗證過,曾經害整個 testbench 顯示 `checked_count=0`)。
- 但拿去 `synth_design`(不加 `-lint`)合成、看 post-synthesis netlist,Vivado 的合成引擎**沒有照字面的「只執行一次」語意實作**,而是把它當連續組合邏輯處理,合成出來的硬體是「正確」的。
- 換句話說:純合成不報錯,不代表模擬結果可信;純模擬過,也不代表這段寫法在語意上是乾淨的。

**規則**:組合邏輯一律寫成兩行 `logic x; assign x = expr;`,不要用帶初始值的宣告當作連續賦值在用。這個規則不是風格潔癖,是因為 sim/synth 兩邊的解讀已經證實會不一樣。

## 4. XSim 模擬含 Xilinx IP 的設計,需要額外準備

跑 `xvlog`/`xelab`/`xsim` 模擬一個有例化 Xilinx IP(例如 `axis_data_fifo`)的頂層時,單純編譯自己的 RTL 不夠,還需要:

1. `glbl.v`(路徑:`<Vivado安裝目錄>/data/verilog/src/glbl.v`)
2. `xelab` 加 `-L xpm`(新版 Xilinx IP 內部會用到 XPM 巨集)
3. IP 自己產生的 reference-file-set 原始碼:`<proj>.gen/sources_1/ip/<ip_name>/hdl/*_vl_rfs.v`,要跟頂層一起編譯,不能只編 `<proj>.gen/.../sim/<ip_name>.v` 那個 sim wrapper。

少任何一項,`xelab` 會在找不到 XPM 相關符號或 IP 內部模組時失敗。

## 5. 用 Tcl 批次管理 IP 的固定流程

```tcl
create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 -module_name axis_data_fifo_0
set_property -dict [list CONFIG.TDATA_NUM_BYTES {8} CONFIG.FIFO_DEPTH {16} ...] [get_ips axis_data_fifo_0]
generate_target {instantiation_template} [get_ips axis_data_fifo_0]
generate_target all [get_ips axis_data_fifo_0]
update_compile_order -fileset sources_1
```

CONFIG 參數名稱、port 名稱不要用猜的或抄舊版文件,直接去 `<Vivado安裝目錄>/data/ip/xilinx/<ip_name>_v<ver>/component.xml` 核對——本專案曾經因為版本差異,港口/參數名稱跟網路上找到的範例不完全一樣。

## 6. Vivado 內建驗證能力的邊界(避免誤判「該不該裝額外工具」)

| 能力 | Vivado 內建有沒有 |
|---|---|
| RTL 靜態 lint(命名/未驅動 bit/位寬等規則檢查) | 有,`synth_design -lint`,規則如 `ASSIGN-1`/`ASSIGN-5`/`ASSIGN-6`/`ASSIGN-10` |
| DRC / Timing Methodology Check | 有 |
| 一般用途的 formal/SAT-based property proving(自己寫 assert,證明所有情況都成立) | 沒有,這塊要靠外部工具(如 SymbiYosys + 後端 solver) |

`-lint` 能抓到「寫法本身有問題」這類靜態缺陷,但不能取代「協定/時序上的行為在所有可能情況下是否成立」這種需要窮舉驗證的問題——後者才是 formal tool 真正補的洞。

## 7. Testbench 撰寫上跟 Vivado XSim 有關的坑

- 對下游長時間持有 `tready=0` 同時又要送一長串資料時,不要用單一 loop 從頭做到尾(送到 FIFO 滿會死鎖),改用 `fork...join`:一支負責送、一支平行觀察反壓再放行 `tready`。

### 7.1 驅動/取樣時機:`negedge` 驅動輸入、`posedge` 之後取樣輸出,`tick()=@(posedge clk);#1;` 這條舊規則不夠

**背景(`EventFIFO` scoreboard 真實踩過的坑)**:一開始用「不要裸的 `@(posedge clk)` 之後立刻驅動/取樣,統一用 `tick()`(`@(posedge clk); #1;`)當唯一入口」這條規則,以為這樣就安全。但寫 scoreboard 判斷 push/pop 有沒有發生時,用 `always @(posedge clk) begin #1; if(wr_valid&&wr_ready) ... end` 這個獨立 process,跟另一個負責驅動 `wr_valid` 的 `initial` 流程,兩者都在同一個 `#1` 之後的時間點要動作——**誰先執行,SystemVerilog 標準沒有規定順序,是模擬器自己決定(implementation-defined)**。實測發現這次 xsim 剛好都讓驅動 `initial` 流程先跑完、scoreboard 才讀,所以讀到的常常是「已經被改成下一次 edge 準備用的新值」,不是「這次 edge 真正發生的事」。

用探針量過:9 個 Stage 的完整測試裡,這種「edge 之前的真實判斷」跟「`#1` 之後重新算一次」兩者不一致發生了 571 次,但最後兩套獨立統計出來的結果剛好一致——**這是巧合,不是這個寫法真的安全**。它依賴兩個沒有任何規範保證的前提:驅動 task 只用「設定→等待→撤回」這種單純節奏、模擬器剛好排出「驅動先跑完」的順序。換一種更複雜的並行驅動、換一顆模擬引擎,任何一個前提垮掉,scoreboard 就會真的記錯資料,而且不會有任何警訊告訴你。

**正確做法**:

```systemverilog
task automatic tick();
    @(negedge clk); // 輸入訊號在這裡改,離下一個 posedge 還有半個週期的安全間隔
    // wr_valid、rd_ready、wr_data 這些「驅動」動作寫在這裡
    @(posedge clk); // DUT 在這裡取樣輸入、跑 always_ff
    #1;              // 等這次 edge 的 NBA、組合邏輯傳播都穩定
    // wr_ready、rd_valid、rd_data 這些「讀取判斷」動作寫在這裡
endtask
```

原則:輸入訊號一旦在 `negedge` 設好,到下一個 `posedge` 之前有整整半個時鐘週期不會再被改——不管 DUT 自己的 `always_ff`,還是任何獨立的 scoreboard process,在這段安全期間內任何時間點讀,結果都一樣,不會因為「哪個 process 先執行」而讀到不同的值。這比舊版「統一用 `tick()` 當唯一入口」更徹底:舊規則只處理了「訊號本身穩不穩定」,沒處理「多個獨立 process 同時要在同一個時間點動作,誰先誰後沒有保證」這個更根本的問題。

**檢查「握手是否成立」的原則不變,但現在有更可靠的做法**:要在**跨越那個 clock edge 之前**取樣 ready 訊號,不要事後才看——事後看到 ready 掉下來,無法分辨是「因為剛被吃掉了」還是「其他原因本來就要掉」。`negedge` 驅動、`posedge` 後取樣這個結構,天然滿足這個原則,不用再額外費心思考「這次讀的時機對不對」。

### 7.2 self-checking 要印具體數值,不要只印「一致/不一致」這種摘要

診斷 7.1 那個坑時,一開始只印 `mismatch_count`(一個抽象的不一致次數),自己也看不出問題出在哪,直到把 `wr_data` 這種具體數值印出來對照程式碼行號,才真正對齊到根因。以後 scoreboard 報錯,一律印 `$time`(或 cycle 數)、預期值、實際值,不要只印布林判斷結果或籠統的計數。

### 7.3 寫 testbench 之前,先用 cycle-by-cycle 表格列出預期行為

不要邊寫程式碼邊設計時序。先把「哪個 cycle 輸入什麼、哪個 cycle 輸出該是什麼」列成表格,過一遍邏輯、讓人確認後再動手寫——這樣問題會在寫程式碼之前就被抓到,不是寫完跑出來才發現時序想錯了。

### 7.4 預設用單一 process 驅動,只有「事件流彼此獨立但要同時發生」才上多 process

7.1 那個坑的更根本解法,不是「改用 `negedge`」這個表層規則,是**整份 testbench 只用一個 `initial` 流程,把驅動跟判斷做進同一個 task、同一個線性執行序列裡**——`EventFIFO` 的 `step` task 就是這樣寫的(`negedge` 讀 `pre_*` 值 → 驅動輸入 → `posedge`+`#1` → 用 `pre_*` 值判斷 `did_push`/`did_pop`),整份 testbench 沒有第二個獨立的 `always @(posedge/negedge clk)` 進程存在,所以根本不存在「兩個 process 同時要在同一個時間點動作,誰先誰後沒有保證」這個結構性風險。valid/ready 這種驅動-響應式介面,操作本質上是一步接一步、有明確先後依賴,單一 process 應該是預設選項。

**必須用多 process(`fork...join`、獨立 `always` 監控)的情況,只有「多個事件流彼此獨立、不互相等待,但要同時發生」**,具體三類:

1. DUT 有多個獨立、不同步的介面要同時驗證交互——例如 `EvtDecoder` 的 AXI4-Stream(收資料)跟 AXI4-Lite(PS 控制),兩條協定節奏互不相干,單一 process 輪流做測不出兩者真正同時發生的情境。
2. 長時間持續送一長串資料,同時中途要觀察某個條件並介入——`tb_fsm_event_extractor.sv` 的做法:對下游長時間 `tready=0` 又要送一長串資料,單一 loop 會死鎖(送到 FIFO 滿卡住、沒人放開 `tready`),要用 `fork...join`:一支負責送、一支平行觀察反壓再放行。
3. 需要貫穿全程的被動監控(某個不變量要全程成立),跟主動驅動邏輯分開,用獨立的背景 process 專職檢查。

**上了多 process 之後,不能假設換了寫法就自動安全**:多個 process 只要會讀寫同一批訊號,一樣要重新推導「這個判斷依據必須鎖定在哪個精確時間點」,不能靠「反正大家都在差不多時候動作」這種模糊假設——參考 7.1 的推導方式,针對新的多 process 結構重做一次。
