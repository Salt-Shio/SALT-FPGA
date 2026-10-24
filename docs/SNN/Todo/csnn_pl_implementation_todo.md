# CSNN 層 RTL TODO

## 目標

把 `D:\Project\Spiking-Affine-Lazy-Training` 訓練出來的 CSNN(conv1 → conv2 → FC)做成事件驅動 RTL，在 PL 端直接更新膜電位，不繞 PS。

- 行為要跟訓練端的整數規格逐位元一致。
- 功耗要打贏對應的 ANN 版本。
- 跟 [`ps_host_if` 替換](../../GENX320/Todo/ps_host_if_replacement_todo.md)平行進行。

## 現況

- Conv 層 `SaltConv` 完成(Part 0~9，2026-10-05 ~ 10-22)。
    - conv1 → conv2 串接(`SaltConvNet`)的輸出、兩層最終狀態跟訓練端逐位元相同。
    - 目標時脈 5 ns(200 MHz)：4.8 ns 下繞回、飽和兩版都過(+0.213、+0.131 ns)。
    - 量測結果、合成流程見 [`SaltConvSynthFlow.md`](../Concept/Layer-RTL/SaltConvSynthFlow.md)。
    - 各 Part 的完整過程(定案討論、反向測試)在 commit `dc9b22a` 版本的這份 TODO。
- Vivado 專案 `SaltConv/`：RTL 在 `SaltConv.srcs/sources_1/new/`，testbench 在 `sim_1/new/`，模擬、合成腳本在 `SaltConv/scripts/`。
- 讀現行 RTL：`SaltConv.sv` 照事件流程分 0~6 段(檔頭有目錄)。
    - 控制總覽：[`SaltConvOverview.md`](../Concept/Layer-RTL/SaltConvOverview.md)。
    - 逐拍例子、資料流程圖：[`Conv-image/SaltConvControl.md`](../Concept/Layer-RTL/Conv-image/SaltConvControl.md)、[`SaltConvDataflow.md`](../Concept/Layer-RTL/Conv-image/SaltConvDataflow.md)。
    - 設計推導：[`Conv.md`](../Concept/Layer-RTL/Conv.md) 5.5「實作」、5.8。
- 分支：Part 8.2、8.x 都已經 fast-forward 併進 `test`，`test` 已推到遠端。$o_c$ 重疊 B 做法的實作留在 tag `overlap-b-redo`(`e8c7163`)。
- FC 層設計 [`FC.md`](../Concept/Layer-RTL/FC.md) 第 1~6 節寫完，第 6 節 ⑤ 留到寫 RTL 時定；RTL 還沒開始。

## SaltFC

照 SaltConv 的作法：

- 每個 Part 都要過目確認才進下一個。
- 規劃一個 Part 時先列出這次做什麼、怎麼量、怎麼驗證，給使用者確認；一次只處理一個策略或一個機制。
- 做法要比較時，不問目標時脈、$R$、$C$ 設多少：量出每種做法的速度(時脈、拍數)跟成本(LUT、FF、BRAM、DSP、多幾拍、設計驗證多複雜)，整理成表給使用者選。
- 驗證照下面「作法」。

| Part | 內容 | FC.md | 狀態 |
|---|---|---|---|
| 0 | 專案結構 | — | 討論中 |
| 1 | 訓練端匯出 FC 的權重、門檻、衰減表 | 第 2 節、第 3 節 ① | 未開始 |
| 2 | 介面規格(parameter、port) | 第 1、6 節 | 未開始 |
| 3 | 輸入 FIFO | 第 1 節 | 未開始 |
| 4 | 權重 BRAM | 第 2 節「權重」 | 未開始 |
| 5 | 神經元 BRAM、門檻 BRAM、清除 | 第 2 節「神經元」「門檻」 | 未開始 |
| 6 | 膜電位更新 | 第 3 節 | 未開始 |
| 7 | spike 選擇與輸出(優先權編碼器、bitmask) | 第 4 節 | 未開始 |
| 8 | pipeline 整合 | 第 5 節 | 未開始 |
| 9 | 膜電位輸出 | 第 6 節 | 未開始 |
| 10 | conv → FC 轉接模組 | 第 1 節 | 未開始 |
| 11 | 串接 conv1 → conv2 → FC，跟訓練端比對 | — | 未開始 |
| 12 | 合成量測(4.8 ns) | — | 未開始 |

