# CSNN 層 RTL TODO

## 目標

把 `D:\Project\Spiking-Affine-Lazy-Training` 訓練出來的 CSNN(conv1 → conv2 → FC)做成事件驅動 RTL，在 PL 端直接更新膜電位，不繞 PS。

- 行為要跟訓練端的整數規格逐位元一致。
- 功耗要打贏對應的 ANN 版本。
- 跟 [`ps_host_if` 替換](../../GENX320/Todo/ps_host_if_replacement_todo.md)平行進行。

## 現況

- Conv 層 `SaltConv` 完成(Part 0~9，2026-10-05 ~ 10-22)。
    - conv1 → conv2 串接(`SaltConvNet`)的輸出、兩層最終狀態跟訓練端逐位元相同。
    - 目標時脈 5 ns(200 MHz)：4.8 ns 下繞回、飽和兩版都過(+0.281、+0.205 ns，2026-10-27 SaltFC Part 6 之後)。
    - 量測結果、合成流程見 [`SaltConvSynthFlow.md`](../Concept/Layer-RTL/SaltConvSynthFlow.md)。
    - 各 Part 的完整過程(定案討論、反向測試)在 commit `dc9b22a` 版本的這份 TODO。
- Vivado 專案 `SaltNET/`(2026-10-24 從 `SaltConv/` 改名，見 Part 0)：
    - RTL 在 `SaltNET.srcs/sources_1/new/{lib,conv,fc,net}/`，`.mem` 在 `sources_1/mem/`。
    - testbench 在 `sim_1/new/{lib,conv,fc,net}/`，答案檔在各自的 `ref/`。
    - 模擬、合成腳本在 `SaltNET/scripts/{lib,conv,fc,net}/`，共用流程 `scripts/sim_common.tcl`。
- 讀現行 RTL：`SaltConv.sv` 照事件流程分 0~6 段(檔頭有目錄)。
    - 控制總覽：[`SaltConvOverview.md`](../Concept/Layer-RTL/SaltConvOverview.md)。
    - 逐拍例子、資料流程圖：[`Conv-image/SaltConvControl.md`](../Concept/Layer-RTL/Conv-image/SaltConvControl.md)、[`SaltConvDataflow.md`](../Concept/Layer-RTL/Conv-image/SaltConvDataflow.md)。
    - 設計推導：[`Conv.md`](../Concept/Layer-RTL/Conv.md) 5.5「實作」、5.8。
- 分支：Part 8.2、8.x 都已經 fast-forward 併進 `test`，`test` 已推到遠端。$o_c$ 重疊 B 做法的實作留在 tag `overlap-b-redo`(`e8c7163`)。
- FC 層設計 [`FC.md`](../Concept/Layer-RTL/FC.md) 第 1~6 節寫完，第 6 節 ⑤ 留到寫 RTL 時定；RTL 還沒開始。

## 交接(2026-10-28)

- SaltFC Part 7 做完、測完，已 commit，等使用者確認(細節見下面「Part 7」)。
- 下一步：把不遵守「答案用訓練端 salt_core 的函式產生、testbench 拿來比對」這條規則的 testbench 挖出來處理(2026-10-28 使用者要求，Part 7 之後做)。已知一支:`gen_spike_select_ref.py` 的候選用訓練端 `_axis_candidates`,送出順序卻是腳本自己照座標排序，沒有呼叫 `salt_core.stream`。
- SaltFC Part 0~3 完成。
- SaltFC Part 4 完成：4a conv 權重 ROM 改用 `lib/ReadOnlyMemory`；4b 權重位址兩層共用 `lib/WeightMemory`(細節見下面「Part 4 權重 BRAM」)。
- SaltFC Part 5 完成(細節見下面「Part 5」)：conv 展開 `WeightTapSelect`、`NeuronMemory` 搬到 lib、FC $\hat V$ 跟門檻的 testbench。
- SaltFC Part 6 完成(細節見下面「Part 6」)：`NeuronUpdate` 拆成 `lib/DecayLookup` + `lib/NeuronUpdate`，加 `SPIKE_OUTPUT`；FC 的兩個時間暫存器改放 Part 8。
- 分支 `test`，最新 commit 是 SaltFC Part 7，還沒 push；工作目錄乾淨。
- 這幾次定下來、之後的 Part 照著做的：
    - 模組分法(Part 5「已定」)：有邏輯才包模組，兩層相同的放 lib；打包、切段寫在各層 top 的 generate 區塊。conv、FC 結構要對稱，提案前先用這條檢查兩層是不是一樣。
    - 驗證範圍(「作法 → 驗證」)：搬位置、改名、展開這類行為不變的整理只做合成比對 + 改到的 testbench + 一支整層 testbench 的部分參數組。
    - 跟使用者討論時一次只講一個決定：先列兩層現況對照，再給選項表跟建議。
    - 只討論使用者要討論的事：TODO 延後表(D 編號)、程式裡的 reviewer 註解，使用者沒叫就不要自己拿出來處理。
    - 講人話：講路徑、訊號時說它實際在做什麼(例：「conv2 的 `in_ready` 反壓 conv1」)，不要直接搬腳本、報告裡的標籤；testbench 細節使用者不在意，不用主動展開。
    - 提量測時先想清楚目的再挑條件：要確認時序有沒有變差，就往更緊的目標週期跑(逼布局找好的)，不要排比現在還鬆的週期。
    - 使用者說「直接做完」時，設計決定都已經定好的話就整個 Part 做完再回報，不用一步一步問。
    - `SaltNET.xpr` 有改動就跟著 commit，不還原、不拿出來討論(見「作法 → 驗證」)。
- 留著沒查的：Part 5 第 1 步(選 tap 展開)合成後 LUT 少 42，原因沒查出來；功能、4.8 ns 都確認過。
- 這次碰到的工具問題：
    - 這台 git 設 `core.autocrlf=true`，有些答案檔在工作目錄是 CRLF(反向測試 `git checkout` 還原時轉的)。比對重產的答案檔要跟 `git show HEAD:<路徑>` 比，不要跟工作目錄的檔案直接比。
    - 從 Git Bash 呼叫 `wsl` 時，`/mnt/c/...` 會被 MSYS 轉成 Windows 路徑，要加 `MSYS_NO_PATHCONV=1`。
    - agent 的 Bash 工具用 heredoc 餵 Python 時，`\\` 會被吃掉一個；含反斜線的替換腳本改用檔案寫。
    - `wsl bash -lc "..."` 裡的 `\$變數` 到 WSL 那邊是空的；有迴圈、變數的指令寫成 `.sh` 檔再 `wsl bash <檔案>`。
    - 訓練端在 WSL 跑匯出、測試時 GPU 可能被別的程式佔滿(JAX 會印一串 `CUDA_ERROR_OUT_OF_MEMORY`)；這些都不用 GPU，加 `JAX_PLATFORMS=cpu`。直接跑 `.py` 要加 `PYTHONPATH=.`,`python -m` 不用。
    - `run_tb_neuron_memory.tcl` 9 組 ALL PASS 之後，印結果的 `puts` 報 `can not find channel named "stdout"`，exit 1；同一個 `puts` 在其他腳本都正常，原因查不到。`run_tb_salt_conv.tcl` 的 `ready_alternate` 第 3 組也碰到類似的事：模擬跑完，讀 `simulate.log` 的 `open` 失敗、錯誤訊息是空的。兩支單獨重跑都 ALL PASS，當偶發處理。2026-10-27 `run_tb_fc_weight_lookup.tcl`、`run_tb_weight_lookup.tcl`，2026-10-28 `run_tb_spike_select.tcl` 各碰到一次 `stdout` 那個(各組的總結行都是 ALL PASS，只有最後印總表的 `puts` 失敗)；網路上查不到 Vivado 的說明。
    - 2026-10-27 `tb_salt_conv_net_ready_burst` 第一次 elaborate 報 `Spawn failed: %1 不是有效的 Win32 應用程式`(vivado-usage skill 8.7)，單獨重跑就過。

## SaltFC

照 SaltConv 的作法：

