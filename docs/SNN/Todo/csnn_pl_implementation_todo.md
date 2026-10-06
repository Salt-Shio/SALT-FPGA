# Conv 層 RTL(SaltConv)TODO

## 目標

把 `D:\Project\Spiking-Affine-Lazy-Training` 訓練出來的 CSNN conv 層做成事件驅動 RTL，在 PL 端直接更新膜電位，不繞 PS。

- 行為要跟訓練端的整數規格逐位元一致。
- 功耗要打贏對應的 ANN 版本。
- 跟 [`ps_host_if` 替換](../../GENX320/Todo/ps_host_if_replacement_todo.md)平行進行。

## 進度

Vivado 專案 `SaltConv/`，頂層 module `SaltConv`。
RTL 在 `SaltConv/SaltConv.srcs/sources_1/new/`，testbench 在 `sim_1/new/`，模擬腳本在 `SaltConv/scripts/`。
每個 Part 都要過目確認才進下一個。

| Part | 內容 | Conv.md | 狀態 | 檔案 |
|---|---|---|---|---|
| 0 | 介面規格(parameter、port) | — | 完成 | `SaltConv.sv` |
| 1 | 輸入 FIFO | — | 完成 | `EventFIFO.sv`、`tb_event_fifo.sv` |
| 2 | 候選神經元與 banking 位址(純組合邏輯) | 第 2 節「神經元」 | 完成 | `CandidateAxis.sv`、`CandidateGrid.sv`、`tb_candidate_axis.sv`、`tb_candidate_grid.sv` |
| 3 | 權重 BRAM 讀取與 tap 選擇 | 第 2 節「權重」 | 未開始 | |
| 4 | 神經元 BRAM($\hat V,t_{last}$)介面，先做單埠無腦版 | 5.2 | 未開始 | |
| 5 | LIF 膜電位更新 | 第 3 節 | 未開始 | |
| 6 | bitmask 優先權排序與輸出 | 第 4 節 | 未開始 | |
| 7 | pipeline FSM 整合，先做無腦版 | 5.1、5.2 | 未開始 | |
| 8 | 優化：管線化、反壓、讀取延遲一般化 | 5.3~5.5 | 視情況再細分 | |

## 下一步：Part 3 權重 BRAM 讀取與 tap 選擇

規格在 Conv.md 第 2 節「權重」：

- 權重 BRAM 唯讀，位址 $(o_c,c)$ 攤平，深度 $OC\times C$。
- 每個位址存一整個 kernel：$K\times K$ 個權重碼打包成一個寬字，寬 $K\times K\times b$。
- 讀出寬字後，每個候選用自己的 $(k_y,k_x)$ 選出 tap 位置 $k_y\times K+k_x$ 的權重碼，是讀出後的 $K\times K$ 選 1 多工，不是另一次定址。
- 同一拍的 $M\times M$ 個候選共用同一個寬字($o_c$、$c$ 相同)，各自做一次多工。

接 Part 2 的地方：

- `CandidateGrid` 每組輸出的 `tap_y`、`tap_x` 就是 $(k_y,k_x)$，`valid=0` 的組不能用。
- $o_c$ 跟 `CandidateGrid` 的 `out_channel` 是同一個值(之後由 Part 7 的計數器給)，$c$ 是輸入事件的 `in_channel`。

開始寫 RTL 之前要先定：

1. **權重檔格式**：見下方「權重匯出格式」還沒定的四項，要跟訓練端一起定。檔案格式決定 RTL 怎麼拆寬字，所以要先定。
2. **讀取延遲怎麼呈現**：BRAM 讀取要 1 clock，Conv.md 第 2 節把「第幾拍讀」留到 pipeline 階段(Part 7)。Part 3 的模組介面要不要先把這 1 拍包進去，要先討論。

## 驗證流程(Part 1、2 用的做法，Part 3 之後照做)

- **答案檔**：Python 腳本用訓練端的函式產生，放 `SaltConv.srcs/sim_1/new/ref/`。
    - 環境是 WSL 的 conda 環境 `jax`(`~/miniconda3/envs/jax/bin/python`)。
    - 範例：`scripts/gen_candidate_grid_ref.py`。
- **testbench**：讀答案檔逐筆比對，不一致印出輸入、欄位、預期值、實際值，最後印一行總結(`ALL PASS` / `FAIL`)。
    - 參數用 generic 帶入，答案檔目錄用 `-testplusarg REF_DIR=` 帶入。
    - 範例：`tb_candidate_grid.sv`。