- 每個 Part 的細節到要做時才規劃；Part 8 要不要像 SaltConv 一樣從無腦版一步一步做，到時候再定。

### Part 0 專案結構

- 要討論的：Vivado 專案 `SaltConv` 要不要改名，底下分 SaltConv、SaltFC 兩部分。
    - 起因：`EventFIFO` 這類通用模組現在放在 `SaltConv` 裡，SaltFC 也要用。
- 一起要定的：
    - 哪些模組兩層共用、放在哪。
    - RTL、testbench、答案檔、`.mem`、腳本(`sim_common.tcl` 這類共用流程)的資料夾怎麼分。
    - 改名會動到的地方：`SaltConv.xpr` 的檔案清單、模擬集、`scripts/` 裡的路徑、`SaltConvSynthFlow.md`、`CLAUDE.md`、`README.md`。

### Part 1 訓練端匯出

- 已定(2026-10-22)：FC 權重寬字的內容跟硬體參數 $n_{col}$(每列幾顆神經元)有關，匯出時傳入 $n_{col}$ 打包；換 $n_{col}$ 要重新匯出。
- 跟 conv 同一套分工(見「已定案設計 → 權重匯出格式」)：打包函式加在訓練端 `salt_core/fpga_export.py`，`tools/export_fpga.py` 只負責讀 `model.npz`；格式規格只寫在 FC.md，docstring 指過去。
- 現在 `fpga_export.py` 只匯出 conv 層。

### Part 11 串接比對

- 用 `reference.npz` 的 `v_final_int` 比整條推論，見「待決事項 → 驗證」。
- 訓練端的 `v_final` 多做了一步 catch-up(每顆神經元再衰減到樣本最後一筆事件的時間，權重 0)，硬體不做；SaltConv 的答案腳本比的是 catch-up 之前的 $\hat V$，FC 也要先處理這個差異。

## 延後、擱著的項目

| 編號 | 項目 | 什麼時候處理 |
|---|---|---|
| D1 | 時序 C：`SpikeSelect` 改成看「窗裡排在我前面的有沒有 pending」，不轉讀的順序 | 整合後 5 ns 過不了才做 |
| D2 | 時序 D：讀位址路徑(FIFO 最前面那筆 → 選這次要讀哪一筆 → `CandidateGrid` → BRAM 讀位址)；4.8 ns 量測裡 M=3 繞回、兩層串接飽和版的最長路徑就是這條 | 整合後 5 ns 過不了才做 |
| D3 | `NeuronUpdate.sv:73` 的 reviewer 註解(用 `DECAY_TABLE_DEPTH` 決定 $\Delta t$ 的位寬) | 先留著 |
| D4 | 讀取開關每拍都開，還是推進那一拍才開 | 之後討論 |
| D5 | testbench 重整：`tb_salt_conv_common.svh` 的 `run_sample` 一個 task 混了驅動、交握檢查、涵蓋統計、拍數、比對 | 碰到要改 testbench 時一起處理 |
| D6 | 上層攤平時 BRAM 輸出暫存器為什麼併不進去 | 換 Vivado 版本時再確認一次 |
| D7 | 權重記憶體改 XPM | 目前不做 |
| D8 | 衰減表 ROM 的 LUT 用量($M\times M$ 份組合邏輯查表) | 吃太多再回頭檢討 |
| D9 | `CandidateAxis` 的除法、`CandidateGrid` 的乘常數用 LUT 還是 DSP | 合成後看 utilization，必要時加 `USE_DSP="no"` |
| D10 | FC 權重放 URAM | 延後，這一版用 BRAM |