- 每個 Part 都要過目確認才進下一個。
- 規劃一個 Part 時先列出這次做什麼、怎麼量、怎麼驗證，給使用者確認；一次只處理一個策略或一個機制。
- 做法要比較時，不問目標時脈、$R$、$C$ 設多少：量出每種做法的速度(時脈、拍數)跟成本(LUT、FF、BRAM、DSP、多幾拍、設計驗證多複雜)，整理成表給使用者選。
- 驗證照下面「作法」。

| Part | 內容 | FC.md | 狀態 |
|---|---|---|---|
| 0 | 專案結構(改名 `SaltNET`、資料夾重分) | — | 完成 |
| 1 | 訓練端匯出 FC 的權重、門檻、衰減表 | 第 2 節、第 3 節 ① | 完成 |
| 2 | 介面規格(parameter、port) | 第 1、6 節 | 完成 |
| 3 | 輸入 FIFO:直接用 `lib/EventFIFO`，不寫新模組，例化在 Part 8 | 第 1 節 | 完成 |
| 4 | 權重 BRAM：4a conv 權重 ROM 改用 lib 通用 ROM；4b 權重位址兩層共用 `lib/WeightMemory`、FC 權重查表 | 第 2 節「權重」 | 完成 |
| 5 | 神經元 BRAM、門檻 BRAM、清除 | 第 2 節「神經元」「門檻」 | 完成 |
| 6 | 膜電位更新：`NeuronUpdate` 拆成 lib `DecayLookup` + `NeuronUpdate`，加 spike 開關 | 第 3 節 | 完成 |
| 7 | spike 選擇：`fc/FCSpikeSelect`、conv 的改名 `ConvSpikeSelect`;bitmask、送出交握放 Part 8 | 第 4 節 ②③ | 做完，等使用者確認 |
| 8 | pipeline 整合 | 第 5 節 | 未開始 |
| 9 | 膜電位輸出 | 第 6 節 | 未開始 |
| 10 | conv → FC 轉接模組 | 第 1 節 | 未開始 |
| 11 | 串接 conv1 → conv2 → FC，跟訓練端比對 | — | 未開始 |
| 12 | 合成量測(4.8 ns) | — | 未開始 |

- 每個 Part 的細節到要做時才規劃；Part 8 要不要像 SaltConv 一樣從無腦版一步一步做，到時候再定。

### Part 0 專案結構

- 起因：`EventFIFO` 這類通用模組現在放在 `SaltConv` 裡，SaltFC 也要用。
- 已定(2026-10-24)：
    - 一個 Vivado 專案，從 `SaltConv` 改名 `SaltNET`，底下分 SaltConv、SaltFC 兩部分。
        - 不選兩個專案：Part 11 三層串接要在同一個地方模擬、合成，不用跨專案拉檔案。代價是同一個專案一次只跑一支模擬，這個限制現在本來就有。
    - RTL 放 `SaltNET.srcs/sources_1/new/` 底下四個資料夾：
        - `lib/`：跟層無關的通用模組，先放 `EventFIFO`、`NeuronMemoryArray`、`NeuronMemoryClear`(參數只有寬度、深度、`READ_LATENCY`)；Part 4 加了 `ReadOnlyMemory`、`WeightMemory`，Part 5 `NeuronMemory` 從 conv 搬過來。
            - 依賴方向(2026-10-27)：lib 可以用 lib，conv、fc 可以用 lib，lib 不用 conv、fc。第一個例子是 `WeightMemory` 例化 `ReadOnlyMemory`，跟 XPM 的 `xpm_memory_sprom` 例化 `xpm_memory_base` 同一種分法。
        - `conv/`：SaltConv 專用。
        - `fc/`：SaltFC 專用。
        - `net/`：多層串接的頂層，`SaltConvNet`、之後的三層串接。
    - `.mem` 照現在放 `sources_1/mem/<量化資料夾>/`。
    - 三層串接的頂層模組到 Part 11 再取名，不叫 `SaltNET`，免得跟專案同名分不清。
    - testbench、答案檔、腳本照 RTL 同一套資料夾分：
        - `sim_1/new/lib/`、`conv/`、`net/`、`fc/`，答案檔放在各自 testbench 旁邊的 `ref/`(例：`sim_1/new/conv/ref/`)。
        - `scripts/lib/`、`scripts/conv/`、`scripts/net/`；所有 `run_tb_*.tcl` 共用的 `sim_common.tcl` 留在 `scripts/` 最上層。
        - `tb_neuron_memory` 放 `conv/`：測的是 `CandidateGrid` 加 `NeuronMemory`，$\{t_{last},\hat V\}$ 打包是 conv 的(Part 5 起 `NeuronMemory` 在 lib，打包寫在 testbench 跟 SaltConv 裡)。
        - conv 的 Python 答案腳本彼此 import，全部放 `scripts/conv/` 同一層。
        - 例外：`gen_salt_conv_ref.py` 在 `scripts/conv/`，同一次計算順便寫兩層串接的答案檔，用 `--net-out-dir` 輸出到 `sim_1/new/net/ref/`。
- 做法(2026-10-24)：
    - 使用者用 GUI 建空專案 `SaltNET/SaltNET.xpr`(board `kv260_som`，part `xck26-sfvc784-2LV-c`，跟舊專案相同)，不加原始碼。
        - 不用 `save_project_as`：`help save_project_as` 沒寫 `.srcs` 裡的原始碼會不會跟著複製；反正檔案清單要照新資料夾重建。
    - 檔案用 `git mv` 搬，歷史接得上；舊的 `SaltConv/SaltConv.xpr` 留到驗證完再刪。
    - `sim_common.tcl`：
        - 開專案時把 `sources_1/new/{lib,conv,fc,net}/` 的 `.sv` 全部加進 `sources_1`。原本每支腳本只加自己要的 RTL，靠跑的順序湊齊，新專案先跑哪支都會缺檔。
        - 建模擬集收成 `create_simset_if_missing`(原本 7 支腳本各複製一份，`run_tb_candidate_axis.tcl` 沒有)。
        - `run_param_sets` 多一個答案檔目錄參數，每支腳本傳自己的 `ref/`。
    - `tb_event_fifo`：參數改成 `parameter`，總結行改成共用格式，新增 `scripts/lib/run_tb_event_fifo.tcl`。
    - testbench 參數預設值(GUI 單組模擬用的相對路徑)、答案腳本、合成腳本裡的 `SaltConv.srcs` 改成 `SaltNET.srcs`。
- 還要定的：
    - `NeuronUpdate`(每顆自己算 $\Delta t$，FC 整層共用一個)要不要改成兩層共用：Part 6 定了，拆成 `lib/DecayLookup`、`lib/NeuronUpdate`(見「Part 6」)。`WeightMemory` 在 Part 4 定了(見「Part 4 權重 BRAM」)。

### Part 1 訓練端匯出

- 已定(2026-10-22)：FC 權重寬字的內容跟硬體參數 $n_{col}$(每列幾顆神經元)有關，匯出時傳入 $n_{col}$ 打包；換 $n_{col}$ 要重新匯出。
- 跟 conv 同一套分工(見「已定案設計 → 權重匯出格式」)：打包函式加在訓練端 `salt_core/fpga_export.py`，`tools/export_fpga.py` 只負責讀 `model.npz`；格式規格只寫在 FC.md，docstring 指過去。
- 已定(2026-10-24)：
    - `tools/export_fpga.py` 用 `--fc-cols N` 給 $n_{col}$，所有 FC 層共用；網路有 FC 層卻沒給就報錯。之後有多層 FC 要各自設定，再改成逐層寫法。
    - FC 的 `.mem` 先不 commit 進這個 repo：$n_{col}$ 要等 Part 4、8 量出各種做法的速度跟成本、使用者選定才確定。在那之前答案腳本用打包函式自己產生要測的版本。