- **跑模擬**：一個 testbench 一個模擬集，`scripts/run_tb_*.tcl` 跑所有參數組，共用流程在 `scripts/sim_common.tcl`。
    - 多組參數一律用 batch 模式跑；從 GUI 的 Tcl Console 跑，連續 elaborate 會不定時出現 `Spawn failed`(原因不明)。
    - GUI 只用來跑 testbench 預設參數的單組模擬、看波形。
- **Vivado 的已知陷阱**記在本機的 `.claude/skills/vivado-usage/SKILL.md`(不進 repo)。
    - 最常碰到的是：GUI 開著專案時，外面用 batch 改的專案設定會被 GUI 存檔蓋掉。GUI 開著就在專案副本上跑，不要動正式專案的 `.xpr`。
- **單獨合成子模組**用 out-of-context(`synth_design -mode out_of_context`)，不然 port 會被當成晶片接腳算進 IOB。

## 專案狀態備註

- `sim_candidate_axis` 模擬集的 `REF_DIR` 被 GUI 存檔蓋掉了。跑 `run_tb_candidate_axis.tcl` 不受影響(腳本每次都會重設)，但在 GUI 對它直接 Run Simulation 會報缺 `REF_DIR`。下次跑這支腳本時會補回去。
- `synth_1` 是 out-of-context，top 是 `CandidateGrid`。之後單獨合成別的子模組，改 top 就好。

## 待決事項

### 量化與數值

- **膜電位暫存器寬度選哪一版**：訓練端給了兩版，$f_V=0$，所以 $w=i_V$。
    - 繞回版：conv1 12 bits、conv2 14 bits，test 0.9222。驗證跟 test 都沒碰到範圍，繞回不會真的發生。
    - 飽和版：conv1 9 bits、conv2 11 bits，test 0.9229。幾乎每筆樣本都會碰到範圍，硬體要逐位元夾住。
    - 其他都相同：$b=7$、$f_a=6$、$f_V=0$、捨入用 `round`，衰減表、門檻、權重碼也相同。
    - `SaltConv` 的 `SATURATE` 參數兩種都支援，選定後由例化端傳入。
- **`FIFO_DEPTH`**：反壓、不丟事件的策略已定，深度要看目標 clock 頻率跟 conv2/compress 的實際輸入事件率，這兩個數字還沒有。
- **FPGA 上實際省多少功耗**：運算量少 20 倍不等於功耗少 20 倍，漏電流、clock tree 是固定成本，要 Vivado 功耗分析或實測才有數字。

### 合成後要確認

- **衰減表 ROM 的 LUT 用量**：$M\times M$ 份組合邏輯查表電路，吃太多再回頭檢討。
- **`CandidateAxis` 的除法、`CandidateGrid` 的乘常數**：除以 $S$、除以 $M$ 不是 2 的次方時，UG901 沒寫會用 LUT 還是 DSP；乘常數也一樣。
    - `CandidateAxis` 單獨合成，$K=3,S=1$：LUT，0 DSP。
    - `CandidateGrid` 預設參數($K=3,S=1,P=1$，64×64，$OC=16$，$M=3$)，out-of-context：306 LUT、54 CARRY8，0 DSP。
    - 其他參數(包括實際的 conv1、conv2)合成後看 utilization，必要時加 `USE_DSP="no"`。

### 權重匯出格式(Part 3 開始前要定)

- 已定：每層三個 `$readmemh` 用的 hex 檔，權重寬字、$\hat v_{th}[o_c]$、$A[\Delta t]$。
- 還沒定：
    - $(o_c,c)$ 攤平的順序。
    - 寬字內 $K\times K$ 個 tap 的排列。
    - 有號數的 hex 表示法。
    - 訓練端由誰寫匯出程式。
- 訓練端 `model.npz` 存的是 $q$、`decay_table_int`、`v_th_int`。$\hat v_{th}$ 逐神經元存，同一個 output channel 值相同。
- 訓練端 TODO 的「量化模型的匯出格式」在等這邊的規格。

### 系統整合

- **`EvtDecoder → conv1` 轉接模組**：要先查 `EvtDecoder` 的 `M_AXIS_TDATA` 實際打包的欄位(EVT2.1)，才能寫 unpack。
- **µs 換 ms**：用 floor，$t=\lfloor t_{\mu s}/1000\rfloor$，跟訓練端相同。放在轉接模組裡還是另開一個模組還沒定。
- **時間戳記繞回**：連續事件流的時間戳記到 $2^{\texttt{TIME\_WIDTH}}$ ms 會繞回，之後 $\Delta t=t-t_{last}$ 會算錯。
    - 怎麼處理還沒討論。
    - 跟神經元記憶體清除是兩件事。