- D4：
    - 每拍都開：讀取開關不用等推進的判斷，量起來稍快(時脈多 0.5~4 MHz，接近布局繞線的變動範圍)；卡住的拍子($k\ge2$、`out_ready=0`)、$R=2$ 等資料的拍子會白讀記憶體，多耗電。
    - 推進才開：不會白讀；讀取開關接在推進的判斷後面，慢一點點。
    - 還沒評估：白讀的次數、多耗多少電。
- D5：方向是共用可以(避免同一段檢查改四次)，但核心流程(餵資料、比輸出、比神經元狀態)要在一個地方看得完；涵蓋統計拆開，跟核心分開。
- D6：現在靠 `keep_hierarchy = "soft"` 加上每次合成檢查 `DOB_REG` 確認；Vivado 內部原因 log 跟官方文件都沒寫，查不到(vivado-usage skill 第 10 節)。
- D7：要先解決 `MEMORY_INIT_FILE` 只能給檔名、不能帶路徑的問題(權重檔改成不重複的檔名、加進專案，訓練端匯出的命名可能也要改)；XPM 也要求記憶體至少 2 個字。
- D10：URAM 不能帶初始值，權重要在執行時寫入。

## 待決事項

### 量化與數值

- `FIFO_DEPTH`：反壓、不丟事件的策略已定，深度要看目標時脈跟實際輸入事件率，事件率還沒有。
- FPGA 上實際省多少功耗：運算量少 20 倍不等於功耗少 20 倍，漏電流、clock tree 是固定成本，要 Vivado 功耗分析或實測才有數字。

### 系統整合

- `EvtDecoder → conv1` 轉接模組：要先查 `EvtDecoder` 的 `M_AXIS_TDATA` 實際打包的欄位(EVT2.1)，才能寫 unpack。
- µs 換 ms：用 floor，$t=\lfloor t_{\mu s}/1000\rfloor$，跟訓練端相同。放在轉接模組裡還是另開一個模組還沒定。
- 時間戳記繞回：連續事件流的時間戳記到 $2^{\texttt{TIME\_WIDTH}}$ ms 會繞回，之後 $\Delta t=t-t_{last}$ 會算錯。
    - 怎麼處理還沒討論；跟神經元記憶體清除是兩件事。
    - `NeuronUpdate` 現在用 `TIME_WIDTH` 位元無號減法算 $\Delta t$，不替繞回做決定。
- 輸出層乘 $s_i$：$\text{score}_i=\hat V[i]\cdot s_i$ 是整個推論唯一的浮點運算。
    - 2026-10-22 定：不放在 FC 層裡。FC 只提供膜電位輸出(FC.md 第 6 節)，乘 $s_i$、argmax 由層外另外寫的模組處理，那個模組還沒設計；放 FPGA 內還是外部還沒定。
- 跟 `ps_host_if` 替換模組要不要融合：等兩邊資源用量(BRAM、LUT、功耗)出來再決定。

### 驗證

- 用 `reference.npz` 逐位元比對：每個量化資料夾都有 val 前 2000 筆的逐筆結果。
    - 欄位：`preds`、`v_final_int`(輸出層暫存器最終值)、`spike_count`(每層 spike 總數)、`overflowed`(每層有沒有碰到暫存器範圍)。
    - `v_final_int` 逐位元相同，就代表整條推論對上。
    - 這台機器只有 N-MNIST 的 `Test`，val 要從 `Train` 切；SaltConv 因此改用 test 前 10 筆(量化資料夾 `eval/test.yaml` 記的評估取樣)，spike 數跟 `eval/test_outputs.npz` 比。

## 作法

### 驗證