- 做法(2026-10-24，訓練端)：
    - `salt_core/fpga_export.py`：
        - 「好幾個欄位接成一個寬字、第 0 個在最低位」收成 `_packed_word_lines`，conv 權重、FC 權重、FC 門檻共用；conv 現有函式的名字、參數不變(這個 repo 的答案腳本有 import)。
        - 新增 `fc_weight_lines(q, weight_width, n_col)`、`fc_threshold_lines(v_th_int, n_out, membrane_width, n_col)`、`write_fc_layer_mem(out_dir, layer, params, weight_width, n_col)`。
        - 不 fire 的 FC 層(`v_th_int=None`)不寫門檻檔；實際的 `out` 層就是這樣，只有 `out_weight.mem`、`out_decay.mem`。
        - 整層寫檔改成內容全部算完、檢查過才建目錄寫檔(conv 也跟著改)，出錯時不留任何檔。
    - `salt_core/tests/test_fpga_export.py`：手算例子(行的順序、位址 $y\cdot n_{in}+\text{src}$、最後一列補 0、寬字位元數不是 4 的倍數、$n_{col}=1$、$n_{col}>n_{out}$、門檻打包、拆回來等於 $q$、各種 raise 不寫檔)。
    - 訓練端 `docs/架構.md`、`README.md` 的說明改成 conv、FC 都匯出。

### Part 2 介面

- 規格本體是 `SaltNET.srcs/sources_1/new/fc/SaltFC.sv`，這裡只記定案的理由。
- 已定(2026-10-25)：
    - 跟 SaltConv 同義的 parameter 同名沿用；FC 新增 `IN_NEURONS`($n_{in}$)、`OUT_NEURONS`($n_{out}$)、`NEURONS_PER_ROW`($n_{col}$)、`SPIKE_OUTPUT`、`MEMBRANE_OUTPUT`。
    - 輸入 port 叫 `in_neuron`(行尾註解標 $\text{src}$)，不叫 `in_src`：FC 接 FC 時上一層的 `out_neuron` 直接接同名的 `in_neuron`，跟 conv 接 conv 的同名規則一樣。
    - $\text{src}$ 位寬是 `localparam`，由 $n_{in}$ 推出，不另開 parameter(FC.md 第 1 節跟著改)：$\text{src}$ 一定落在 $0\sim n_{in}-1$；conv 的 `X_WIDTH` 開成 parameter 是因為輸入座標位寬由上游決定，FC 沒有這個情況。
    - 開關關掉時 port 還在(SystemVerilog 不能照 parameter 拿掉 port)，`valid` 固定 0，合成時修剪。
    - 膜電位輸出埠：`membrane_valid`、`membrane_ready`、`membrane_row_start`($y\cdot n_{col}$)、`membrane_values`($n_{col}\cdot w$)、`membrane_time`(FC.md 第 6 節 ③)。
- 驗證(2026-10-25)：本體是空的，只確認能 elaborate、port 位寬對。non-project `synth_design -rtl`(不碰 `.xpr`)，逐 port 數位元數：

| 參數 | `in_neuron` | `out_neuron`、`membrane_row_start` | `membrane_values` |
|---|---|---|---|
| 預設($n_{in}=1296$、$n_{out}=10$、$n_{col}=4$、$w=14$) | 11 | 4 | 56 |
| $n_{col}=1$ | 11 | 4 | 14 |
| $n_{in}=n_{out}=n_{col}=1$ | 1 | 1 | 14 |
| $w=11$、$n_{col}=10$、spike 關、膜電位開 | 11 | 4 | 110 |

- 時間 port 都是 16 位元，`valid`/`ready`、`clk`、`rst_n` 都是 1 位元。

### Part 4 權重 BRAM

- 已定(2026-10-25)：做法 A，唯讀 ROM 收成 `lib/ReadOnlyMemory`(參數只有深度、寬度、$R$、檔名，位址從外面給)，conv 權重、FC 權重、FC 門檻(Part 5)共用。
    - 不選 B(lib ROM 只給 FC，conv 不動)、C(FC 自己一份)：同一段 ROM 會重複兩、三份。
    - conv 的 `WeightMemory` 只留位址計算 $o_c\cdot C+c$；`keep_hierarchy = "soft"` 跟 `NeuronMemoryArray` 一樣只框陣列跟讀出暫存器。
    - 分兩步：4a 先讓 conv 改用 lib ROM、證明行為跟時序沒變，4b 才做 FC。
- 4a 做法(2026-10-25)：
    - 新增 `lib/ReadOnlyMemory.sv`；`conv/WeightMemory.sv` 改成算位址 + 例化 `ReadOnlyMemory`(實例名 `memory_array`)。
    - `tb_salt_conv_common.svh` 讀權重真值的階層路徑改成 `dut.weight_memory.memory_array.rom`。
- 4a 驗證(2026-10-25)：
    - 模擬(專案副本，GUI 開著)：`tb_weight_lookup` 9 組、`tb_salt_conv_ready_{high,random,burst,alternate}` 各 70 組、`tb_salt_conv_net_ready_{high,random,burst}` 各 2 組，全部 ALL PASS。
    - 合成後(布局前)：兩版的 LUT、FF、BRAM、DSP，跟 10 顆 BRAM 的 `DOA_REG`/`DOB_REG`，跟改動前完全相同(改動前的 RTL 從 git HEAD 取出，同一支檢查腳本各跑一次)。
    - 布局繞線 4.8 ns：繞回 +0.213 → +0.319、飽和 +0.131 → +0.128，兩版都過；FF 數的差異是布局時搬出的 BRAM 輸出暫存器數量不同，見 `SaltConvSynthFlow.md`「現行 RTL：兩層串接」。
    - 碰到的工具問題：
        - 飽和版第一次合成在 `opt_design` 報 `[Synth 20-411]`(訊息空白，模擬同時在跑)，單獨重跑就過，同 vivado-usage skill 第 11 節。
        - 專案副本放在 agent 的暫存目錄(路徑約 140 字元)時，模擬集名稱長的幾支 elaborate 報 `XSIM 43-3409 Failed to compile generated C file`：xsim 的 `.obj` 路徑 260 字元以上的都失敗，258 以下的都過(Windows MAX_PATH)。副本改放 `C:/Users/salt/AppData/Local/Temp/s4a/` 重跑就過。`ready_burst` 還碰到一次讀 `simulate.log` 的 `open` 失敗(偶發，同上)。
- 4b 已定(2026-10-27)：
    - 權重位址兩層同一個算法：外層編號 × 內層數量 + 事件編號(conv $o_c\cdot C+c$，FC $y\cdot n_{in}+	ext{src}$)，每拍用組合邏輯算。
        - 比過另一種：位址存在暫存器，新事件時放事件編號、之後每拍加內層數量，加法器不在輸入 FIFO → 讀位址的路徑上。
        - 單獨量 FC 讀取這一段(`EventFIFO` → 位址 → `ReadOnlyMemory`，實際參數，4.8 ns，$R=1$、$2$ 結果相同；量測 RTL 沒進 repo)：

| | 每拍算(選這個) | 位址暫存器 |
|---|---|---|
| 繞線後 WNS | +2.275 ns | +2.419 ns |
| 最長路徑 | 2.066 ns：FIFO 讀指標 → LUT 記憶體 → 2 段 CARRY8 → LUT → BRAM 位址 | 1.934 ns：FIFO 讀指標 → LUT 記憶體 → LUT → BRAM 位址 |
| LUT / FF / BRAM | 34 / 23 / 3.5 | 35 / 24 / 3.5 |

        - 差 0.13 ns，在單次 ±0.2 ns 的變動內。選每拍算：位址只看兩個輸入，不用處理新事件、停住；conv 的 $C$(2、8)是 2 的次方，這個算法沒有邏輯，conv 不用改。
        - Part 12 量整個 FC 時這條路徑如果卡住，再把 `WeightMemory` 改成位址暫存器的算法，兩層一起換。
    - 位址計算收成 `lib/WeightMemory`，conv、FC 共用：
        - 不拆成 `ConvWeightMemory`、`FCWeightMemory`：算法一樣，兩份內容相同。
        - 不在各層 top 各寫一次：算式單獨測不到，FC 要到 Part 8 才驗得到。
        - 參數 `IN_INDEX_WIDTH`、`IN_COUNT`、`OUT_COUNT`、`WORD_WIDTH`、`READ_LATENCY`、`WEIGHT_FILE`；port `out_index`(conv $o_c$、FC $y$)、`in_index`(conv $c$、FC $	ext{src}$)、`read_word`。
        - `IN_INDEX_WIDTH` 開成參數：conv 的 `IN_CHANNEL_WIDTH` 由上游決定，不一定等於 $\lceil\log_2 C