- **輸出層乘 $s_i$**：$\text{score}_i=\hat V[i]\cdot s_i$ 是整個推論唯一的浮點運算，放 FPGA 內還是外部還沒定。conv 層不需要 $s$。
- **跟 `ps_host_if` 替換模組要不要融合**：等兩邊資源用量(BRAM、LUT、功耗)出來再決定。

### 驗證

- **用 `reference.npz` 逐位元比對**：每個量化資料夾都有 val 前 2000 筆的逐筆結果。
    - 欄位：`preds`、`v_final_int`(輸出層暫存器最終值)、`spike_count`(每層 spike 總數)、`overflowed`(每層有沒有碰到暫存器範圍)。
    - `v_final_int` 逐位元相同，就代表整條推論對上。
    - conv 層單獨驗證時只有 spike 總數可比，沒有逐筆的 spike 序列。

## 已定案設計

### 運算方式

- 事件驅動：每筆事件到達就用經過的整數 ms 數 $\Delta t$ 做解析衰減、判斷 fire，不等下一筆事件。
- 跟 spikingjelly 逐步更新不是同一個函數，已放棄精確等效。硬體的整數規格見 [`model_operation_quant.md`](../Concept/model_operation_quant.md) 第 3 節。
- 候選神經元、banking、LIF 更新、輸出排序、pipeline 時序的推導見 [`Conv.md`](../Concept/Layer-RTL/Conv.md)。

### 介面(Part 0)

- 規格本體就是 `SaltConv.sv`，文件不重複貼。parameter 預設值都是佔位，每個 layer 例化時傳入完整參數。
- 事件介面用分欄位 port(`in_x`、`in_y`、`in_channel`、`in_time`)，不打包成 `TDATA`。
    - `EvtDecoder` 打包是被 PS 端 AXI DMA 規格限制，`SaltConv` 沒有這個限制。
- 命名：
    - parameter、port 用描述性完整名稱，不用 `K`、`S`、`OC` 這類單字母，行尾註解標 Conv.md 的數學符號。
    - `_WIDTH` 專指位元寬，影像尺寸用 `OUT_ROWS`、`OUT_COLS`。
    - 事件介面前綴用 `in_`、`out_`。
- 量化參數：`WEIGHT_WIDTH`($b$)、`MEMBRANE_INT_WIDTH`($i_V$)、`MEMBRANE_FRAC_WIDTH`($f_V$)、`DECAY_FRAC_WIDTH`($f_a$)、`DECAY_TABLE_DEPTH`($\Delta t_{\max}$)。
    - `MEMBRANE_WIDTH`($w$)是 `localparam`，由整數位加小數位推出。
    - 捨入、溢位行為做成 `ROUND`、`SATURATE` 兩個 `bit` 參數，兩種都要能合成。
    - $\tau$ 不進硬體，只透過衰減表 $A[\Delta t]$ 出現。
- 訓練出來的三份資料不佔 port，用 `$readmemh` 從檔案載入，檔名參數是 `WEIGHT_FILE`、`THRESHOLD_FILE`、`DECAY_FILE`。
    - 檔名參數不寫型別：UG901 不支援 `string` 型別參數，也不支援空字串參數。

### 門檻與衰減表

- **門檻 $\hat v_{th}[o_c]$**：逐 output channel 一份(per-channel 權重量化下每個 channel 不同)。
    - 載入後是編譯期常數，合成成 mux，不另外配置記憶體。
- **衰減表 $A[\Delta t]$**：兩版共用同一張，深度 $\Delta t_{\max}=75$，每格 $f_a=6$ bits 無號，值 $60,56,53,\dots,1$。
    - 同一拍 $M\times M$ 個候選要同時查(Conv.md 第 3 節 ①)。
    - 用 LUT 做 ROM，組合邏輯讀取，由綜合工具生成 $M\times M$ 份。

### 輸入 FIFO(`EventFIFO`)

- 只有輸入端有 FIFO。
    - 輸出端靠 Conv.md 第 4 節的 bitmask 排序送出。
    - 下游 `ready=0` 時直接反壓，卡住整條內部 pipeline(Conv.md 5.4 節)。
- 獨立成參數化寬度的可重用子模組，自己寫，不用 Xilinx IP。
    - 深度小(現行 16)，用不到 BRAM 管理能力。
    - 介面是分欄位，套 AXI4-Stream IP 反而要多包一層 pack/unpack。
- 現在是 distributed RAM 版，輸出遵守 valid/ready 交握，外部不假設任何固定延遲。
    - 之後深度開大換 BRAM(讀取多 1 clock)，只要改 `EventFIFO` 內部把 `valid` 延後對齊，外部不用動。