- 答案檔：Python 腳本用訓練端的函式產生，放 `sim_1/new/ref/`。
    - 環境是 WSL 的 conda 環境 `jax`(`~/miniconda3/envs/jax/bin/python`)。
    - 整層的答案用兩份互相比對，一致才寫答案檔：訓練端官方的整層 forward，跟照硬體做法逐筆算的迴圈(例：`scripts/gen_salt_conv_ref.py`)。
    - 參數組：訓練端的實際參數 × 繞回、飽和兩版，加上人工參數(不是 2 的次方、位寬下限、邊界情況)；人工參數的權重用訓練端同一個打包函式產生 `.mem`。
- testbench：讀答案檔逐筆比對，不一致印出輸入、欄位、預期值、實際值，最後印一行總結(`ALL PASS` / `FAIL`)。
    - 參數用 generic 帶入，答案檔目錄用 `-testplusarg REF_DIR=` 帶入。
    - 一支 testbench 只測一種情況(例如一種反壓方式)，不同情況拆成不同檔案；共用的部分放 `.svh`，但核心流程要在一個地方看得完。
    - 機制維持一個 `initial` 流程(negedge 給值、posedge 前檢查)，不用多個並行 process、SVA。
    - 涵蓋統計跟核心流程分開，要加之前先問。
    - 反向測試：改壞 RTL 或答案檔，確認會 FAIL；跑完還原，確認跟 commit 相同。
- 跑模擬：一個 testbench 一個模擬集，`scripts/run_tb_*.tcl` 跑所有參數組，共用流程在 `scripts/sim_common.tcl`。
    - 多組參數一律用 batch 模式跑；從 GUI 的 Tcl Console 跑，連續 elaborate 會不定時出現 `Spawn failed`。
    - 一個 Vivado session 只跑一個模擬集：第二個會沿用第一個的檔案清單(vivado-usage skill 8.8)。多支 testbench 由 `run_testbenches_in_children` 每支開一個子 Vivado。
    - 同一個專案一次只跑一支：多個 Vivado 同時開 `.xpr` 跑模擬會互相改寫專案檔。non-project 的合成不碰 `.xpr`，可以跟模擬同時跑。
    - 跑完 `.xpr` 會留下作用中的模擬集、generic 這些改動，commit 時不放，`git checkout` 還原。
    - `run_tb_salt_conv.tcl` 只跑部分參數組時，`-tclargs` 加 `NAME:value` 條件(例：`OUT_CHANNELS:1`)。
    - GUI 只用來跑 testbench 預設參數的單組模擬、看波形；GUI 開著時在專案副本上跑，不要動正式專案的 `.xpr`。
- Vivado 的已知陷阱記在本機的 `.claude/skills/vivado-usage/SKILL.md`(不進 repo)。從 agent 的 shell 跑 Vivado 要先 `env -u NoDefaultCurrentDirectoryInExePath`(8.6)。

### 合成量測

- 流程、參數、量測結果都在 [`SaltConvSynthFlow.md`](../Concept/Layer-RTL/SaltConvSynthFlow.md)：兩層串接用 `SaltConv/scripts/synth_salt_conv_net.tcl`，比較做法時的單層量測見「比較做法時的量測(單層)」。
- 目標固定 5 ns，跑 4.8 ns 看過不過，不掃最高時脈。

## 已定案設計

### 量化方案

- 模組是通用的：捨入(`ROUND`)、溢位處理(`SATURATE`)兩種都支援，由例化端用參數選，不選定一版。
- 訓練端目前給了兩版，$f_V=0$，所以 $w=i_V$：
    - 繞回版：conv1 12 bits、conv2 14 bits，test 0.9222。驗證跟 test 都沒碰到範圍，繞回不會真的發生。
    - 飽和版：conv1 9 bits、conv2 11 bits，test 0.9229。幾乎每筆樣本都會碰到範圍，硬體要逐位元夾住。
    - 其他都相同：$b=7$、$f_a=6$、$f_V=0$、捨入用 `round`，衰減表、門檻、權重碼也相同。