ceil$。
    - 寬字切段放各層 top：
        - conv 原本照舊用 `WeightTapSelect`；Part 5 第 1 步改成在 SaltConv 每個 bank 的 generate 區塊裡選(見 Part 5)。
        - FC 在 SaltFC 每行的 generate 區塊裡切第 $x$ 段；$\hat V$、門檻的寬字也在同一個區塊切。SaltFC 本體到 Part 8 才寫，切段跟著寫。
    - 原本做的 `fc/FCWeightMemory`(位址由上層算、模組裡切段)沒 commit，刪掉。
- 4b 做法(2026-10-27)：
    - `conv/WeightMemory.sv` 用 `git mv` 搬到 `lib/`，改成上面的參數、port；`SaltConv`、`tb_weight_lookup` 跟著改。實例名 `weight_memory`、`memory_array` 不變，`tb_salt_conv_common.svh` 的階層路徑不用改。
    - 正式專案 `.xpr` 用 batch `remove_files` 拿掉舊路徑；新路徑、`lib/ReadOnlyMemory.sv` 由 `sim_common.tcl` 加進去了。
    - `sim_1/new/fc/tb_fc_weight_lookup.sv`：例化 `lib/WeightMemory`(FC 參數)，送 $(y,	ext{src})$，在 testbench 裡照 SaltFC 的切法切段，窮舉比對 $n_{col}$ 個權重碼(含最後一列補 0 的位置)。
    - `scripts/fc/gen_fc_weight_lookup_ref.py`：答案直接從 $q$ 算，不經過權重檔的打包；權重檔用訓練端 `fc_weight_lines` 寫，跟答案放在 `sim_1/new/fc/ref/`(實際參數的也放這裡，不放 `sources_1/mem/`，見 Part 1)。讀量化資料夾、隨機 $q$ import `scripts/conv/gen_weight_lookup_ref.py` 的 `trained_q`、`synthetic_q`。
    - `scripts/fc/run_tb_fc_weight_lookup.tcl`：參數組 $(n_{in},n_{out},n_{col},b,R)$。
- 4b 驗證(2026-10-27，正式專案，GUI 已關)：
    - `tb_fc_weight_lookup` 的參數組：

| $n_{in}$ | $n_{out}$ | $n_{col}$ | $b$ | $R$ | 情況 | 比對數 |
|---|---|---|---|---|---|---|
| 1296 | 10 | 4 | 7 | 1、2 | 實際參數 | 各 15552 |
| 7 | 5 | 1 | 7 | 1 | 一個位址一個碼 | 35 |
| 7 | 10 | 3 | 9 | 2 | 最後一列補 2 格 0、寬字 27 bits | 84 |
| 5 | 3 | 4 | 4 | 1 | $n_{col}>n_{out}$，只有一列 | 20 |
| 1 | 1 | 1 | 4 | 2 | 深度 1、位寬下限 | 1 |

    - 模擬：`tb_fc_weight_lookup` 6 組、`tb_weight_lookup` 9 組、`tb_salt_conv_ready_{high,random,burst,alternate}` 各 70 組、`tb_salt_conv_net_ready_{high,random,burst}` 各 2 組，全部 ALL PASS。
    - 實際參數的權重檔跟 Part 1 用 `tools/export_fpga.py --fc-cols 4` 匯出的 `out_weight.mem`(繞回、飽和兩版)逐 byte 相同。
    - 合成後(布局前，兩層串接)：兩版跟改動前(git HEAD)的 `report_utilization` 除了日期、指令兩行逐行相同(LUT 繞回 1275、飽和 1273，FF 421，BRAM 8，DSP 8)，10 顆 BRAM 的 `DOA_REG`/`DOB_REG` 也相同。
    - 反向測試：`WeightMemory` 的位址改成 `in_index * OUT_COUNT + out_index`。
        - 外層、內層數量都大於 1 的組全部 FAIL：FC 4 組、conv 8 組。
        - 外層數量是 1 的組(FC 的 $n_{row}=1$ 兩組、conv 的 OC=1)兩種算式相同，PASS。
        - 改回後兩支再跑一次，全部 ALL PASS。
    - FC 的切段寫在 testbench 裡，RTL 的切段要等 SaltFC 寫好，由整層 testbench 驗。

### Part 5 神經元 BRAM、門檻 BRAM、清除

- 已定(2026-10-27)：
    - 模組怎麼分，兩層用同一條規則：
        - 有邏輯要做(算位址、清除選擇)才包模組；兩層相同的邏輯放 lib，共用一份。
        - 寬字的打包、切段(conv 選 tap、打包 $\{t_{last},\hat V\}$；FC 切 $n_{col}$ 段)一律寫在各層 top 每份電路的 generate 區塊裡，不包模組。
        - 結果是 conv、fc 資料夾沒有記憶體的包裝模組，兩層 top 都直接用 lib。
    - 選 tap 不包模組的取捨：
        - 兩邊都包(conv `WeightTapSelect`、FC 另包一個只有接線的模組)：$\hat V$、門檻的切段也得各包一個，模組越包越多。
        - 兩邊都不包：SaltConv 每個 bank 多一行 `assign`，拿掉例化的 10 行，總行數幾乎不變。
        - 代價：tap 選擇沒有單獨的 testbench，`tb_weight_lookup` 裡照 SaltConv 的寫法選；RTL 那份由 `tb_salt_conv` 驗(K=1、3、4、5，S=1、2，沒有 K=7、S=3)。
    - 新的 lib 模組沿用名字 `NeuronMemory`(從 `conv/` 搬到 `lib/`)，port `clearing`、`clear_addr`、`write_enable`、`write_addr`、`write_word`、`read_enable`、`shift_enable`、`read_addr`、`read_word`。
    - 門檻 BRAM 沒有位址計算，SaltFC 直接例化 `lib/ReadOnlyMemory`。
    - $t_{last}$ 兩個暫存器不在 Part 5；2026-10-27 定放 Part 8(見 Part 6)。
- 步驟：

| 步驟 | 內容 | 狀態 |
|---|---|---|
| 1 | conv 展開 `WeightTapSelect`：刪掉模組，每個 bank 在 SaltConv 的 generate 區塊裡選 tap | 做完 |
| 2 | `conv/NeuronMemory` 搬到 `lib/`，只留清除選擇 + `NeuronMemoryArray`，寬字進出；$\{t_{last},\hat V\}$ 打包搬到 SaltConv 的 generate 區塊 | 做完 |
| 3 | FC $\hat V$：`lib/NeuronMemory` 用 FC 參數(寬 $n_{col}\cdot w$、深 $n_{row}$)，新 testbench 測清除 $n_{row}$ 拍、清完是 0、讀寫後切出的第 $x$ 段 | 做完 |
| 4 | FC 門檻：`lib/ReadOnlyMemory` 讀 Part 1 格式的門檻檔，新 testbench 比對每列切出的 $n_{col}$ 個門檻(含最後一列補 0)；實際 `out` 層不 fire、沒有門檻檔，只用隨機參數組 | 做完 |

- 第 3、4 步的切段先寫在 testbench 裡，SaltFC 的 generate 區塊到 Part 8 才有。
- 第 1 步做法(2026-10-27)：
    - `SaltConv.sv`：拿掉 `WeightTapSelect` 例化跟 `weight_code` 二維陣列；`row_banks`/`col_banks` 的 generate 區塊裡用 `pipe_tap_y[READ_LATENCY][row_bank]`、`pipe_tap_x[READ_LATENCY][col_bank]` 選，tap 超出 $K-1$ 給 0；`WeightTapSelect` 檔頭的範圍檢查說明、84 → 98 LUT 的量測搬到註解。
    - `git rm conv/WeightTapSelect.sv`，`.xpr` 用 batch `remove_files` 拿掉。
    - `tb_weight_lookup.sv`：例化 `WeightTapSelect` 改成 testbench 裡同一個寫法的 generate；答案檔、腳本不動。
    - `lib/WeightMemory.sv` 檔頭、`SaltConvDataflow.md` 流程圖、`SaltConvSynthFlow.md`「設計決定的量測依據」表的名稱跟著改。