### 候選計算(`CandidateAxis`、`CandidateGrid`)

- 拆成單軸子模組，參數 $K,S,P,O_{max}$，y、x 各例化一次。上層做 $M\times M$ 配對跟 bank 內位址攤平。
    - 候選條件兩軸獨立，只有位址攤平要兩軸合併。
    - 單軸可以窮舉驗證。
    - 非正方形 kernel 只要兩個實例傳不同參數。
- 輸出 $M$ 組，第 $r$ 組就是 bank $r$($o\bmod M=r$)的候選，每組帶 $\{valid,\ o,\ \lfloor o/M\rfloor,\ k\}$。
    - $o\bmod M$ 就是組的編號，不另外輸出。
    - $k$ 在這裡一起算好，給 Part 3 選權重 tap。
- 輸出 port 每個欄位各自一個 unpacked array：`valid`、`out_coord`、`bank_offset`、`tap`，長度 `BANK_COUNT`，位寬用模組參數算。
    - 不用 struct：要多一個共用巨集 `.svh`，上層兩軸位寬不同還要各開 generate block，專案其他地方也沒用 struct。
- 兩軸配對獨立成子模組 `CandidateGrid`，可以單獨窮舉驗證。
    - 輸入 $(y,x)$ 跟這一拍的 $o_c$，輸出 $M\times M$ 組 `valid`、`bank_addr`、$(o_y,o_x)$、$(k_y,k_x)$。
    - 只算到位址，不含 BRAM；BRAM 是 Part 3、Part 4。
- bank 內位址用乘常數攤平：$(o_c\cdot G_y+g_y)\cdot G_x+g_x$，不把每一維補到 2 的次方(Conv.md 第 2 節「bank 內部位址」)。
    - 補到 2 的次方，在 $OC=16$、$G_y=G_x=22$ 時 BRAM 用量約兩倍。
- 每個 bank 容量一律 $OC\times G_y\times G_x$，邊界不整除時有些 bank 空幾格(Conv.md 第 2 節「每個 bank 容量」)。

### 神經元記憶體清除

- 換樣本時所有層的 $\hat V$、$t_{last}$ 都要回到 0。
- 不開 port：`rst_n` 釋放後逐位址寫 0，清除期間 `in_ready=0`(Conv.md 第 2 節「清除」)。
- 只用在剛開機跟實驗重來。實際應用是連續事件流，沒有樣本邊界。
- `rst_n` 會丟掉 FIFO、pipeline 裡還沒處理完的事件。
    - 實驗時要等上一個樣本處理完才 reset。
    - 怎麼知道處理完，是驅動實驗那一端的事。

### 層間事件格式

- conv 跟 FC 分開，不統一：
    - conv 層的輸入、輸出都是分欄位座標 $(x,y,c,t)$。
    - FC 層的輸入是攤平編號 $(\text{src},t)$，直接拿 $\text{src}$ 當權重矩陣 column 索引。
- 格式轉換由誰負責：
    - `EvtDecoder → conv1`：`EvtDecoder` 輸出打包的 `TDATA`，中間一個小型轉接模組做 unpack，由 top 例化，不算 `SaltConv` 或 `EvtDecoder` 內部。`EventProcessor.sv`(GENX320 範圍)不改。
    - `conv → conv`：欄位直接對應($o_c\to c$、$o_y\to y$、$o_x\to x$、$t\to t$)，直接接線。位寬一致是上下層參數配置的責任。
    - `conv → FC`：要換成 $i=o_c\cdot H_{out}W_{out}+o_y\cdot W_{out}+o_x$，需要實際運算，等 FC.md 定案再處理。

### 目前不做

- **事件間 pipeline overlap**(讓不同 $o_c$ 的讀跟算/寫重疊)：
    - 省下的是固定 2~3 拍，不隨 $OC$ 變大，理論吞吐量餘裕已經很大。
    - 等實測吞吐量真的不夠再評估。

## 參考文件

- [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md)：conv 分支事件驅動 RTL 的完整推導。
- [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)：FC 分支，還沒開始。
- [`Concept/model_operation_quant.md`](../Concept/model_operation_quant.md)：硬體看這份，整數版的參數、單筆事件更新、候選規則、多層串接、輸出層讀出。
- [`Concept/model_operation_float.md`](../Concept/model_operation_float.md)：浮點推導。
- 訓練端 `D:\Project\Spiking-Affine-Lazy-Training`：單狀態仿射 LIF 加 associative scan 平行掃描訓練，conv/FC 都支援，N-MNIST 約 92%。