### 運算方式

- 事件驅動：每筆事件到達就用經過的整數 ms 數 $\Delta t$ 做解析衰減、判斷 fire，不等下一筆事件。
- 跟 spikingjelly 逐步更新不是同一個函數，已放棄精確等效。硬體的整數規格見 [`model_operation_quant.md`](../Concept/model_operation_quant.md) 第 3 節。
- conv 的推導見 [`Conv.md`](../Concept/Layer-RTL/Conv.md)，FC 的見 [`FC.md`](../Concept/Layer-RTL/FC.md)。

### 介面

- 規格本體就是頂層 `.sv`，文件不重複貼。parameter 預設值都是佔位，每個 layer 例化時傳入完整參數。
- 事件介面用分欄位 port(例如 `in_x`、`in_y`、`in_channel`、`in_time`)，不打包成 `TDATA`。
    - `EvtDecoder` 打包是被 PS 端 AXI DMA 規格限制，層模組沒有這個限制。
- 命名：
    - parameter、port 用描述性完整名稱，不用 `K`、`S`、`OC` 這類單字母，行尾註解標數學符號。
    - `_WIDTH` 專指位元寬，影像尺寸用 `OUT_ROWS`、`OUT_COLS`。
    - 事件介面前綴用 `in_`、`out_`。
- 量化參數：`WEIGHT_WIDTH`($b$)、`MEMBRANE_INT_WIDTH`($i_V$)、`MEMBRANE_FRAC_WIDTH`($f_V$)、`DECAY_FRAC_WIDTH`($f_a$)、`DECAY_TABLE_DEPTH`($\Delta t_{\max}$)。
    - `MEMBRANE_WIDTH`($w$)是 `localparam`，由整數位加小數位推出。
    - 捨入、溢位行為做成 `ROUND`、`SATURATE` 兩個 `bit` 參數，兩種都要能合成。
    - $\tau$ 不進硬體，只透過衰減表 $A[\Delta t]$ 出現。
- 訓練出來的資料不佔 port，用 `$readmemh` 從檔案載入，檔名參數是 `WEIGHT_FILE`、`THRESHOLD_FILE`、`DECAY_FILE`。
    - 檔名參數不寫型別：UG901 不支援 `string` 型別參數，也不支援空字串參數。

### 資源類型

- 乘法一律用 DSP(`use_dsp = "yes"`，不做成參數)；布局時乘法 DSP 設 `DONT_TOUCH`，不讓 PSIP 把切點暫存器搬出去。
- 記憶體都寫明資源類型，不交給 Vivado 依大小判斷：權重、神經元用 BRAM，`EventFIFO`、衰減表用 LUT。
- BRAM 用推斷寫法，陣列跟讀出暫存器的模組加 `keep_hierarchy = "soft"`，$R=2$ 的第二級才併得進 BRAM 輸出暫存器；不用 XPM(見 D7)。
- 理由與量測見 `SaltConvSynthFlow.md`。

### 門檻與衰減表(conv)

- 門檻 $\hat v_{th}[o_c]$：逐 output channel 一份(per-channel 權重量化下每個 channel 不同)。載入後是編譯期常數，合成成 mux，不另外配置記憶體。
    - FC 每顆神經元一個門檻，用 BRAM(FC.md 第 2 節「門檻」)。
- 衰減表 $A[\Delta t]$：兩版共用同一張，深度 $\Delta t_{\max}=75$，每格 $f_a=6$ bits 無號，值 $60,56,53,\dots,1$。
    - conv 同一拍 $M\times M$ 個候選各自查，`NeuronUpdate` 每份各帶一張 LUT ROM。
    - FC 整層共用一個 $\Delta t$，只要 1 份(FC.md 第 3 節 ①)。

### 輸入 FIFO(`EventFIFO`)