- 第 1 步驗證(2026-10-27，只挑必要的)：
    - `tb_weight_lookup` 9 組 ALL PASS(testbench 改了)。
    - `tb_salt_conv_ready_high` 只跑 R2C2 重疊 10 組(`-tclargs tb_salt_conv_ready_high READ_LATENCY:2 COMPUTE_LATENCY:2 OVERLAP:1`)，K=1、3、4、5 都 ALL PASS，含訓練端 conv1、conv2 兩版。
    - 合成後(布局前，兩層串接)跟 HEAD 比：FF 421、BRAM 8、DSP 8、10 顆 BRAM 的 `DOA_REG`/`DOB_REG` 相同；LUT 繞回 1275 → 1233、飽和 1273 → 1231，兩版都少 42。選法照搬，LUT 為什麼變少沒查出原因。
- 第 2 步做法(2026-10-27)：
    - `conv/NeuronMemory.sv` 用 `git mv` 搬到 `lib/`：參數 `DEPTH`、`WORD_WIDTH`、`READ_LATENCY`(跟 `NeuronMemoryArray` 同名)，寬字進出，只留清除選擇 + `NeuronMemoryArray`。
    - `SaltConv.sv`：每個 bank 的 generate 區塊裡打包 `{pipe_time[L], new_membrane}`、讀出拆成 `membrane`、`last_time`；新增 `NEURON_WORD_WIDTH`。實例名 `neuron_memory`、`memory_array` 不變，`tb_salt_conv_common.svh`、`tb_salt_conv_net_common.svh` 的階層路徑不用改。
    - `tb_neuron_memory.sv`：打包、拆開改寫在 testbench 的 generate 裡；答案檔、腳本不動。
    - `lib/NeuronMemoryClear.sv` 檔頭改成 conv、FC 共用的說法。
- 第 3 步做法(2026-10-27)：
    - `sim_1/new/fc/tb_fc_neuron_memory.sv`：`NeuronMemoryClear` + `lib/NeuronMemory`(深 $n_{row}$、寬 $n_{col}\cdot w$)，切段照 SaltFC 每行的寫法寫在 testbench 裡；寫入值由 testbench 的函式產生(第一格下界、最後一格上界)，不用答案檔。
    - 流程：reset(期間送全 1 的外部寫入，檢查 `clearing` 剛好 $n_{row}$ 拍)→ 讀全部要是 0 → 寫全部 → 讀回比對 → 再 reset → 讀全部要回到 0。
    - `scripts/fc/run_tb_fc_neuron_memory.tcl`：參數組 $(n_{out},n_{col},w,R)$ = (10,4,14,1)、(10,4,11,2)(訓練端 out 層繞回、飽和的 $w$)、(10,3,9,2)、(5,1,7,1)、(3,4,6,1)(只有一列)、(1,1,4,2)。
- 第 4 步做法(2026-10-27)：
    - `scripts/fc/gen_fc_threshold_lookup_ref.py`：隨機門檻(前兩個是 $w$ 位元上下界，共用 conv 的 `synthetic_q`)，答案直接從門檻算，門檻檔用訓練端 `fc_threshold_lines` 寫，放 `sim_1/new/fc/ref/`。參數組跟第 3 步相同的 $(n_{out},n_{col},w)$。
    - `sim_1/new/fc/tb_fc_threshold_lookup.sv`：`lib/ReadOnlyMemory`(深 $n_{row}$、寬 $n_{col}\cdot w$)讀每一列，切段寫在 testbench 裡，比對 $n_{col}$ 個門檻(含最後一列補 0)。
    - `scripts/fc/run_tb_fc_threshold_lookup.tcl`：上面 6 組，$R$ 同第 3 步。
- FC.md 第 2 節「神經元」「門檻」記上用哪個 lib 模組、切段在哪裡。
- 第 2~4 步驗證(2026-10-27)：
    - `tb_neuron_memory` 9 組 ALL PASS(第一次跑第 9 組 elaborate 碰到 `USF-XSIM-95 Failed to open file to read (elaborate.log)`，整支重跑就過)。
    - `tb_fc_neuron_memory` 6 組、`tb_fc_threshold_lookup` 6 組、`tb_fc_weight_lookup` 6 組 ALL PASS。
    - `tb_salt_conv_ready_high` R2C2 重疊 10 組、`tb_salt_conv_net_ready_high` 2 組 ALL PASS。
    - 反向測試(新 testbench 才做)：
        - `lib/NeuronMemory` 清除時照寫外部資料(不寫 0)：`tb_fc_neuron_memory` 6 組全部 FAIL，第一次清除後就抓到。
        - 門檻答案檔改壞一格($n_{col}=3$ 那組)：只有那組 FAIL，`MISMATCH y=2 column=0`；重新產生後 12 個檔跟原本逐檔相同。
    - 合成後(布局前)：第 2 步前後逐行相同(LUT 繞回 1233、飽和 1231)。
    - 布局繞線 4.8 ns(Part 5 全部做完)：繞回 +0.283、飽和 +0.254，兩版都過，見 `SaltConvSynthFlow.md`「現行 RTL：兩層串接」。

### Part 6 膜電位更新

- 已定(2026-10-27)：`conv/NeuronUpdate` 拆成兩個獨立的 lib 模組，conv、FC 共用，兩層 top 都例化「衰減查表 + 膜電位更新」，只有份數不同。
    - 不選「膜電位更新加參數、選內部算 ① 或外部接 $A$」：FC 那一份 ① 一定在 $n_{col}$ 份外面，衰減查表還是要獨立成模組，參數只是把它藏進 conv；port 不能照參數拿掉，兩種模式的 port 永遠都在，兩種模式都要測。
    - 不選「FC 的 ① 寫在 SaltFC top」：① 會有兩份。
    - ① 小也包模組：有減法、比較、ROM，照 Part 5「有邏輯才包模組」；lib 已經有 `WeightMemory` 這種大小的模組。
    - 起因：conv 每顆神經元有自己的 $t_{last}$，① 在 `NeuronUpdate` 裡每份各算；FC 整層共用 $t_{last}$，一列只要 1 份 ①，$n_{col}$ 顆共用。直接用 `NeuronUpdate`，FC 會多 $n_{col}-1$ 份衰減表；另寫一份 ②③④ 又跟 conv 重複。

| 模組 | 內容 | conv 份數 | FC 份數 |
|---|---|---|---|
| 衰減查表 | ① $\Delta t$ → 衰減碼 $A$(含 $\Delta t=0$ 給 1.0、超過 $\Delta t_{\max}$ 給 0) | M×M | 1 |
| 膜電位更新 | ②③④，輸入 $A$、$\hat V$、$q$、門檻；C=2 的切點留在 ② 之後；加 spike 開關參數(FC 可關) | M×M | $n_{col}$ |

- 拆的時候要一起處理：
    - `salt_conv_impl.xdc` 用 `*neuron_update/rounded_product` 找乘法 DSP 設 `DONT_TOUCH`：實例名沿用 `neuron_update`、`rounded_product` 留在裡面，pattern 不用改，拆完確認 8 顆都套上。
    - FC 最後一列空位置的 fire 遮罩($y\cdot n_{col}+x<n_{out}$)在 SaltFC top 做，不放進模組。
- 已定(2026-10-27)名稱、port：
    - 衰減查表：新檔 `lib/DecayLookup.sv`，實例名 `decay_lookup`；參數 `TIME_WIDTH`、`DECAY_FRAC_WIDTH`、`DECAY_TABLE_DEPTH`、`DECAY_FILE`；輸入 `event_time`、`last_time`，輸出 `decay_code`(`DECAY_FRAC_WIDTH+1` 位元)。不叫 `DecayTable`：還有 $\Delta t$ 減法跟兩種特例，不只 ROM。
    - 膜電位更新：`conv/NeuronUpdate.sv` 用 `git mv` 搬到 `lib/`，沿用名字跟實例名 `neuron_update`(同 Part 5 `NeuronMemory`)，xdc 的 `*neuron_update/rounded_product`、testbench 的階層路徑不用改。
        - 拿掉 `TIME_WIDTH`、`DECAY_TABLE_DEPTH`、`DECAY_FILE`；留 `DECAY_FRAC_WIDTH`(乘積位寬、右移、round 加半格要用)。
        - `last_time`、`event_time` 換成 `decay_code`，跟 `DecayLookup` 的輸出同名直接接。