- 只有輸入端有 FIFO；輸出端靠 bitmask 排序送出，下游 `ready=0` 時直接反壓，卡住整條內部 pipeline。
- 獨立成參數化寬度的可重用子模組，自己寫，不用 Xilinx IP。
    - 深度小(現行 16)，用不到 BRAM 管理能力。
    - 介面是分欄位，套 AXI4-Stream IP 反而要多包一層 pack/unpack。
- 現在是 distributed RAM 版(`ram_style = "distributed"`，資料陣列的寫入放在沒有 reset 的 `always_ff`)，輸出遵守 valid/ready 交握，外部不假設任何固定延遲。
    - 之後深度開大換 BRAM(讀取多 1 clock)，只要改 `EventFIFO` 內部把 `valid` 延後對齊，外部不用動。
- 讀出端必須維持 FWFT：`rd_data` 直接是最前面那一筆，`rd_valid && rd_ready` 那一拍才移走。
    - 靠它成立的兩件事：同一拍看下游 ready、同一拍決定拿不拿事件，讀出端不用另加 skid buffer；換事件那一拍直接用 FIFO 最前面那筆送讀位址，不多花拍數。
    - 換 BRAM 時，`EventFIFO` 內部要多一格輸出暫存器，先把下一筆讀出來放著，對外維持 FWFT。
- 寫入端 `wr_ready = !full`，`full` 是暫存器，不看讀出端：上一層看到的 ready 不會跟這一層的控制串在一起，層與層之間不用另加 skid buffer。

### 候選計算(conv：`CandidateAxis`、`CandidateGrid`)

- 拆成單軸子模組，參數 $K,S,P,O_{max}$，y、x 各例化一次；兩軸配對、bank 內位址攤平在 `CandidateGrid`。
    - 候選條件兩軸獨立，只有位址攤平要兩軸合併；單軸可以窮舉驗證；非正方形 kernel 只要兩個實例傳不同參數。
- 單軸輸出 $M$ 組，第 $r$ 組就是 bank $r$($o\bmod M=r$)的候選，每個欄位各自一個 unpacked array：`valid`、`out_coord`、`bank_offset`、`tap`。
    - 另外一個值 `min_bank`：窗最小座標 $o_{max}-(M-1)$ 的 bank，$(m_{max}+1)\bmod M$，給 `SpikeSelect` 用；不是 Conv.md 第 2 節 $o_{min}$ 的 bank。
    - 不用 struct：要多一個共用巨集 `.svh`，上層兩軸位寬不同還要各開 generate block。
- `CandidateGrid` 輸入 $(y,x)$ 跟這一拍的 $o_c$，輸出 $M\times M$ 組 `valid`、`bank_addr`、$(o_y,o_x)$、$(k_y,k_x)$，跟窗左上角的 bank `top_row_bank`、`left_col_bank`。
- bank 內位址用乘常數攤平：$(o_c\cdot G_y+g_y)\cdot G_x+g_x$，不把每一維補到 2 的次方(補了在 $OC=16$、$G_y=G_x=22$ 時 BRAM 用量約兩倍)。
- 每個 bank 容量一律 $OC\times G_y\times G_x$，邊界不整除時有些 bank 空幾格。

### 神經元記憶體清除

- 換樣本時所有層的膜電位、$t_{last}$ 都要回到 0。
- 不開 port：`rst_n` 釋放後逐位址寫 0，清除期間 `in_ready=0`。
- 只用在剛開機跟實驗重來。實際應用是連續事件流，沒有樣本邊界。
- `rst_n` 會丟掉 FIFO、pipeline 裡還沒處理完的事件：實驗時要等上一個樣本處理完才 reset，怎麼知道處理完是驅動實驗那一端的事。

### 層間事件格式

- conv 跟 FC 分開，不統一：
    - conv 層的輸入、輸出都是分欄位座標 $(x,y,c,t)$。
    - FC 層的輸入是攤平編號 $(\text{src},t)$，直接拿 $\text{src}$ 當權重矩陣的欄索引。