- 已定(2026-10-27)spike 開關：`NeuronUpdate` 加參數 `SPIKE_OUTPUT`(跟 SaltFC 同義同名)，關掉時 `spike` 固定 0、`new_membrane` 直接給 $\hat V'$，`threshold` 例化時接 0，比較器跟寫 0 的選擇器合成時修剪。
    - 不選「模組只輸出 $\hat V'$，比門檻、寫 0 交給各層 top」：同一段邏輯兩份。
    - 不選「模組不動，給到不了的門檻」：飽和版 $\hat V'$ 最大 $2^{w-1}-1$，$w$ 位元門檻沒有比它大的值。
    - conv 理論上也可以不 fire(只累積膜電位)，所以 `NeuronUpdate` 不假設 conv 一定 fire。SaltConv 這次例化時傳 `1'b1`；SaltConv 自己要不要開 `SPIKE_OUTPUT` 見 D11。
- 已定(2026-10-27)FC 的兩個時間暫存器(事件暫存器的 $t$、上一筆 $t$)跟每個管線位置帶的 $t$、$t_{last}$ 放 Part 8，寫在 SaltFC top：更新時機是最後一列推進那拍，屬於 Part 8 的推進規則，Part 6 寫了也接不上、測不到；conv 的事件暫存器、`pipe_time` 也在 SaltConv top。
- Part 6 做完的樣子：`lib/DecayLookup.sv`、`lib/NeuronUpdate.sv` 兩個模組，SaltConv 每個 bank 例化這兩個(行為、時序不變)；SaltFC 仍然只有 parameter、port。
- 做法(2026-10-27)：
    - 新增 `lib/DecayLookup.sv`：① 整段從 `NeuronUpdate` 搬過來，邏輯、衰減表屬性不變；使用者的 reviewer 註解跟著 $\Delta t$ 搬過來。
    - `conv/NeuronUpdate.sv` 用 `git mv` 搬到 `lib/`：拿掉 ①、`TIME_WIDTH`、`DECAY_TABLE_DEPTH`、`DECAY_FILE`，`last_time`、`event_time` 換成 `decay_code`，加 `SPIKE_OUTPUT`(generate 區塊 `fire`/`no_fire`)。
    - `SaltConv.sv`：每個 bank 的 generate 區塊例化 `decay_lookup`(接 BRAM 讀出的 $t_{last}$、`pipe_time[R]`)再接 `neuron_update`，`SPIKE_OUTPUT` 傳 `1'b1`。
    - `tb_neuron_update` 只測 lib 模組，照 Part 0 的資料夾規則搬到 lib：`sim_1/new/lib/tb_neuron_update.sv`、`sim_1/new/lib/ref/`、`scripts/lib/{gen_neuron_update_ref.py,run_tb_neuron_update.tcl}`。
        - testbench 串 `DecayLookup` → `NeuronUpdate`，加參數 `SPIKE_OUTPUT`。
        - 答案檔每行多一欄 $\hat V'$(`process_event` 不給門檻算的，訓練端不 fire 的層也是這樣呼叫，`salt_core/quant/scan.py` `_run_layer_scan`)；`SPIKE_OUTPUT = 0` 時比 `spike = 0`、`new_membrane` = $\hat V'$。
        - 參數組：原本 8 組 × ROUND × SATURATE 都是 `SPIKE_OUTPUT = 1`，另加 8 組 × SATURATE 的 `SPIKE_OUTPUT = 0`(ROUND = 1；不 fire 只差在 fit 之後，繞回、飽和兩種就夠)，共 48 組。
    - 正式專案 `.xpr` 用 batch `remove_files` 拿掉 `sources_1/new/conv/NeuronUpdate.sv`，`sim_neuron_update` 的 testbench 換成新路徑。
    - 文件：FC.md 第 3 節 ①②④ 記上用哪個 lib 模組、spike 開關就是 `SPIKE_OUTPUT`；`SaltConvDataflow.md`、`SaltConvSynthFlow.md` 的名稱跟著改。
- 驗證(2026-10-27)：
    - 重新產生的答案檔前 7 欄跟改動前(git HEAD)逐行相同(36 個檔)，衰減表檔逐檔相同。
    - `tb_neuron_update` 48 組 ALL PASS。
    - 反向測試：`SPIKE_OUTPUT = 0` 的寫回改成「到門檻寫 0」，只跑 spike 關的 6 組(conv2 繞回、飽和的 $w$ 跟一組人工參數 × SATURATE)，6 組全部 FAIL；還原後跟測過的版本相同。
    - 合成後(布局前，兩層串接)跟 HEAD 比：繞回、飽和兩版的 `report_utilization` 除了日期、指令兩行逐行相同(LUT 1233、1231，FF 421，BRAM 8)，10 顆 BRAM 的 `DOA_REG`/`DOB_REG` 相同；xdc 的 `DONT_TOUCH` 套上 8/8 顆乘法 DSP。
    - `tb_salt_conv_ready_high` R2C2 重疊 10 組、`tb_salt_conv_net_ready_high` 2 組 ALL PASS。`run_tb_salt_conv.tcl` 10 組的總結行都是 ALL PASS 之後，印總表的 `puts` 又報一次 `can not find channel named "stdout"`(exit 1，同交接「工具問題」那條)。
    - 布局繞線 4.8 ns(使用者要求簡單確認)：繞回 +0.283 → +0.281、飽和 +0.254 → +0.205，兩版都過，最長路徑同一類(神經元 BRAM 讀出 → 計算第 1 級乘法 DSP)，見 `SaltConvSynthFlow.md`「現行 RTL：兩層串接」。
    - WNS 比改動前小，改動前、改動後再各跑一次 4.6 ns：改動後繞回 +0.300(改動前 +0.065)、飽和 +0.344(改動前 +0.022)。兩個目標取最好的 FMAX：繞回 221.4 → 232.6 MHz、飽和 220.0 → 235.0 MHz。差距在同一份電路布局的變動範圍內，沒有變差。
    - 合成腳本的跨層路徑改名：`conv1_output_to_conv2`(conv1 送 spike 事件給 conv2)、`conv2_ready_to_conv1`(conv2 反壓 conv1，沒有資料送回)。
    - 沒做：`tb_salt_conv` 完整回歸。

### Part 7 spike 選擇與輸出

- 範圍：FC.md 第 4 節 ②③(挑哪一顆、送出的編號 $i$)。只有 `SPIKE_OUTPUT = 1` 時用到。
- 已定(2026-10-28)：
    - FC 的挑選自己一個模組 `fc/FCSpikeSelect`，不收進 lib：conv 的順序由窗左上角的 bank 決定(每筆事件不同)、在 M×M 裡挑座標，FC 順序固定、在一列 $n_{col}$ 位元裡給行號，算法不一樣(Part 4b 的標準：算法一樣才收成一份)。兩層共用的只有「找第一個 1」，為了它改 conv 要重跑整層回歸跟時序。
        - 不選「lib 放通用優先權編碼器，conv 也改用」：conv 挑 fire 那段在管線停不停的路徑上，改了要重量。
        - 不選「寫在 SaltFC top」：違反 Part 5「有邏輯才包模組」，單獨測不到。
    - conv 的 `SpikeSelect` 改名 `ConvSpikeSelect`，跟 `FCSpikeSelect` 配對；例化名 `spike_select`、testbench 那一串(`tb_spike_select`、`sim_spike_select`、`spike_select_*.txt`)不改：testbench 本來就靠有沒有 `fc_` 分層。
    - bitmask、送出交握、停住放 Part 8，寫在 SaltFC top，跟 conv 第 6 段一樣：
        - 這一拍要挑哪些(算的那一拍是 $s$ 加最後一列空位置的遮罩，停住的拍子是 bitmask)要分得出「是不是算的那一拍」，靠 Part 8 的管線。
        - 輸出「還有沒有剩」決定整條管線停不停、讀不讀下一列，是 Part 8 的推進規則；FC 還要併 Part 9 膜電位輸出沒被收走的條件。
        - 不選「收成 lib 模組兩層共用」：挑選模組夾在中間，port 要繞一圈(吐出要挑的 → 各層挑選模組 → 收回挑到哪顆)，而且 conv 這段在停住的路徑上，改了要重量。
    - `FCSpikeSelect` 直接輸出 $i=y\cdot n_{col}+x$(輸入這一列帶的 $y\cdot n_{col}$)，跟 `ConvSpikeSelect` 直接輸出 $o_y$、$o_x$ 對稱，兩層 top 都只接線；$n_{col}$ 是 2 的次方就把 $x$ 接進低位，其他用加法，兩條分支都在 Part 7 的 testbench 測到。