- 格式轉換由誰負責：
    - `EvtDecoder → conv1`：`EvtDecoder` 輸出打包的 `TDATA`，中間一個小型轉接模組做 unpack，由 top 例化，不算 `SaltConv` 或 `EvtDecoder` 內部。`EventProcessor.sv`(GENX320 範圍)不改。
    - `conv → conv`：欄位直接對應($o_c\to c$、$o_y\to y$、$o_x\to x$、$t\to t$)，直接接線。位寬一致是上下層參數配置的責任。
    - `conv → FC`：換成 $\text{src}=o_c\cdot H_{out}W_{out}+o_y\cdot W_{out}+o_x$，中間一個轉接模組，放在 FC 輸入 FIFO 寫入端之前，先存一級暫存器再換算，由 top 例化，`SaltConv`、FC 層都不改(2026-10-22 定，FC.md 第 1 節)。
    - `FC → FC`：輸出 $(i,t)$ 直接接下一層的 $(\text{src},t)$。

### 權重匯出格式

- 每層三個 `$readmemh` 用的 hex 檔：權重寬字、門檻、衰減表 $A[\Delta t]$。
    - Vivado 合成只收 `$readmemh`、`$readmemb` 兩種(UG901 Table 24)，選 hex。
    - 格式規格只寫在 Conv.md(第 2 節「權重」「門檻」、第 3 節 ①「檔案格式」)、FC.md(第 2 節「權重」「門檻」、第 3 節 ①)，這裡不重複。
    - 二補數，一行一個位址，固定 $\lceil\text{位元數}/4\rceil$ 個 hex 字元，最左邊補 0。
- 匯出程式由訓練端寫，docstring 指到 Conv.md、FC.md，不在訓練端文件另寫一份規格。
    - 打包函式放 `salt_core/fpga_export.py`(輸入陣列、輸出 `.mem`)，`tools/export_fpga.py` 只負責讀 `model.npz`。
    - SALT-FPGA 測非 2 的次方參數時，答案檔腳本 import 同一個打包函式產生隨機權重的 `.mem`。
    - 輸入一個量化資料夾，`--out-dir` 指定輸出；每層 `<層>_weight.mem`、`<層>_threshold.mem`、`<層>_decay.mem`。
    - 匯出時檢查：$q$ 超出 $b$ 位元、門檻超出 $w$ 位元(conv 另外檢查同一個 $o_c$ 的門檻不全相同)、衰減表超出 $f_a$ 位元，都 raise。
    - 訓練端 `salt_core/tests/` 加手算小例子驗證打包。
- `.mem` commit 進 SALT-FPGA(`SaltConv.srcs/sources_1/mem/<量化資料夾>/`)，繞回版、飽和版各一份。
- 訓練端 `model.npz` 存的是 $q$(conv 形狀 `(OC, C, K, K)`)、`decay_table_int`、`v_th_int`。$\hat v_{th}$ 逐神經元存，conv 同一個 output channel 值相同。

## 參考文件

- [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md)：conv 層事件驅動 RTL 的完整推導。
- [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)：FC 層事件驅動 RTL 的設計，第 1~6 節已寫。
- [`Concept/Layer-RTL/SaltConvSynthFlow.md`](../Concept/Layer-RTL/SaltConvSynthFlow.md)：合成與實作流程、量測結果。
- [`Concept/model_operation_quant.md`](../Concept/model_operation_quant.md)：硬體看這份，整數版的參數、單筆事件更新、候選規則、多層串接、輸出層讀出。
- [`Concept/model_operation_float.md`](../Concept/model_operation_float.md)：浮點推導。
- 訓練端 `D:\Project\Spiking-Affine-Lazy-Training`：單狀態仿射 LIF 加 associative scan 平行掃描訓練，conv/FC 都支援，N-MNIST 約 92%。