- 做法(2026-10-28)：
    - 第 1 步 conv 改名：`git mv conv/SpikeSelect.sv conv/ConvSpikeSelect.sv`，module 名、SaltConv 與 `tb_spike_select` 的例化、`CandidateAxis`/`CandidateGrid`/SaltConv 註解、`gen_candidate_axis_ref.py`/`gen_spike_select_ref.py` 說明、`SaltConvOverview.md`、`SaltConvControl.md`、`SaltConvDataflow.md`、`SaltConvSynthFlow.md`、架構總覽 drawio(命令列重新匯出 svg)跟著改；`.xpr` 用 batch `remove_files` 拿掉舊路徑。
    - 第 2 步 `fc/FCSpikeSelect.sv`：參數 `OUT_NEURONS`、`NEURONS_PER_ROW`；輸入 `pending`($n_{col}$ 位元)、`row_start`($y\cdot n_{col}$)，輸出 `found`、`selected`(one-hot)、`selected_neuron`($i$)。generate 三支：2 的次方而且 $i$ 位寬比 $x$ 寬(接位元)、2 的次方只有一列($i$ 就是 $x$)、其他(加法，含 $n_{col}=1$)。
    - `scripts/fc/gen_fc_spike_select_ref.py`：送出順序用訓練端 `salt_core.stream.extract_output_events_fc` 算(FC 層 forward 把 spike 排成下一層事件流的函式)；每列窮舉合法行的子集合，做只有一筆輸入事件的 `spike_mask` 丟進去，前 `n_real_events` 筆的 `event_source_idx` 就是預期的 $i$。
    - `sim_1/new/fc/tb_fc_spike_select.sv` + `scripts/fc/run_tb_fc_spike_select.tcl`：照預期順序一步一步比 `found`、`selected`、`selected_neuron`，每步用答案(不用 DUT 的 `selected`)清掉那一行；參數組 $(n_{out},n_{col})$ = (10,4)、(10,3)、(13,5)、(20,8)、(5,1)、(3,4)、(2,8)、(1,1)。
    - FC.md 第 4 節 ②③ 記上用 `FCSpikeSelect`、bitmask 跟交握在 SaltFC top。
- 驗證(2026-10-28)：
    - 第 1 步(行為不變的整理)：
        - 合成後(布局前，兩層串接)跟 HEAD 比：繞回、飽和兩版的 `report_utilization` 除了表頭(日期、指令、分隔線長度)逐行相同(LUT 1233、1231，FF 421，BRAM 8，DSP 8)，10 顆 BRAM 的 `DOA_REG`/`DOB_REG` 相同。
        - `tb_spike_select` 8 組 ALL PASS(印總表的 `puts` 又報 `can not find channel named "stdout"`，同交接「工具問題」)。
        - `tb_salt_conv_ready_high` R2C2 重疊 10 組 ALL PASS。
    - 第 2 步：
        - `tb_fc_spike_select` 8 組 ALL PASS(共 686 個 case、2379 步)。
        - 反向測試：
            - 改成挑最大的那一行：$n_{col}>1$ 的 6 組全部 FAIL;$n_{col}=1$ 的 (5,1)、(1,1) PASS(一列只有一行，挑最大跟最小是同一顆)。
            - 「直接接位元」那支不接 $x$(低位給 0):只有走這支的 (10,4)、(20,8) FAIL;(3,4)、(2,8) 走「只有一列」那支，PASS。
            - 還原後跟測過的版本逐 byte 相同。
- 不做：合成量測。`FCSpikeSelect` 要等 Part 8 接進 SaltFC 才有實際電路，Part 12 一起量。

### Part 11 串接比對

- 用 `reference.npz` 的 `v_final_int` 比整條推論，見「待決事項 → 驗證」。
- 訓練端的 `v_final` 多做了一步 catch-up(每顆神經元再衰減到樣本最後一筆事件的時間，權重 0)，硬體不做；SaltConv 的答案腳本比的是 catch-up 之前的 $\hat V$，FC 也要先處理這個差異。

## 延後、擱著的項目

| 編號 | 項目 | 什麼時候處理 |
|---|---|---|
| D1 | 時序 C：`ConvSpikeSelect` 改成看「窗裡排在我前面的有沒有 pending」，不轉讀的順序 | 整合後 5 ns 過不了才做 |
| D2 | 時序 D：讀位址路徑(FIFO 最前面那筆 → 選這次要讀哪一筆 → `CandidateGrid` → BRAM 讀位址)；4.8 ns 量測裡 M=3 繞回、兩層串接飽和版的最長路徑就是這條 | 整合後 5 ns 過不了才做 |
| D4 | 讀取開關每拍都開，還是推進那一拍才開 | 之後討論 |
| D5 | testbench 重整：`tb_salt_conv_common.svh` 的 `run_sample` 一個 task 混了驅動、交握檢查、涵蓋統計、拍數、比對 | 碰到要改 testbench 時一起處理 |
| D6 | 上層攤平時 BRAM 輸出暫存器為什麼併不進去 | 換 Vivado 版本時再確認一次 |
| D7 | 權重記憶體改 XPM | 目前不做 |
| D8 | 衰減表 ROM 的 LUT 用量($M\times M$ 份組合邏輯查表) | 吃太多再回頭檢討 |
| D9 | `CandidateAxis` 的除法、`CandidateGrid` 的乘常數用 LUT 還是 DSP | 合成後看 utilization，必要時加 `USE_DSP="no"` |
| D10 | FC 權重放 URAM | 延後，這一版用 BRAM |
| D11 | SaltConv 開 `SPIKE_OUTPUT` 參數(conv 當不 fire 的層) | 有網路要用到時 |

- D4：
    - 每拍都開：讀取開關不用等推進的判斷，量起來稍快(時脈多 0.5~4 MHz，接近布局繞線的變動範圍)；卡住的拍子($k\ge2$、`out_ready=0`)、$R=2$ 等資料的拍子會白讀記憶體，多耗電。
    - 推進才開：不會白讀；讀取開關接在推進的判斷後面，慢一點點。
    - 還沒評估：白讀的次數、多耗多少電。
- D5：方向是共用可以(避免同一段檢查改四次)，但核心流程(餵資料、比輸出、比神經元狀態)要在一個地方看得完；涵蓋統計拆開，跟核心分開。
- D6：現在靠 `keep_hierarchy = "soft"` 加上每次合成檢查 `DOB_REG` 確認；Vivado 內部原因 log 跟官方文件都沒寫，查不到(vivado-usage skill 第 10 節)。
- D7：要先解決 `MEMORY_INIT_FILE` 只能給檔名、不能帶路徑的問題(權重檔改成不重複的檔名、加進專案，訓練端匯出的命名可能也要改)；XPM 也要求記憶體至少 2 個字。
- D10：URAM 不能帶初始值，權重要在執行時寫入。
- D11：只開參數不夠，SaltConv 不 fire 就沒有任何輸出，要跟 FC 一樣加膜電位輸出埠才有用；`NeuronUpdate` 在 Part 6 已經支援。

## 待決事項

### 量化與數值

- `FIFO_DEPTH`：反壓、不丟事件的策略已定，深度要看目標時脈跟實際輸入事件率，事件率還沒有。
- FPGA 上實際省多少功耗：運算量少 20 倍不等於功耗少 20 倍，漏電流、clock tree 是固定成本，要 Vivado 功耗分析或實測才有數字。

### 系統整合

- `EvtDecoder → conv1` 轉接模組：要先查 `EvtDecoder` 的 `M_AXIS_TDATA` 實際打包的欄位(EVT2.1)，才能寫 unpack。
- µs 換 ms：用 floor，$t=\lfloor t_{\mu s}/1000\rfloor$，跟訓練端相同。放在轉接模組裡還是另開一個模組還沒定。
- 時間戳記繞回：連續事件流的時間戳記到 $2^{\texttt{TIME\_WIDTH}}$ ms 會繞回，之後 $\Delta t=t-t_{last}$ 會算錯。
    - 怎麼處理還沒討論；跟神經元記憶體清除是兩件事。
    - `DecayLookup` 現在用 `TIME_WIDTH` 位元無號減法算 $\Delta t$，不替繞回做決定。
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

- 答案檔：Python 腳本用訓練端的函式產生，放 testbench 旁邊的 `ref/`(例：`sim_1/new/conv/ref/`)。
    - 環境是 WSL 的 conda 環境 `jax`(`~/miniconda3/envs/jax/bin/python`)。
    - 整層的答案用兩份互相比對，一致才寫答案檔：訓練端官方的整層 forward，跟照硬體做法逐筆算的迴圈(例：`scripts/conv/gen_salt_conv_ref.py`)。
    - 參數組：訓練端的實際參數 × 繞回、飽和兩版，加上人工參數(不是 2 的次方、位寬下限、邊界情況)；人工參數的權重用訓練端同一個打包函式產生 `.mem`。
- testbench：讀答案檔逐筆比對，不一致印出輸入、欄位、預期值、實際值，最後印一行總結(`ALL PASS` / `FAIL`)。
    - 參數用 generic 帶入，答案檔目錄用 `-testplusarg REF_DIR=` 帶入。
    - 一支 testbench 只測一種情況(例如一種反壓方式)，不同情況拆成不同檔案；共用的部分放 `.svh`，但核心流程要在一個地方看得完。
    - 機制維持一個 `initial` 流程(negedge 給值、posedge 前檢查)，不用多個並行 process、SVA。
    - 涵蓋統計跟核心流程分開，要加之前先問。
    - 反向測試：改壞 RTL 或答案檔，確認會 FAIL；跑完還原，確認跟 commit 相同。
    - 驗證範圍看改動挑必要的：搬位置、改名、展開這類行為不變的整理，合成比對 + 改到的 testbench + 一支整層 testbench 的一部分參數組就好，不跑完整回歸(完整回歸 `tb_salt_conv` 四支約 40 分鐘)、不做反向測試。
- 跑模擬：一個 testbench 一個模擬集，`scripts/<資料夾>/run_tb_*.tcl` 跑所有參數組，共用流程在 `scripts/sim_common.tcl`。
    - 第一次跑時腳本自己建模擬集，RTL 由 `sim_common.tcl` 一次加進 `sources_1`；新的 testbench 照 `scripts/lib/run_tb_event_fifo.tcl` 寫。
    - 多組參數一律用 batch 模式跑；從 GUI 的 Tcl Console 跑，連續 elaborate 會不定時出現 `Spawn failed`。
    - 一個 Vivado session 只跑一個模擬集：第二個會沿用第一個的檔案清單(vivado-usage skill 8.8)。多支 testbench 由 `run_testbenches_in_children` 每支開一個子 Vivado。
    - 同一個專案一次只跑一支：多個 Vivado 同時開 `.xpr` 跑模擬會互相改寫專案檔。non-project 的合成不碰 `.xpr`，可以跟模擬同時跑。
    - 跑完 `.xpr` 會留下作用中的模擬集、generic 這些改動，直接跟著 commit，不還原(2026-10-27 改：還原會讓 repo 裡的 `.xpr` 留著搬走的舊路徑)。
    - `run_tb_salt_conv.tcl` 只跑部分參數組時，`-tclargs` 加 `NAME:value` 條件(例：`OUT_CHANNELS:1`)。
    - GUI 只用來跑 testbench 預設參數的單組模擬、看波形；GUI 開著時在專案副本上跑，不要動正式專案的 `.xpr`。
- Vivado 的已知陷阱記在本機的 `.claude/skills/vivado-usage/SKILL.md`(不進 repo)。從 agent 的 shell 跑 Vivado 要先 `env -u NoDefaultCurrentDirectoryInExePath`(8.6)。

### 合成量測

- 流程、參數、量測結果都在 [`SaltConvSynthFlow.md`](../Concept/Layer-RTL/SaltConvSynthFlow.md)：兩層串接用 `SaltNET/scripts/net/synth_salt_conv_net.tcl`，比較做法時的單層量測見「比較做法時的量測(單層)」。
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
    - conv 同一拍 $M\times M$ 個候選各自查，`DecayLookup` 每份各帶一張 LUT ROM。
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
    - 另外一個值 `min_bank`：窗最小座標 $o_{max}-(M-1)$ 的 bank，$(m_{max}+1)\bmod M$，給 `ConvSpikeSelect` 用；不是 Conv.md 第 2 節 $o_{min}$ 的 bank。
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

- 每層三個 `$readmemh` 用的 hex 檔：權重寬字、門檻、衰減表 $A[\Delta t]$；不 fire 的 FC 層沒有門檻檔。
    - Vivado 合成只收 `$readmemh`、`$readmemb` 兩種(UG901 Table 24)，選 hex。
    - 格式規格只寫在 Conv.md(第 2 節「權重」「門檻」、第 3 節 ①「檔案格式」)、FC.md(第 2 節「權重」「門檻」、第 3 節 ①)，這裡不重複。
    - 二補數，一行一個位址，固定 $\lceil\text{位元數}/4\rceil$ 個 hex 字元，最左邊補 0。
- 匯出程式由訓練端寫，docstring 指到 Conv.md、FC.md，不在訓練端文件另寫一份規格。
    - 打包函式放 `salt_core/fpga_export.py`(輸入陣列、輸出 `.mem`)，`tools/export_fpga.py` 只負責讀 `model.npz`。
    - SALT-FPGA 測非 2 的次方參數時，答案檔腳本 import 同一個打包函式產生隨機權重的 `.mem`。
    - 輸入一個量化資料夾，`--out-dir` 指定輸出，有 FC 層時 `--fc-cols` 給 $n_{col}$；每層 `<層>_weight.mem`、`<層>_threshold.mem`、`<層>_decay.mem`。
    - 匯出時檢查：$q$ 超出 $b$ 位元、門檻超出 $w$ 位元(conv 另外檢查同一個 $o_c$ 的門檻不全相同)、衰減表超出 $f_a$ 位元，都 raise。
    - 訓練端 `salt_core/tests/` 加手算小例子驗證打包。
- `.mem` commit 進 SALT-FPGA(`SaltNET.srcs/sources_1/mem/<量化資料夾>/`)，繞回版、飽和版各一份。
- 訓練端 `model.npz` 存的是 $q$(conv 形狀 `(OC, C, K, K)`)、`decay_table_int`、`v_th_int`。$\hat v_{th}$ 逐神經元存，conv 同一個 output channel 值相同。

## 參考文件

- [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md)：conv 層事件驅動 RTL 的完整推導。
- [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)：FC 層事件驅動 RTL 的設計，第 1~6 節已寫。
- [`Concept/Layer-RTL/SaltConvSynthFlow.md`](../Concept/Layer-RTL/SaltConvSynthFlow.md)：合成與實作流程、量測結果。
- [`Concept/model_operation_quant.md`](../Concept/model_operation_quant.md)：硬體看這份，整數版的參數、單筆事件更新、候選規則、多層串接、輸出層讀出。
- [`Concept/model_operation_float.md`](../Concept/model_operation_float.md)：浮點推導。
- 訓練端 `D:\Project\Spiking-Affine-Lazy-Training`：單狀態仿射 LIF 加 associative scan 平行掃描訓練，conv/FC 都支援，N-MNIST 約 92%。
