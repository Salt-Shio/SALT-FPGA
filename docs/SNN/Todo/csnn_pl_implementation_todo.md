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
    - 模擬、合成腳本在 `SaltNET/scripts/{lib,conv,fc,net}/`，共用流程 `scripts/sim_common.tcl`(模擬)、`scripts/synth_common.tcl`(合成，2026-11-14 起)。
- 讀現行 RTL：`SaltConv.sv` 照事件流程分 0~6 段(檔頭有目錄)。
    - 控制總覽：[`SaltConvOverview.md`](../Concept/Layer-RTL/SaltConvOverview.md)。
    - 逐拍例子、資料流程圖：[`Conv-image/SaltConvControl.md`](../Concept/Layer-RTL/Conv-image/SaltConvControl.md)、[`SaltConvDataflow.md`](../Concept/Layer-RTL/Conv-image/SaltConvDataflow.md)。
    - 設計推導：[`Conv.md`](../Concept/Layer-RTL/Conv.md) 5.5「實作」、5.8。
- 分支：工作在 `test`，`main` 停在 `5507967`。$o_c$ 重疊 B 做法的實作留在 tag `overlap-b-redo`(`e8c7163`)。
- FC 層設計 [`FC.md`](../Concept/Layer-RTL/FC.md) 第 1~6 節寫完(第 6 節 2026-11-07 改成膜電位輸出不握手、加層外的暫存器模組與 PS 轉接)；RTL 做完 Part 10(整層管線含 fire、膜電位輸出、層外的 `fc/FCMembraneRegister`、conv → FC 轉接模組 `fc/ConvToFCAdapter`)。
- 整個網路 `net/SaltConvFCNet`(conv1 → conv2 → 轉接模組 → FC → 膜電位暫存器，Part 11，2026-11-11 做完，使用者確認 2026-11-14)：test 前 10 筆、繞回飽和兩版，每一層每一次更新的 $(t,\hat V)$、每個 spike 跟訓練端逐筆相同。整條網路層級沒測到的情況見「Part 11 → 沒測到的」。
    - 4.8 ns 兩版都過(繞回 +0.301、飽和 +0.179，Part 12，2026-11-14)；BRAM 12.5、DSP 12、LUT 約 1470。

## 交接(2026-11-15)

- SaltFC Part 12(合成量測)進行中，細節見下面「Part 12」。
    - 實際網路 `SaltConvFCNet` 4.8 ns 兩版都過(繞回 +0.301、飽和 +0.179)；合成共用流程抽成 `scripts/synth_common.tcl`，改前改後結果相同。
    - 極限測試 BRAM 73 顆(50.7%)兩版都過(+0.151、+0.092)，先被吃掉餘裕的是 FC。
    - 等使用者決定：極限測試要不要補到約 82 顆(多一層 FC 256 → 128)、要不要量最高時脈。
    - 檔案還沒 commit，清單見「Part 12」最後。
    - 極限測試的資料要先在 WSL 跑 `scripts/net/gen_salt_stress_net_mem.py`(寫到 `SaltNET.runs/stress_net_mem/`，不進版控)。
- SaltFC Part 11(整個網路串接比對)完成，使用者確認(2026-11-14)，細節見下面「Part 11」。
    - 頂層 `net/SaltConvFCNet`：conv1 → conv2 → `ConvToFCAdapter` → SaltFC → `FCMembraneRegister`，直接例化，不經過 `SaltConvNet`。
    - 每一層每一次更新的 $(t,\hat V)$、每個 spike、FC 每筆事件之後的 10 顆 $\hat V$ 都跟訓練端逐筆相同：2 支 testbench × 4 組(繞回、飽和 × FC $n_{col}=4$、$n_{col}=1$ 逼出反壓) ALL PASS，反向測試四項都抓到。
    - 答案檔(約 37 MB 兩個)不進 git，跑模擬前先跑 `scripts/net/gen_salt_conv_fc_net_ref.py`。
    - 測到、沒測到的極端情況整理在「Part 11 → 極端情況」(2026-11-11 使用者問)。
- 整條網路層級的補測(人工參數逼出繞回、其他管線設定)：使用者決定先不補(2026-11-14)。
- SaltFC Part 10(conv → FC 轉接模組)完成，使用者確認(2026-11-11)，細節見下面「Part 10」。
    - `fc/ConvToFCAdapter`：conv 輸出存一級事件暫存器，下一拍換成 $\text{src}$；給 conv 的 ready 是「暫存器空的，或下游這拍收」。跟純組合邏輯版量過，只做暫存器版。
    - 單獨模擬兩支各 7 組 ALL PASS，反向測試三項都抓到；4.8 ns 布局繞線(conv2 → 轉接模組 → SaltFC)繞回 +0.333、飽和 +0.379。
    - 只單獨測過轉接模組，接上 conv2、SaltFC 跑資料在 Part 11。
- SaltFC Part 9(膜電位輸出)完成，使用者確認(2026-11-08)，細節見下面「Part 9」。
    - SaltFC 膜電位輸出只有 valid(`membrane_ready` 拿掉)，寫回那一拍存一級輸出暫存器、下一拍送；`stall` 不動。
    - 層外的 `fc/FCMembraneRegister`：存每顆最新值，收到最後一列的下一拍拉 `update_done`、送 `update_time`。
    - 整層模擬 72 + 203 組、FCMembraneRegister 32 組 ALL PASS；反向測試四項都抓到；4.8 ns 布局繞線繞回 +0.760、飽和 +0.622。
    - 答案檔加 update 行(每筆事件之後全部神經元的 V̂)，用訓練端 `FCLayer.forward(trace=True)` 的 `v_steps` 跟逐筆迴圈互相比對；訓練端在 `per-layer-quant` 的 `7a6a863`，只讀不改。
- conv1 → conv2 → 轉接模組 → FC → FCMembraneRegister 整條跟訓練端比對還沒做，使用者決定(2026-11-08)等 Part 10 做完、到 Part 11 再測，見下面「Part 11」。
- SaltFC Part 8(pipeline 整合)完成，使用者確認(2026-11-05)，細節見下面「Part 8」。
    - 步驟 1~5:不 fire(`SPIKE_OUTPUT = 0`)整層模擬 63 組 ALL PASS。
    - 步驟 6:fire 的送出、停住，四支 `out_ready` testbench 196 組 ALL PASS、反向測試三項都抓到。
    - 門檻讀法維持做法 C(比 $\hat V$ 晚一拍讀);跟 A 的合成比較寫在 FC.md 第 2 節「門檻」。選 A 多的 FF 是 $(C-1)\cdot n_{col}\cdot w$(上限，ROM 內容化簡後會更少)。
- 訓練端 2026-11-04 `per-layer-quant` 分支改了 API(`round_mode` 搬進每層 `QuantizedLayerParams`，`QuantBackend()` 不帶參數，`load_quantized` 回傳沒有 `round_mode`)：`gen_salt_conv_ref.py`、`gen_salt_fc_ref.py` 跟著改，重產的 conv 30 個、FC 不 fire 27 個答案檔跟 HEAD 逐 byte 相同。
- 輸出層 per-tensor(訓練端實驗 E,pc/pc/pt,繞回版)給 FPGA:匯出在 `sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1_out-pt/`(`cdc6315`,$n_{col}=4$),conv1、conv2 的 6 個檔跟 per-channel 版相同，只有 `out_weight.mem` 不同。
    - 測試用哪個量化資料夾只寫在 `SaltNET/scripts/quant_versions.txt`(`wrap`、`saturate` 兩行),答案腳本(`scripts/quant_versions.py`)跟 `run_tb_*.tcl`、`synth_salt_conv_net.tcl`(`scripts/quant_versions.tcl`)都讀它；換權重只改這個檔。原本 9 支腳本各自寫死。
    - `wrap` 設成這個資料夾：FC 的訓練端參數組換成 per-tensor 的權重(重產後只有繞回版那 6 個檔變了，`tb_fc_weight_lookup` 6 組、`tb_salt_fc_no_spike` 63 組 ALL PASS);$n_{col}=4$ 時腳本寫的權重檔、衰減表檔要跟匯出的 `out_*.mem` 相同。conv 的資料一樣，conv、lib、net 的答案重產跟 HEAD 逐 byte 相同，`run_tb_weight_lookup` 9 組、`run_tb_neuron_update` 48 組、`tb_salt_conv_ready_high` 訓練端 4 組、`tb_salt_conv_net_ready_high` 2 組 ALL PASS。
    - `saturate` 還沒有 per-tensor 的匯出，維持 per-channel(`..._saturate_iv9-11-11`)。
- SaltFC Part 0~3 完成。
- SaltFC Part 4 完成：4a conv 權重 ROM 改用 `lib/ReadOnlyMemory`；4b 權重位址兩層共用 `lib/WeightMemory`(細節見下面「Part 4 權重 BRAM」)。
- SaltFC Part 5 完成(細節見下面「Part 5」)：conv 展開 `WeightTapSelect`、`NeuronMemory` 搬到 lib、FC $\hat V$ 跟門檻的 testbench。
- SaltFC Part 6 完成(細節見下面「Part 6」)：`NeuronUpdate` 拆成 `lib/DecayLookup` + `lib/NeuronUpdate`，加 `SPIKE_OUTPUT`；FC 的兩個時間暫存器改放 Part 8。
- SaltFC Part 7 完成(細節見下面「Part 7」)：FC 挑選模組 `fc/FCSpikeSelect`，conv 的改名 `ConvSpikeSelect`;bitmask、送出交握放 Part 8。
- 2026-10-29 盤點「答案用訓練端 salt_core 的函式產生」這條規則：訓練端有對應函式卻沒用的只有 `tb_spike_select` 的送出順序，已改(見下面「Part 7」最後)。bank 排列、記憶體讀寫清除、FIFO、拍數、寬字切段這些訓練端沒有對應函式，使用者決定不處理。
- 分支 `test`，比 `origin/test` 多 8 個 commit(`cdc6315` 起，最新是 Part 11)還沒 push：agent 這邊 push 時 Git Credential Manager 存不了認證(`wincredman`)，要使用者在自己的終端機 `git push origin test`。`origin/main` 停在 `5507967`。
- 訓練端(2026-11-09 確認)：重構改在新專案 `D:\Project\Spiking-Affine-Lazy-Training-refactor` 從頭寫，目前只有 `CLAUDE.md`、`docs/`，還沒有程式碼。答案腳本(`gen_salt_conv_ref.py`、`gen_salt_fc_ref.py` 等)照舊 import 原本的 `D:\Project\Spiking-Affine-Lazy-Training`(`per-layer-quant` 的 `7a6a863`)，只讀不改；之後要換到新專案，等使用者說再改，換了要重產答案、跟 HEAD 比。
- 這幾次定下來、之後的 Part 照著做的：
    - 模組分法(Part 5「已定」)：有邏輯才包模組，兩層相同的放 lib；打包、切段寫在各層 top 的 generate 區塊。conv、FC 結構要對稱，提案前先用這條檢查兩層是不是一樣。
    - 驗證範圍(「作法 → 驗證」)：搬位置、改名、展開這類行為不變的整理只做合成比對 + 改到的 testbench + 一支整層 testbench 的部分參數組。
    - 跟使用者討論時一次只講一個決定：先列兩層現況對照，再給選項表跟建議。
    - 只討論使用者要討論的事：TODO 延後表(D 編號)、程式裡的 reviewer 註解，使用者沒叫就不要自己拿出來處理。
    - 講人話：講路徑、訊號時說它實際在做什麼(例：「conv2 的 `in_ready` 反壓 conv1」)，不要直接搬腳本、報告裡的標籤；testbench 細節使用者不在意，不用主動展開。
    - 提量測時先想清楚目的再挑條件：要確認時序有沒有變差，就往更緊的目標週期跑(逼布局找好的)，不要排比現在還鬆的週期。
    - 使用者說「直接做完」時，設計決定都已經定好的話就整個 Part 做完再回報，不用一步一步問。
    - `SaltNET.xpr` 有改動就跟著 commit，不還原、不拿出來討論(見「作法 → 驗證」)。
    - 答案一律用訓練端 salt_core 的函式產生，testbench 拿來比對；訓練端有對應函式就要叫，不在腳本、testbench 裡自己重寫一份。只有硬體才有的東西(bank 排列、記憶體、FIFO、拍數、寬字切段)沒有對應函式，才自己算(2026-10-29)。
    - 命名有一個明顯改動少、又符合既有命名習慣的選項時，直接提名字跟一句理由，不列選項表。
    - 使用者說「用訓練端匯出的那組 .mem 測」:先看 `sources_1/mem/` 有沒有已經匯出(commit)的資料夾，改 `scripts/quant_versions.txt` 指過去重產答案、重跑，不要另外提方案、問範圍(2026-11-05)。
    - 使用者問「跟什麼成倍率」是要公式(例：多的 FF $=(C-1)\cdot n_{col}\cdot w$)，直接給公式跟無關的參數，不要講實測數字的來龍去脈(2026-11-05)。
- 留著沒查的：Part 5 第 1 步(選 tap 展開)合成後 LUT 少 42，原因沒查出來；功能、4.8 ns 都確認過。
- 這次碰到的工具問題：
    - 這台 git 設 `core.autocrlf=true`，有些答案檔在工作目錄是 CRLF(反向測試 `git checkout` 還原時轉的)。比對重產的答案檔要跟 `git show HEAD:<路徑>` 比，不要跟工作目錄的檔案直接比。
    - 從 Git Bash 呼叫 `wsl` 時，`/mnt/c/...` 會被 MSYS 轉成 Windows 路徑，要加 `MSYS_NO_PATHCONV=1`。
    - agent 的 Bash 工具用 heredoc 餵 Python 時，`\\` 會被吃掉一個；含反斜線的替換腳本改用檔案寫。
    - `wsl bash -lc "..."` 裡的 `\$變數` 到 WSL 那邊是空的；有迴圈、變數的指令寫成 `.sh` 檔再 `wsl bash <檔案>`。
    - 訓練端在 WSL 跑匯出、測試時 GPU 可能被別的程式佔滿(JAX 會印一串 `CUDA_ERROR_OUT_OF_MEMORY`)；這些都不用 GPU，加 `JAX_PLATFORMS=cpu`。直接跑 `.py` 要加 `PYTHONPATH=.`,`python -m` 不用。
    - `run_tb_neuron_memory.tcl` 9 組 ALL PASS 之後，印結果的 `puts` 報 `can not find channel named "stdout"`，exit 1；同一個 `puts` 在其他腳本都正常，原因查不到。`run_tb_salt_conv.tcl` 的 `ready_alternate` 第 3 組也碰到類似的事：模擬跑完，讀 `simulate.log` 的 `open` 失敗、錯誤訊息是空的。兩支單獨重跑都 ALL PASS，當偶發處理。2026-10-27 `run_tb_fc_weight_lookup.tcl`、`run_tb_weight_lookup.tcl`，2026-10-28 `run_tb_spike_select.tcl` 各碰到一次 `stdout` 那個(各組的總結行都是 ALL PASS，只有最後印總表的 `puts` 失敗)；網路上查不到 Vivado 的說明。
    - `perl -CSD -pi -e 's/中文.../'` 對含中文的樣式比對不到(輸入照 UTF-8 解成字元，樣式本身沒解)，替換照樣成功結束、什麼都沒改；含中文的替換用 Python 寫，`assert` 舊字串出現次數。
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
| 7 | spike 選擇：`fc/FCSpikeSelect`、conv 的改名 `ConvSpikeSelect`;bitmask、送出交握放 Part 8 | 第 4 節 ②③ | 完成 |
| 8 | pipeline 整合 | 第 5 節 | 完成 |
| 9 | 膜電位輸出：SaltFC 送出、層外暫存器模組 `fc/FCMembraneRegister` | 第 6 節 | 完成 |
| 10 | conv → FC 轉接模組 `fc/ConvToFCAdapter`(暫存器版) | 第 1 節 | 完成 |
| 11 | 串接 conv1 → conv2 → 轉接模組 → FC → 膜電位暫存器(`net/SaltConvFCNet`)，每一層每一次更新跟訓練端比對 | — | 完成 |
| 12 | 合成量測(4.8 ns)：實際網路、極限測試(BRAM 約 84 顆) | — | 進行中 |

- 每個 Part 的細節到要做時才規劃。

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
    - 膜電位輸出埠：`membrane_valid`、`membrane_ready`、`membrane_row_base`($y\cdot n_{col}$)、`membrane_values`($n_{col}\cdot w$)、`membrane_time`(FC.md 第 6 節 ③)。2026-11-07 改定不握手，`membrane_ready` 在 Part 9 拿掉。
- 驗證(2026-10-25)：本體是空的，只確認能 elaborate、port 位寬對。non-project `synth_design -rtl`(不碰 `.xpr`)，逐 port 數位元數：

| 參數 | `in_neuron` | `out_neuron`、`membrane_row_base` | `membrane_values` |
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
        - 輸出「還有沒有剩」決定整條管線停不停、讀不讀下一列，是 Part 8 的推進規則；FC 還要併 Part 9 膜電位輸出沒被收走的條件(2026-11-07 改定膜電位輸出不握手，不用併，見「Part 9」)。
        - 不選「收成 lib 模組兩層共用」：挑選模組夾在中間，port 要繞一圈(吐出要挑的 → 各層挑選模組 → 收回挑到哪顆)，而且 conv 這段在停住的路徑上，改了要重量。
    - `FCSpikeSelect` 直接輸出 $i=y\cdot n_{col}+x$(輸入這一列帶的 $y\cdot n_{col}$)，跟 `ConvSpikeSelect` 直接輸出 $o_y$、$o_x$ 對稱，兩層 top 都只接線；$n_{col}$ 是 2 的次方就把 $x$ 接進低位，其他用加法，兩條分支都在 Part 7 的 testbench 測到。
- 做法(2026-10-28)：
    - 第 1 步 conv 改名：`git mv conv/SpikeSelect.sv conv/ConvSpikeSelect.sv`，module 名、SaltConv 與 `tb_spike_select` 的例化、`CandidateAxis`/`CandidateGrid`/SaltConv 註解、`gen_candidate_axis_ref.py`/`gen_spike_select_ref.py` 說明、`SaltConvOverview.md`、`SaltConvControl.md`、`SaltConvDataflow.md`、`SaltConvSynthFlow.md`、架構總覽 drawio(命令列重新匯出 svg)跟著改；`.xpr` 用 batch `remove_files` 拿掉舊路徑。
    - 第 2 步 `fc/FCSpikeSelect.sv`：參數 `OUT_NEURONS`、`NEURONS_PER_ROW`；輸入 `pending`($n_{col}$ 位元)、`row_base`($y\cdot n_{col}$)，輸出 `found`、`selected`(one-hot)、`selected_neuron`($i$)。generate 三支：2 的次方而且 $i$ 位寬比 $x$ 寬(接位元)、2 的次方只有一列($i$ 就是 $x$)、其他(加法，含 $n_{col}=1$)。
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
- 2026-10-29 補：`scripts/conv/gen_spike_select_ref.py` 的送出順序原本是腳本自己照 $o_y\cdot W+o_x$ 排，改成呼叫訓練端 `salt_core.stream.extract_output_events_conv`(只開 1 個 $o_c$,每批 256 個 case 當不同輸入事件一次算),編號用 `salt_core.connectivity.conv.unravel_conv_source` 換回座標。重新產生的 8 個答案檔跟原本逐 byte 相同，所以 testbench 沒重跑。

### Part 8 pipeline 整合

- 已定(2026-10-29)：
    - 直接寫最終的管線($R$、$C$、`OVERLAP` 參數、讀寫衝突)，不像 SaltConv 從無腦版一步一步做：conv 那樣做是因為每一步都要量划不划算，這些 conv 已經量過，FC.md 第 5 節照 conv 的結論寫。
    - 照 SaltFC 的段落分步驟寫，每一步寫完給使用者看內容跟設計想法，確認才進下一步；先做不 fire，再加 fire。
    - SaltFC 段號是 0~5：SaltConv 的第 3 段(下一個 $o_c$ 碰到哪些神經元)FC 沒有，管線位置起比 SaltConv 少一。
- 步驟：

| 步驟 | 段 | 內容 | 狀態 |
|---|---|---|---|
| 1 | 0、1 | 共用控制宣告；清除、輸入 FIFO、事件暫存器 $\text{src}$、兩個時間暫存器 | 做完 |
| 2 | 2 | 列計數 $y$、$y\cdot n_{col}$ 累加、下一列從 FIFO 還是事件暫存器拿、BRAM 讀取 enable | 做完 |
| 3 | 3 | 管線位置 1..L 帶 $y$、$y\cdot n_{col}$、$t$、$t_{last}$、valid；算的那一拍 | 做完 |
| 4 | 4 | 三顆記憶體、1 份 `DecayLookup`、每行的 generate 區塊(切段、`NeuronUpdate`、最後一列空位置的遮罩) | 做完 |
| 5 | 5(不 fire) | 不重疊時等前一列、讀寫衝突、`read_next_row`；`SPIKE_OUTPUT = 0` 那一支停住固定 0；整層模擬比最後的 $\hat V$ | 做完 |
| 6 | 5(fire) | bitmask、`FCSpikeSelect`、送出交握、停住；整層模擬再加比 spike 輸出 | 做完 |

- 已定(2026-10-29)門檻兩種並存：SaltFC 加參數選「每顆一個門檻」(per-channel，門檻 BRAM)或「整層一個門檻」(per-tensor，編譯期常數，不用 BRAM、沒有讀取延遲要對齊)，在步驟 4 一起做。
    - 起因：訓練端中間層固定 per-channel，FC 的 channel 就是輸出神經元，每顆的步長 $s_i$ 不同，整數門檻 $\hat v_{th}[i]=\operatorname{round}(v_{th}/s_i\cdot2^{f_V})$ 每顆不同；per-tensor 整層一個 $s$，整數門檻只有一個(浮點 $v_{th}$ 每層一個純量)。`LayerQuantSpec.per_channel` 本來就逐層，只有 `example/quant_run.py` 的 `quant_layer_specs`、config 只開放輸出層選。
    - SaltConv 也要對稱(門檻陣列大小 1 或 $OC$)，FC 做完再處理，見 D12。
    - 參數名 `SHARED_THRESHOLD`(1：整層一個)，放在量化行為那組；conv、FC 同名。
    - 整層一個時門檻檔先自己假設(訓練端還沒改)：只有一行，$w$ 位元二補數，$\lceil w/4\rceil$ 個 hex 字元，跟 conv 門檻檔一行的格式相同；SaltFC 讀進大小 1 的陣列，複製 $n_{col}$ 份接到每一行。
- 已定(2026-10-29)每顆一個門檻時門檻 BRAM 的讀法(做法 C)：門檻在計算第 2 級(位置 L)才比，$C=2$ 時比 $\hat V$ 晚一拍讀，位址用 `pipe_row[1]`、讀取開關 `pipe_valid[1] && !stall`，讀取延遲照 $R$；$C=1$ 時跟 $\hat V$ 同一拍讀。
    - 比過的：A 跟 $\hat V$ 同一拍讀、讀取延遲設 $L$(多一級讀出暫存器，$R=2$ 時多 $n_{col}\cdot w$ 個 FF)；B 讀取延遲 $R$、SaltFC 另寫一級暫存器(FF 同 A，多一段要對齊停住)。三個都不影響管線延遲；選 C 是因為不多暫存器，代價只有門檻 BRAM 的讀位址、開關跟另外兩顆不同。
    - 步驟 6 做完後 A、C 各合成一次($R=2,C=2$，4.8 ns 布局繞線，2026-11-05)：WNS 繞回 C +0.368、A +0.502，飽和 C +0.453、A +0.473(最長路徑都不經過門檻，差在單次布局的變動範圍內);合成後 LUT 幾乎相同、A 多 8 個 FF(多的那一級只留 8 位元，門檻 BRAM 合成後也只接 8 根輸出腳，跟門檻內容、列數有關，上限 $n_{col}ot w$);C 不比 A 差，不換。數字跟比較方式寫在 FC.md 第 2 節「門檻」。
- 已定(2026-11-04)FC 留不重疊模式(`OVERLAP = 0`)，照 SaltConv 兩種並存，第 5 段 `wait_previous_row` 保留。
- ~~Part 9 要回來改的：第 5 段 `no_spike_output` 那一支 `stall` 固定 0，只到 Part 9 為止；膜電位輸出沒被收走也要停住，`stall` 要拿出來併兩個輸出的條件。~~ 2026-11-07 改定膜電位輸出不握手，`stall` 不用改，見「Part 9」。
- 已定(2026-10-29)步驟 4 的另外兩個設計：
    - 最後一列空位置的遮罩 `column_valid[x]`：前 `LAST_ROW_COLUMNS` 行是常數 1，後面的行是 `pipe_row[L]` 不是最後一列；跟 FC.md 的 $y\cdot n_{col}+x<n_{out}$ 等價，各行共用一個比較，整除時沒有邏輯。跟 `spike` 做 AND 放在第 5 段挑 fire 的地方(同 conv 的 `pipe_candidate_valid`)。
    - $\hat V$ 整列寫回，空位置算出來的值照寫，不另外寫 0：行跟行獨立，碰不到真的神經元；膜電位輸出照 FC.md 第 6 節空位置沒有意義。整層 testbench 只比 $n_{out}$ 顆。
- 已定(2026-10-29)第 5 段不重疊等前一列(`wait_previous_row`)、讀寫衝突(`read_conflict`)維持分開、只比第 0 列，不改成通用寫法：通用規則跟為什麼不照它寫，記在 FC.md 第 5 節 ⑦⑧。
- 已定(2026-10-29)步驟 5 整層模擬(`SPIKE_OUTPUT = 0`)：
    - 答案照 SaltConv：訓練端 `FCLayer.forward` + `QuantBackend`(官方)跟逐筆迴圈(`apply_decay_table_int` + `process_event`)互相比對；官方 `v_final` 有 catch-up，逐筆迴圈補上同一步對上後，testbench 比 catch-up 之前的 $\hat V$。
    - 訓練端 out 層：繞回($w=14$)、飽和($w=11$)× $n_{col}=4$、$10$($n_{row}=3$、$1$)，輸入是 test 前 10 筆經訓練端 conv1 → conv2 的輸出，換成 $\text{src}=o_c\cdot H_{out}W_{out}+o_y\cdot W_{out}+o_x$。
    - 人工參數 $(n_{in},n_{out},n_{col})$：(7,10,3)、(7,10,4)、(5,3,4)、(7,5,1)、(1,1,1)；量化行為變化 `ROUND`、`SATURATE`、小 $w$、一組 $f_V>0$；事件時間含第一筆 $t=0$、同一毫秒、間隔超過 $\Delta t_{\max}$。
    - 每組跑 7 種 $(R,C,\text{OVERLAP})$：$(1,1)$ 加 $(1,2)$、$(2,1)$、$(2,2)$ 各配重疊、不重疊。
    - 比：$n_{out}$ 顆最後的 $\hat V$(階層路徑讀 BRAM)、最後的 `event_time`、輸入一直有時的拍數。
- 步驟 5 做法(2026-10-29)：
    - `scripts/fc/gen_salt_fc_ref.py`：拍數、檔名常數、`signed_range`、`write_lines` import `scripts/conv/gen_salt_conv_ref.py`(拍數算法跟 conv 相同，$o_c$ 換成列)；權重檔、衰減表檔用訓練端 `fc_weight_lines`、`decay_lines` 寫，跟答案一起放 `sim_1/new/fc/ref/`；印出每組碰到暫存器範圍的次數(out 層繞回 0、飽和 2865，人工 2~158)。
    - `sim_1/new/fc/tb_salt_fc_no_spike.sv`：單一 `initial`，上游一直有事件；樣本結束比 $n_{out}$ 顆 $\hat V$、`event_time`、拍數；每拍比讀出的 $\hat V$、權重寬字等於記憶體內容(讀到還沒寫回的舊值當拍抓到)。沒有涵蓋統計。
    - `scripts/fc/run_tb_salt_fc_no_spike.tcl`：9 組 × 7 種 $(R,C,\text{OVERLAP})$ = 63 組。
- 步驟 5 驗證(2026-10-29)：
    - 63 組 ALL PASS。
    - 反向測試一：讀寫衝突永遠不擋。$n_{row}=1$ 的三組 7 種設定全部 FAIL；$n_{row}=3$ 的兩組只有 $R=2,C=2$ 重疊($L=3$)FAIL；$n_{row}=4$、$5$ 全部 PASS。跟 FC.md 第 5 節 ⑧ 的表一致。
    - 反向測試二：`DecayLookup` 改接時間暫存器(不用位置 R 帶的 $t$、$t_{last}$)。只有 $R=2$ 重疊的組 FAIL($n_{row}=1$ 跟 $R=2,C=2$ 重疊的 $n_{row}=3$ 被讀寫衝突隔開，換事件時舊事件的列已經過了位置 R，PASS)。
    - 兩次都還原，跟改之前逐 byte 相同。第一次跑反向測試一時第 3 組 elaborate 碰到 `Spawn failed: %1 不是有效的 Win32 應用程式`(vivado-usage skill 8.7)，原封不動重跑就過。
- 步驟 6(2026-11-04)RTL：第 5 段 `spike_output` 那一支照 SaltConv 第 6 段，`pending`(算的那一拍是 `spike && column_valid`，之後是 bitmask)→ `FCSpikeSelect` → 送出交握 → `pending_left` 存回 bitmask;`stall` 只看個數(`pending_any`、`pending_multiple`)。
    - 驗證到哪：non-project `synth_design -rtl` 8 組(訓練端形狀 $n_{col}=4$ 每顆一個、整層一個門檻各配 $(R,C,\text{OVERLAP})$=(1,1,0)、(2,2,1);$n_{col}=3$ 兩種門檻;$n_{out}=n_{col}=1$;`SPIKE_OUTPUT = 0`)、`-lint` 2 組都過，沒有新的 lint 訊息(膜電位輸出埠沒驅動是 Part 9)。門檻檔是只給 elaborate 讀的暫存檔。
    - `SPIKE_OUTPUT = 0` 那一支沒改，`tb_salt_fc_no_spike` 沒重跑。
- 步驟 6(2026-11-04)答案跟 testbench:
    - `gen_salt_fc_ref.py` 加 7 組會 fire 的人工參數組(排在 `SYNTHETIC_SETS` 最後，不 fire 那幾組抽到的亂數不變)：每顆一個門檻 4 組、整層一個 3 組，涵蓋 $n_{col}$=1、3、4、8(2 的次方接位元)、$n_{row}$=1、最後一列不滿、$f_V>0$、truncate、飽和。門檻大多壓低，最後一列權重取絕對值、用低門檻(換事件那一拍被擋才碰得到);$n_{row}=1$ 照 conv OC = 1 的做法累積幾筆才 fire。檔名多 `_SH<0|1>`，門檻檔用訓練端 `fc_threshold_lines` / `threshold_lines` + `layer_threshold` 寫；答案檔第一行 coverage 同 conv(`stall_last_of_oc` 換成 `stall_last_of_row`)。
    - `tb_salt_fc_common.svh` + `tb_salt_fc_ready_{high,random,burst,alternate}.sv`，照 conv 四支；FC 另外比 `event_time`、每顆一個門檻時算的那一拍門檻讀出值等於門檻 ROM。`scripts/fc/run_tb_salt_fc.tcl` 7 組 × 7 種 $(R,C,\text{OVERLAP})$。
    - 驗證：四支各 49 組 ALL PASS，要求的涵蓋項目都碰到。
    - 反向測試(`tb_salt_fc_ready_random` 的 $n_{out}=10$ 兩組 × 7 種，各 14 組;做完還原，跟改之前逐 byte 相同)：
        - `compute_cycle` 不看 `pipe_held`(停住的拍子再寫回一次):14 組全部 FAIL。
        - `pending_left` 不看 `spike_sent`(沒送成也清掉):14 組全部 FAIL。
        - BRAM 輸出暫存器停住時照樣推進(`read_shift_enable = 1`):只有 $R=2,C=2$ 重疊的 2 組 FAIL。$C=1$ 時停住的列已經算完、用不到；不重疊時後面沒有列，推進來的還是同一列；只有重疊 + $C=2$ 時位置 R 那一列正在算第 1 級，資料被換掉。
- 工具問題(2026-11-04):試跑 `run_tb_salt_fc.tcl` 單組時，總表 `puts` 的 `can not find channel named "stdout"` 連續 2 次(輸出導到 `/dev/null`、導到檔案都一樣);之後四支完整跑(輸出導到 `/dev/null`)都正常。Vivado 的 xsim Tcl 原始碼沒有碰 `stdout`，原因還是查不到。每組的總結行在 Vivado log 裡，出事時從 log 數。
- 步驟 1~4 只確認 elaborate(non-project `synth_design -rtl`，不碰 `.xpr`)：控制訊號到步驟 5 才驅動，模擬沒有意義。整層的答案腳本、testbench 到步驟 5 前再討論。
- 步驟 1(2026-10-29)：`event_time`、`event_last_time` 換事件時一起往後推一格，要 reset：conv 的 $t_{last}$ 存在神經元記憶體裡跟著清除歸 0，FC 的存在暫存器。
- 步驟 2(2026-10-29)：`last_read_row`、`last_read_row_base` 一起更新；下一列是新事件時 $t_{last}$ 取 `event_time`(時間暫存器這拍結束才推進)。
- 命名(2026-10-29)：
    - $y\cdot n_{col}$ 叫 `row_base`(`start` 範圍太廣)：SaltFC 的 `last_read_row_base`、`read_row_base`，port `membrane_row_base`，`FCSpikeSelect` 的輸入 `row_base`。
    - SaltFC 內部的 $\text{src}$ 叫 `src`(`fifo_src`、`event_src`、`read_src`)，`neuron` 只指這一層的神經元；port `in_neuron` 不改(Part 2)。`tb_fc_weight_lookup` 的 `read_neuron` 也改成 `read_src`。
    - 驗證：`tb_fc_spike_select` 答案重產跟 HEAD 逐 byte 相同、8 組 ALL PASS；`tb_fc_weight_lookup` 6 組 ALL PASS；SaltFC 四組參數 elaborate。

### Part 9 膜電位輸出

- 已定(2026-11-07)，設計寫在 FC.md 第 6 節 ②~⑦：
    - 膜電位輸出只有 valid，沒有 ready；SaltFC 不因膜電位輸出停住，`stall` 維持只看 spike 輸出，`no_spike_output` 那一支固定 0 不改。
        - 起因：收的一端只存最新值，一拍寫得完一列，SaltFC 一拍最多送一列，ready 永遠是 1；訓練端讀 $\hat V$ 的解碼方式(膜電位回歸)只用最後的值。
        - 代價：後面的模組每一拍都要收得下，收不下由它自己丟。
    - 送出時機：剛到位置 $L$、寫回那一拍(`compute_cycle`)，存一級輸出暫存器，下一拍送；不停住，每拍照樣更新。
    - 每顆最新值的暫存器放在 SaltFC 外面(層外的膜電位暫存器模組)：中間層 FC 不用多 $n_{out}\cdot w$ 個 FF；要每一筆的直接接 SaltFC 的膜電位輸出。
        - 寫入：收到一筆就寫 $y\cdot n_{col}$ 起的 $n_{col}$ 格，最後一列空的位置不寫；reset 歸 0。
        - 「一筆更新完」：收到最後一列($y\cdot n_{col}=(n_{row}-1)\cdot n_{col}$)寫完的下一拍送一拍脈衝，跟這筆事件的 $t$ 一起送；只有那一拍保證 $n_{out}$ 格是同一筆事件的值，要慢慢用的在那一拍複製。
        - Part 11 跟訓練端比對時要用這個脈衝那一拍的值。
    - 不用 AXI：SaltFC、暫存器模組都是 PL 內部連線。接 PS 時在暫存器模組後面另放 AXI4-Stream 轉接(FC.md 第 6 節 ⑦)：閒著時收到「一筆更新完」才整筆複製、送的時候不收，valid 維持到握手；字寬、打包做 PS 端時再定。
- 範圍(使用者確認 2026-11-07)：SaltFC 的膜電位輸出 + 暫存器模組；AXI 轉接延後到接 PS 時。
- 計畫(使用者確認 2026-11-07)：4.8 ns 布局繞線在 Part 9 量；訓練端答案檔也加 update 行(4 個檔合計多約 2.8 MB)。
- RTL(2026-11-07)：
    - `SaltFC`：拿掉 `membrane_ready`；第 5 段開頭加 `MEMBRANE_OUTPUT` 分支。`membrane_valid` 每拍等於上一拍的 `compute_cycle`(要 reset)；`membrane_row_base`、`membrane_values`、`membrane_time` 只在 `compute_cycle` 那拍存 `pipe_row_base[L]`、`new_membrane_word`、`pipe_time[L]`，其他拍保持(少翻轉，FC.md 第 6 節 ⑤)。`MEMBRANE_OUTPUT = 0` 時四個輸出固定 0。
    - `fc/FCMembraneRegister`(新)：參數 `OUT_NEURONS`、`NEURONS_PER_ROW`、`MEMBRANE_WIDTH`、`TIME_WIDTH`；輸入四個埠跟 SaltFC 的 `membrane_*` 同名；輸出 `membranes`($n_{out}\cdot w$)、`update_done`、`update_time`。每列一個比較器(`row_selected[y]`)，每顆一格；`update_done` 是收到最後一列的下一拍。名字用 FC 前綴：照列寫入是 FC 專用，跟 `FCSpikeSelect` 一樣。
    - elaborate(non-project `synth_design -rtl`)：SaltFC 8 組(訓練端形狀 SPK0 的 R1C1、R2C2 重疊各配膜電位開關；人工 $n_{col}$=3、4、8、1 會 fire 的組)、FCMembraneRegister 6 組都過；`-lint` SaltFC 2 組、FCMembraneRegister 1 組沒有新的訊息，`Synth 8-3848` 消失。
- 答案(2026-11-07)：`gen_salt_fc_ref.py` 每筆事件記下處理完之後全部 $n_{out}$ 顆的 $\hat V$，答案檔在 `out` 行之後加 `update <t> <V̂_0> … <V̂_{n_out-1}>`，每筆輸入事件一行。
    - 官方改成 `FCLayer.forward(..., trace=True)`：`trace.v_steps` 是每一步寫回之後的暫存器值(fire 的已經歸 0)，整數掃描一步一筆事件，前 $n_{real}$ 欄要跟逐筆迴圈(`process_event`)逐筆、逐顆相同才寫檔；16 組都一致。
    - 重產的 16 個答案檔拿掉 update 行跟 HEAD 逐 byte 相同，權重、門檻、衰減表檔不變(55 個檔)。
    - 訓練端在 `per-layer-quant` 的 `7a6a863`，只 import 不改；跑的時候加 `PYTHONDONTWRITEBYTECODE=1`，跑完訓練端 `git status` 不變。
- testbench(2026-11-07)：
    - `tb_salt_fc_update_lines.svh`(新)：讀 update 行，三支 testbench 共用。
    - `tb_salt_fc_membrane_check.svh`(新)：`tb_salt_fc_no_spike`、`tb_salt_fc_common.svh` 共用的膜電位輸出檢查。照「事件、列」的順序逐筆比 `membrane_row_base`、這一列真的神經元的值、`membrane_time`；樣本結束時筆數要是 $\text{in\_count}\cdot n_{row}$，`MEMBRANE_OUTPUT = 0` 時是 0。停住的拍子多送、少送一列，整串會錯開。
    - 兩支整層 testbench 加參數 `MEMBRANE_OUTPUT`(預設 1)，總結行多 `MEMBRANE_OUTPUT=`、`membrane_check_count`；樣本結束的條件多等 `membrane_valid` 變 0(輸出暫存器晚 1 拍)。
    - `tb_fc_membrane_register_common.svh` + `_back_to_back.sv`(每拍一列，最快的情況)、`_gap.sv`(每列之前一半機率空 1~3 拍)：單獨測 FCMembraneRegister，列的值取 update 行，空位置、valid=0 的拍子送亂數；每拍比每一格等於 testbench 記的值(收到第 $y$ 列就蓋那 $n_{col}$ 格)，`update_done` 只在最後一列的下一拍、`update_time` 是那筆事件的 $t$，`update_done` 次數等於事件數。
    - `sim_common.tcl` 的 `create_simset_if_missing`：模擬集已經存在時，把清單裡還沒加進去的檔補進去(新加的 `.svh`)。
    - `scripts/fc/run_tb_fc_membrane_register.tcl`(新)：兩支各 16 組(全部 SaltFC 答案檔)。
- 驗證(2026-11-07)：
    - `tb_salt_fc_no_spike` 72 組 ALL PASS：63 組 `MEMBRANE_OUTPUT = 1`(訓練端繞回組 35943 筆 = 11981 筆事件 × 3 列)，加 9 組 $(2,2,1)$ `MEMBRANE_OUTPUT = 0`(`membrane_check_count=0`，其他照舊)。
    - 四支 `tb_salt_fc_ready_*` 203 組 ALL PASS，要求的涵蓋項目都碰到：各 49 組 `MEMBRANE_OUTPUT = 1`，`ready_random` 多 7 組 $(2,2,1)$ `MEMBRANE_OUTPUT = 0`。
    - `tb_fc_membrane_register_back_to_back`、`_gap` 各 16 組 ALL PASS。
    - 反向測試(做完還原，跟改之前逐 byte 相同)：
        - SaltFC `membrane_valid` 改接 `pipe_valid[L]`(停住的拍子也送)：`ready_random` 49 組全部 FAIL。不 fire 的組 `stall` 固定 0，`pipe_valid[L]` 跟 `compute_cycle` 是同一個訊號，沒跑。
        - SaltFC 值不過暫存器(valid 有過，差一拍)：`ready_random` $(2,2,1)$ 7 組全部 FAIL。
        - FCMembraneRegister `update_done` 跟最後一列同一拍拉(暫存器還沒寫進去)：`back_to_back` 16 組全部 FAIL。
        - FCMembraneRegister 每次寫入都拉 `update_done`：$n_{row}>1$ 的 9 組 FAIL，$n_{row}=1$ 的 7 組照樣過。
- 量測(2026-11-07，訓練端輸出層形狀 1296 → 10、$n_{col}=4$、`SPIKE_OUTPUT = 0`、`MEMBRANE_OUTPUT = 1`、$R=2,C=2$ 重疊，4.8 ns 布局繞線，乘法 DSP 套 `DONT_TOUCH`，腳本在 session 暫存目錄)：

| 版本 | WNS | 最長路徑 | 進輸出暫存器最緊 | LUT(合成後) | FF(合成後) | BRAM | DSP |
|---|---|---|---|---|---|---|---|
| 繞回 | +0.760 | `pipe_time` → 衰減乘法 DSP | +3.463(DSP → `membrane_values`) | 256 | 252 | 4.5 | 4 |
| 飽和 | +0.622 | `pipe_time` → 衰減乘法 DSP | +2.580 | 276 | 240 | 4.5 | 4 |

- 量測說明：
    - LUT 是合成後 LUT 單元的個數；`report_utilization` 的 CLB LUTs(兩個 LUT 可以共用一個實體 LUT)是 223、227。
    - 輸出暫存器繞回 75 個 FF、飽和 63 個：$n_{col}\cdot w+\lceil\log_2 n_{out}\rceil+16+1$ 是 77、65，$n_{col}=4$ 時 $y\cdot n_{col}$ 低 2 位一定是 0，修剪掉 2 個。
    - `MEMBRANE_OUTPUT = 0` 那兩次沒有比較價值：spike 也關，整層沒有輸出，合成把電路修剪到剩 31 個 LUT、0 BRAM(飽和版那次 `opt_design` 前碰到空白的 `Synth 20-411`，vivado-usage skill 11 節的平行合成偶發錯誤，沒重跑)。所以加膜電位輸出之前這一層的 FF(約 177 = 252 − 75)是推算的。
    - 輸出暫存器不在最長路徑上，最長路徑跟 Part 8 繞回版同一類($t$、$t_{last}$ → 衰減乘法)。
    - FCMembraneRegister 單獨合成(out-of-context)：$w=14$ 是 157 FF、4 LUT，$w=11$ 是 127 FF；就是 $n_{out}\cdot w+16+1$。
- 工具問題(2026-11-07)：
    - testbench 變數取名 `cell`：是 SystemVerilog 保留字(config 用)，xvlog 報 `syntax error near 'cell'`，改名 `membrane`。
    - 反向測試一第一次跑，第 1 組模擬跑完讀 `simulate.log` 的 `open` 失敗、訊息空白(同 vivado-usage skill 8.7)，原封不動重跑就過。
    - agent 的 Bash 工具用 heredoc 餵 Python 時，`\` 照樣會被吃掉一個(之前記過)；連 `<<'EOF'` 也一樣，含反斜線、跨行字串的替換腳本改用 Write 寫檔再跑。

### Part 10 conv → FC 轉接模組

- 要解決的：conv2(`SaltConv`)送出 `out_channel`($o_c$)、`out_y`($o_y$)、`out_x`($o_x$)、`out_time`($t$)，SaltFC 收 `in_neuron`($\text{src}$)、`in_time`($t$)；轉接模組換成 $\text{src}=o_c\cdot H_{out}W_{out}+o_y\cdot W_{out}+o_x$，$t$ 原封不動。訓練端形狀 conv2 輸出 16 channel、$9\times9$，$n_{in}=1296$。
- 事件 queue 在哪(2026-11-09 跟使用者釐清)：queue 就是 `lib/EventFIFO`，每一層在自己的輸入端例化一份，不是放在兩層中間的獨立模組，也不分 conv 版、FC 版。三種連接都在寫進下一層的 queue 之前換好格式：conv → conv、FC → FC 直接接線，conv → FC 經過轉接模組。轉接模組放在 queue 前面，理由同 FC.md 第 1 節(換算接在 FIFO 讀出端會拉長讀位址那條路徑，而且 SaltFC 就要知道上一層是 conv)。
- 已定(2026-11-09，設計寫在 FC.md 第 1 節「$\text{src}$ 從哪裡來」)：
    - 名字 `ConvToFCAdapter`，放 `fc/`：輸出的 $\text{src}$ 是 FC 的輸入格式，同 `FCMembraneRegister`。之後 `EvtDecoder → conv1` 的轉接模組套同一條規則(放下游那一層的資料夾)就放 `conv/`，取名照同一個格式。
    - 參數只給 conv 的輸出形狀 `IN_CHANNELS`、`IN_ROWS`、`IN_COLS` 跟 `TIME_WIDTH`；座標位寬、`OUT_NEURONS`($n_{in}$)、`OUT_NEURON_WIDTH` 是 `localparam`，跟 SaltConv、SaltFC 同一套公式(數量大於 1 才取 $\lceil\log_2\rceil$，否則 1)。上層把同一組形狀傳給三個模組，位寬就對得上；代價是公式在三個模組各寫一份。位寬也開成 parameter 的做法沒採用：上游一定是 SaltConv，多開只多了寫錯的機會。
    - port 同名直接接：輸入用 conv 輸入的名字(`in_x`、`in_y`、`in_channel`、`in_time`)，輸出用 FC 輸出的名字(`out_neuron`、`out_time`)。
    - 只做暫存器版，不做成參數：跟純組合邏輯版量過(下面「量測」)，照之前層外小電路只選一種的慣例(最接近的是 Part 9 的膜電位輸出暫存器)。純組合邏輯省下的 29 個 FF、1 拍用不到，飽和版的跨層路徑還會變成整個設計最緊的地方。
    - 座標、$t$ 的寫入開關維持「conv 有送而且 ready 是 1」：改成只看 ready 時序只多約 0.1~0.2 ns(跟布局變動差不多)，沒資料的拍子 28 個 FF 會跟著翻轉。
    - 不加 skid buffer：給 conv 的 ready 同一拍看 SaltFC 的 `in_ready`，這條反壓路徑餘裕 +1.674、+2.367，不是最長路徑。
    - 乘加不用 DSP：常數乘法合成成 LUT 加進位鏈。「乘加放進 DSP」的版本沒有量。
- RTL(2026-11-09)：`fc/ConvToFCAdapter.sv` 照事件流程分兩段(1 事件進來：事件暫存器、給 conv 的 ready；2 換算、送出)。`in_ready = !event_valid || out_ready`；`event_valid` 在 `in_ready` 時更新成 `in_valid`，要 reset；座標、$t$ 在 `in_valid && in_ready` 時寫，沒有 reset；`out_valid` 就是 `event_valid`，`out_neuron` 從存的座標算。
    - elaborate(non-project `synth_design -rtl`)7 組形狀都展開、port 位寬正確(例：$16\times9\times9$ 座標各 4 位元、$\text{src}$ 11 位元；全部是 1 時 $\text{src}$ 1 位元)；`-lint` 2 組都是 0 則訊息。
- 答案(2026-11-09)：`scripts/fc/gen_conv_to_fc_adapter_ref.py`，用訓練端 `salt_core.connectivity.conv.unravel_conv_source` 把 $0\sim n_{in}-1$ 每個 $\text{src}$ 拆成座標(conv 層讀輸入事件就是用它，也就是訓練端攤平順序的定義)，每個 $\text{src}$ 放兩次、順序打亂；另外用 numpy `ravel_multi_index` 攤平回去，跟 $\text{src}$ 相同才寫檔。$t$ 不遞減、可以重複，含 0 跟 $2^{16}-1$。
    - 腳本也確認繞回、飽和兩個量化資料夾的 conv2 輸出都是 $16\times9\times9$、out 層 $n_{in}$ 都是 1296；跑完訓練端 `git status` 不變。
    - 參數組 $(OC,H_{out},W_{out})$，`TIME_WIDTH` 都是 16：訓練端 (16,9,9)；(3,5,7) 都不是 2 的次方、列數跟行數不同；(4,4,8) 都是 2 的次方；(1,9,9) 只有一個 channel；(5,1,6) 只有一列；(6,5,1) 只有一行；(1,1,1)。
- testbench(2026-11-09)：只例化轉接模組，上游(conv)、下游(SaltFC 的輸入)都是 testbench。
    - `tb_conv_to_fc_adapter_common.svh`：照答案檔順序送座標，沒被收下就維持；記一份「收進來、還沒送出去」的清單，每拍比 `out_valid` 等於清單不空、`out_valid=1` 時 `out_neuron`、`out_time` 等於清單第一筆(下游不收的拍子也比)、`in_ready` 等於「清單空的或下游這拍收」；送完多跑 3 拍、比總筆數。
    - `tb_conv_to_fc_adapter_ready_high.sv`(上游每拍送、下游一直收)、`_ready_random.sv`(兩邊各一半機率)。
    - `scripts/fc/run_tb_conv_to_fc_adapter.tcl`：兩支各 7 組。
- 驗證(2026-11-09)：
    - 14 組 ALL PASS。`ready_high` 的拍數是「事件數 + 1 + 結尾 3 拍」，每拍過一筆、剛好晚 1 拍。
    - 反向測試(做完還原，跟改之前逐 byte 相同)：
        - 列、行的乘數對調：列數跟行數不同的 4 組裡 3 組 FAIL；(5,1,6) 只有一列，$o_y$ 一定是 0，照樣過。
        - ready 只看「暫存器空的」：7 組全部 FAIL。原本預期是每兩拍才過一筆，實際是卡死：`event_valid` 也只在 ready 是 1 時更新，裝進一筆之後 ready 永遠是 0。
        - ready 固定 1：7 組全部 FAIL，下游不收時暫存器被蓋掉。
    - 沒有接上 conv2、SaltFC 跑資料：轉接模組單獨驗證過；硬體 conv2 → 轉接模組 → SaltFC 算得對是推論(三段各自跟訓練端比過)，資料驗證在 Part 11。量測用的外包頂層只合成、沒模擬過。
- 量測(2026-11-09，conv2 → 轉接模組 → SaltFC，訓練端形狀，兩層 $R=2,C=2$ 重疊，乘法 DSP 套 `DONT_TOUCH`，4.8 ns 布局繞線，腳本、外包頂層在 session 暫存目錄)：暫存器版、純組合邏輯版 × 繞回、飽和，數字跟比較寫在 FC.md 第 1 節。
    - 正式 RTL 重量一次(暫存器版)，數字跟量測版完全相同：WNS 繞回 +0.333、飽和 +0.379；conv2 → 轉接模組暫存器 +0.953、+0.848；暫存器 → SaltFC 的 FIFO +2.143、+2.171；反壓 +1.674、+2.367；DSP 8 顆(轉接模組沒用到)。
    - conv2 → 暫存器這段 0.85~0.95 ns 的餘裕主要花在 conv2 自己的計算第 2 級(加權重、比門檻、挑選，到 `out_valid` 約 3.3 ns)，轉接模組只占最後的寫入開關約 0.5 ns；跟 conv1 接 conv2 量到的 +0.71~+0.89 同一個水準。
- 工具問題(2026-11-09)：飽和版量測碰到一次平行合成的偶發錯誤 `Synth 20-411`(vivado-usage skill 第 11 節)，單獨重跑就過。

### Part 11 串接比對

- 目標(使用者 2026-11-11)：軟體跟硬體每一層、每一次更新的 $(t,\hat V)$、每一個 spike 都對上。
- 單獨測已經確認的(2026-11-08)：SaltConvNet(conv1 → conv2)輸出、最終狀態跟訓練端相同；SaltFC 吃訓練端 conv2 的輸出，spike、每筆事件之後的 $\hat V$ 跟訓練端相同；兩邊都是 test 前 10 筆。硬體 conv2 接硬體 FC 也對是推論，沒跑過。
- 已定(2026-11-11)：
    - 串接範圍：conv1 → conv2 → `ConvToFCAdapter` → SaltFC → `FCMembraneRegister`。頂層 `net/SaltConvFCNet`，直接例化這五個模組，不經過 `SaltConvNet`(使用者要求重新接；`SaltConvNet` 跟它的 testbench 不動)。SaltFC 是輸出層，固定不 fire、開膜電位輸出。
    - 樣本：test 前 10 筆，跟單層測試同一批。答案照之前的做法由腳本叫訓練端算；原本寫的「用 `reference.npz` 比」不用：它跟 `eval/test_outputs.npz` 欄位相同(每筆樣本只有輸出層最後的 $\hat V$、每層 spike 總數、溢位與截斷旗標)，比不到逐次更新。腳本另外拿 `test_outputs.npz` 對 `spike_count` 跟 FC 最後的 `v_final_int`。
    - catch-up：訓練端壓縮佇列後補的一步(每顆神經元衰減到這一層最後一筆輸入事件的時間，權重 0)，讓 `v_final` 等於「每筆事件每顆都走一步」的密集版；不影響 spike、下一層的輸入。硬體只在事件來時更新，不做這一步。比對時跳過：conv 的逐次更新拿掉最後那一步，最終狀態比 catch-up 之前的值；FC 每筆事件更新全部神經元，catch-up 的 $\Delta t$ 一律是 0。
    - 比對項目：
        - conv1、conv2 每一次更新：寫回神經元 BRAM 那一拍的 bank、位址、$(t,\hat V)$，依 bank 照順序比，不能多寫、少寫。寫入開關是 `compute_cycle && 候選合法`，停住的拍子不寫，每筆事件碰到的每顆神經元剛好寫一次。
        - 每個 spike：conv1 → conv2、conv2 → 轉接模組、轉接模組 → SaltFC 三個介面交握成功那一拍逐筆比。
        - FC 每一次更新：每次 `update_done` 比 10 顆的 `membranes`、`update_time`，次數等於 FC 的輸入事件數。
        - 三個介面的握手規則；樣本結束時兩層 conv 的最終狀態。
    - 參數組：繞回、飽和 × (FC $n_{col}=4$、FIFO 16，實際設定；FC $n_{col}=1$、FIFO 2，FC 每筆事件 10 拍，逼出反壓)，共 4 組；$R=2,C=2$ 重疊。
    - testbench：這條網路最後是膜電位輸出，沒有 ready，只差上游怎麼餵：`tb_salt_conv_fc_net_input_high`(conv1 收得下就送)、`_input_random`(每拍 7 成機率送)。各介面被擋的拍數只印在 log，不當通過條件。
    - 答案檔 `sim_1/new/net/ref/salt_conv_fc_net_SAT<0|1>.txt` 不進 git(估計每個約 33 MB，幾乎都是 conv 的逐次更新)，跑模擬前用 `scripts/net/gen_salt_conv_fc_net_ref.py` 產生；FC 的權重檔、衰減表檔照常進 git。
    - 答案檔格式(使用者確認 2026-11-11)：每筆樣本 `sample <in> <conv1_out> <conv2_out> <conv1_write> <conv2_write> <conv1_state> <conv2_state>`，接 `in <x> <y> <c> <t>`、`conv1_out <o_c> <o_y> <o_x> <t>`、`conv2_out <o_c> <o_y> <o_x> <t> <src>`、`conv1_write`/`conv2_write <row_bank> <col_bank> <addr> <V̂> <t>`、`fc_update <t> <V̂_0> … <V̂_9>`、`conv1_state`/`conv2_state <row_bank> <col_bank> <addr> <V̂> <t_last>`，最後 `end <sample_count>`。
    - 反向測試：conv 寫入開關不排除停住的拍子、轉接模組 `in_ready` 固定 1、答案檔改掉 conv 中間一次更新、答案檔改掉 FC 一筆更新。
    - 合成量測在 Part 12。
- RTL(2026-11-11)：`net/SaltConvFCNet.sv` 照事件流程分 5 段(conv1、conv2、轉接、FC、膜電位暫存器)。conv2 輸出形狀、FC 的 $n_{in}$、層間位寬都在頂層推出來；SaltFC 固定 `SPIKE_OUTPUT = 0`、`MEMBRANE_OUTPUT = 1`、`SHARED_THRESHOLD = 0`，spike 輸出不接、`out_ready` 接 1。
    - elaborate(non-project `synth_design -rtl`)：飽和 $n_{col}=4$、繞回 $n_{col}=1$ 都展開，port 位寬對(`membranes` 110、140 位元)。`-lint` 只有 SaltFC、`NeuronUpdate` 不 fire 時沒用到的訊號(`shifted_product`、`unfitted`、`threshold`、`column_valid`、`spike`、`out_ready`)，新頂層沒有訊息。
- 答案(2026-11-11)：`scripts/net/gen_salt_conv_fc_net_ref.py`。
    - 單層腳本跟著改(行為不變)：`gen_salt_conv_ref.py` 的逐筆迴圈多回傳 `writes`(每一次更新，照硬體順序)，`official_forward` 加 `trace`；抽出 `load_trained_version`(讀量化資料夾、test 樣本、`test_outputs.npz`)、`trained_layer_model`、`check_spike_count`、`bank_location`，`gen_salt_fc_ref.py` 抽出 `trained_layer_model` 並改用 `load_trained_version`。兩支重產的 85 個答案檔、資料檔跟 HEAD 逐 byte 相同。
    - conv 每一次更新的交叉比對：逐筆迴圈的 `writes` 依神經元(`o_c·H·W + o_y·W + o_x`，訓練端 `tile_channels` 的順序)分開，跟官方 `trace` 每顆前 n_real 步的 `v_steps`、`event_ms`、`spike_mask` 逐次比；n_real 從 `event_ms` 有值的步數拿(整數版第 t 步處理佇列第 t 欄，catch-up 那一步跟補齊的步 `event_ms` 是 nan)，並確認有值的步都在最前面。
    - 繞回、飽和兩版 10 筆全部通過，每筆 conv1 約 3.6 萬次、conv2 約 9 萬次更新；答案檔 37.6 MB、37.7 MB(1382018、1387580 行)。FC 權重檔、衰減表檔 $n_{col}=4$、1 各一份寫在 `sim_1/new/net/ref/`，$n_{col}=4$ 繞回版跟 `sources_1/mem` 匯出的相同。
- testbench(2026-11-11)：`tb_salt_conv_fc_net_common.svh` + `_input_high.sv`、`_input_random.sv`，`scripts/net/run_tb_salt_conv_fc_net.tcl`(支援 `NAME:value` 篩參數組；找不到答案檔時提示先跑答案腳本)。conv 的寫 port、記憶體快照用 generate 裡的 assign / `always @(snapshot_request)` 搬出來，判斷都在單一 `initial` 流程。
- 驗證(2026-11-11)：
    - 2 支 × 4 組 ALL PASS。每組比 conv1 358744 次、conv2 923088 次(繞回 917760)更新，FC 12023 次(繞回 11981)更新，三個介面每個 spike。一組 10 筆約 30 秒。
    - $n_{col}=4$、FIFO 16：`conv2_blocked`、`fc_in_blocked` 都是 0，FC 從來沒擋過上游。$n_{col}=1$、FIFO 2：兩個都大於 0(飽和 `input_high` 第 0 筆 32、175 拍)，反壓從 SaltFC 傳回轉接模組、conv2。
    - 反向測試(都在飽和 `input_high`；做完還原，跟備份逐 byte 相同、git 沒有改動)：
        - conv 寫入開關改成 `pipe_valid[L] && 候選合法`(停住的拍子也寫)：FAIL，第一個錯在 sample 0 cycle 827 conv1 多寫。停住時寫進去的位址、值都不對，不是重寫同一個值，所以舊的 `tb_salt_conv_net_ready_high`(只比最終狀態)兩版也 FAIL；這項證明不了逐次比對比最終狀態多抓到什麼，那個由下面改答案檔那項證明。
        - 轉接模組 `in_ready` 固定 1：$n_{col}=4$ 照樣 ALL PASS(FC 不擋)；$n_{col}=1$ FAIL，暫存器那筆被蓋掉(「上一拍送不出去，這一拍資料變了」)，SaltFC 少收 170 筆。
        - 答案檔改 sample 5 一次 conv2 中間更新的 $\hat V$(−952 → −951)：error_count=1，只有那一次更新報錯，最終狀態、輸出事件都沒報。
        - 答案檔改 sample 5 第 500 筆 FC 更新神經元 3(−465 → −464)：error_count=1。
- 極端情況(2026-11-11，從兩個答案檔數的，都在 ALL PASS 的模擬裡)：
    - 測到的(繞回版 / 飽和版)：
        - 同一顆神經元同一毫秒再更新($\Delta t=0$，不衰減)：conv1 115736 / 115736 次、conv2 641520 / 646640 次、FC 10919 / 10967 次。
        - 兩次更新隔超過衰減表深度 75 ms(衰減成 0，含第一次更新就從 $t_{last}=0$ 超過的)：conv1 2152 次、conv2 1728 次，兩版相同；FC 沒有。
        - 剛好隔 75 ms(查表最後一格)：conv1 32 次；conv2、FC 沒有。
        - 膜電位夾在暫存器上下限：繞回版 0；飽和版 conv1 14003 次、conv2 30586 次、FC 3075 次(神經元·次)。
        - 寫回 0(fire 後歸 0 或剛好算出 0)：conv1 28832 / 29011 次、conv2 14598 / 14647 次。
        - 輸入連續兩筆同一毫秒：20000 筆裡 18798 筆。
        - 反壓：`input_high` 每筆樣本 conv1 擋上游約 3.8 萬拍、conv2 擋 conv1 約 2.5 萬拍；SaltFC 擋轉接模組只有 $n_{col}=1$、FIFO 2 那組碰得到。
    - 只在單層測試的人工參數組測過的：繞回真的發生、參數不是 2 的次方、位寬下限、conv $OC=1$、1×1 輸出、FC $n_{row}=1$、最後一列不滿、$f_V>0$、truncate、FC fire(含同一列多個 fire、整層一個門檻)、讀寫衝突、下游長時間不收或交替收、其他 6 種管線設定。
    - 沒測到的：
        - 整條網路真的發生繞回(真實資料整個 test 一筆都沒有，整條網路也沒用人工參數跑過)。
        - 整條網路的其他管線設定(只跑 $R=2,C=2$ 重疊)。
        - 整條網路的 conv FIFO 深度(conv1、conv2 一律 16，只有 FC 換過 2)。
        - 整條網路裡 FC fire(輸出層不 fire)。
        - 樣本中途 reset、清除時還有事件在 FIFO(只測樣本之間 reset；中途 reset 會丟事件，是已知行為)。
        - 時間戳記繞回($2^{16}$ ms，處理方向 2026-11-15 定了、還沒實作，見「待決事項 → 系統整合」)。
        - 事件特別密或特別稀的樣本(#1589、#1073、#7596 沒用，只用 test 前 10 筆)。
- 工具問題(2026-11-11)：`USF-XSIM-95 Failed to open file to read (elaborate.log)` 碰到 2 次(完整跑的 `input_high` 第 1 組、反向測試二的第 2 組 elaborate)，原封不動重跑就過；vivado-usage skill 第 11 節記過同訊息(當時是多個 Vivado 同時開專案)，這次沒有同時開，原因查不到。
- 整條網路層級的補測(人工參數逼出繞回、其他管線設定)：使用者決定先不補(2026-11-14)，「沒測到的」照列。

### Part 12 合成量測

- 要回答的：整條網路放進同一次布局，4.8 ns 還過不過、最長路徑在哪、總共吃多少資源；之前都是分段量(SaltConvNet、conv2 → 轉接模組 → SaltFC、SaltFC 單層)，分段過不代表整條過。
- 已定(使用者確認 2026-11-14)：
    - 量測：`net/SaltConvFCNet`，繞回、飽和各一次，參數同 Part 11 的前兩組(FC $n_{col}=4$、三層 FIFO 16、$R=2,C=2$ 重疊)，4.8 ns。不量 $n_{col}=1$、FIFO 2(只為模擬逼反壓)、其他管線設定、其他週期。
    - 飽和版 FC 的 `.mem` 用訓練端 `tools/export_fpga.py --fc-cols 4` 匯出到 `sources_1/mem/<飽和版資料夾>/`(選 A；不選合成腳本讀 `sim_1/new/net/ref/`)：每層都從 `quant_versions.txt` 指的資料夾讀。
    - 合成共用流程抽成 `scripts/synth_common.tcl`(同 `sim_common.tcl` 的分法)，`synth_salt_conv_net.tcl` 跟著改；改前改後同一份 RTL 各跑兩版，`info.txt`、utilization 要逐行相同。
    - 極限測試(使用者 2026-11-14 加的)：BRAM 用到約 84 顆(假設 144 顆裡有 60 顆給別的電路，±5 顆)時 4.8 ns 還剩多少餘裕。
        - 不擋 BRAM 位置，讓工具從 144 顆裡挑；占掉那 60 顆的電路用到的 LUT、繞線沒模擬，結果偏樂觀。
        - 網路：conv1 → conv2 → conv3(16 通道 K3 S2 P0，輸出 4×4)→ 轉接模組 → FC1(256 → 512，fire)→ FC2(512 → 256，fire)→ FC 輸出層(256 → 10，不 fire)→ 膜電位暫存器。多一層 conv 縮小攤平寬度是使用者提的；兩層隱藏讓最大一顆權重記憶體約 29 顆 BRAM，不是一顆跨七十顆(結果沒過時分不出是互搶還是 FC 結構)。
        - 三層 FC $n_{col}=4$(agent 定)：跟量過的輸出層同一種控制寬度，每層 FC 的時序能跟 Part 8、9 的單層量測比；代價是每筆事件 FC1 128 拍、FC2 64 拍，不影響時序量測。
        - 權重、門檻用固定 seed 的亂數(用真的權重可能被內容修剪，Part 8 的門檻 BRAM 56 根輸出腳只接 8 根)，訓練端的打包函式寫 `.mem`；衰減表借訓練端現有的(conv3 借 conv2、FC1/FC2 借輸出層)。新層 $i_V$ 同 conv2(繞回 14、飽和 11)，繞回、飽和各一次。
        - 先只合成看 BRAM 數，不在 79~89 就調 FC1 的輸出寬度，落在範圍內才布局繞線。只合成、不模擬，FC 接 FC 在模擬裡沒跑過(使用者 OK)。
        - Part 7 留的「`FCSpikeSelect` 合成量測 Part 12 一起量」：FC1、FC2 會 fire，在極限測試裡量到。
- 做了什麼(2026-11-14；數字、路徑、各層資源都整理在 [`SaltConvSynthFlow.md`](../Concept/Layer-RTL/SaltConvSynthFlow.md)「量測結果」，這裡只記結論)：
    - 飽和版 `out_weight.mem`、`out_decay.mem` 匯出：conv 6 個檔跟 HEAD 逐 byte 相同，FC 2 個檔跟 Part 11 testbench 用的相同；訓練端 `git status` 不變。
    - `scripts/synth_common.tcl` 抽出，`synth_salt_conv_net.tcl` 改寫：改前改後兩版報告除了表頭逐行相同，結果跟 10/27 相同(繞回 +0.281、飽和 +0.205)。
    - 實際網路 `SaltConvFCNet`(`synth_salt_conv_fc_net.tcl`)4.8 ns：繞回 +0.301、飽和 +0.179，兩版都過；最長路徑在 conv 層內，跟兩層串接同一類；BRAM 12.5、DSP 12。讀權重位址 +1.18 以上，Part 4b 的位址暫存器不用做。
    - 極限測試(`SaltStressNet.sv`、`gen_salt_stress_net_mem.py`、`synth_salt_stress_net.tcl`)：
        - 原定「調 FC1 輸出寬度補到 79~89」行不通：Vivado 把唯讀記憶體深度補到 2 的次方，FC1 = 512 時 BRAM 總數 73，576 時 129(兩顆串接、讀出暫存器併不進去)，中間沒有。
        - FC2 的 $n_{in}=576$ 時位址乘法合成成 DSP，`synth_common.tcl` 的 DONT_TOUCH 檢查改成只看 `NeuronUpdate` 的 DSP。
        - 使用者決定(2026-11-14)：不強制到 84，先布局 73 顆那版。
        - 73 顆(BRAM 50.7%)4.8 ns：繞回 +0.151、飽和 +0.092，兩版都過。整體比實際網路少 0.15 / 0.09(在 ±0.2 變動內)；掉得超過變動範圍的兩處都在 FC(輸出層衰減乘法路徑繞線變長、停住訊號拉到 28 顆權重 BRAM)，conv 幾乎沒變。布局時搬出 14、16 顆 BRAM 的輸出暫存器(實際網路沒搬)。
- 待使用者決定(2026-11-14 提出)：
    - 極限測試要不要補到約 82 顆：FC2 後面多一層 FC 256 → 128(權重 8192 字，剛好 2 的次方，約 +9 顆)。其他做法比過：FC1、FC2 改 $n_{col}=5$(約 87，控制寬度沒量過)、conv1 改 32 通道(約 85，神經元記憶體可能串接，在 conv1 最長路徑上)。
    - 要不要量最高時脈(照 UG949 用更緊的週期多跑幾次)：只跑 4.8 ns 一次只能說過不過、大概剩多少。
- Part 12 的檔案還沒 commit：`synth_common.tcl`、`synth_salt_conv_net.tcl`(改)、`synth_salt_conv_fc_net.tcl`、`SaltStressNet.sv`、`gen_salt_stress_net_mem.py`、`synth_salt_stress_net.tcl`、飽和版 `out_*.mem`、`SaltConvSynthFlow.md`、這份 TODO。

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
| D12 | SaltConv 門檻也加「整層一個」參數，跟 SaltFC 對稱：門檻陣列大小 1 或 $OC$，選的索引是 0 或 `pipe_channel[L]`；Conv.md 的不重疊、讀寫衝突照 FC.md 第 5 節 ⑦⑧ 補例子跟通用規則 | SaltFC Part 8 做完後 |

- D4：
    - 每拍都開：讀取開關不用等推進的判斷，量起來稍快(時脈多 0.5~4 MHz，接近布局繞線的變動範圍)；卡住的拍子($k\ge2$、`out_ready=0`)、$R=2$ 等資料的拍子會白讀記憶體，多耗電。
    - 推進才開：不會白讀；讀取開關接在推進的判斷後面，慢一點點。
    - 還沒評估：白讀的次數、多耗多少電。
- D5：方向是共用可以(避免同一段檢查改四次)，但核心流程(餵資料、比輸出、比神經元狀態)要在一個地方看得完；涵蓋統計拆開，跟核心分開。
- D6：現在靠 `keep_hierarchy = "soft"` 加上每次合成檢查 `DOB_REG` 確認；Vivado 內部原因 log 跟官方文件都沒寫，查不到(vivado-usage skill 第 10 節)。
- D7：要先解決 `MEMORY_INIT_FILE` 只能給檔名、不能帶路徑的問題(權重檔改成不重複的檔名、加進專案，訓練端匯出的命名可能也要改)；XPM 也要求記憶體至少 2 個字。
- D10：URAM 不能帶初始值，權重要在執行時寫入。
- D11：只開參數不夠，SaltConv 不 fire 就沒有任何輸出，要跟 FC 一樣加膜電位輸出埠才有用；`NeuronUpdate` 在 Part 6 已經支援。
- 額外補充：為了分析運作的狀況與能力，後續我希望補上一個視覺化的分析，輸入事件在時間軸上的分布，layer 之間的事件在時間軸上的分布，輸出在時間軸上的分布，用來看出延遲狀況，細節之後再討論。

## 待決事項

### 量化與數值

- `FIFO_DEPTH`：反壓、不丟事件的策略已定，深度要看目標時脈跟實際輸入事件率，事件率還沒有。
- FPGA 上實際省多少功耗：運算量少 20 倍不等於功耗少 20 倍，漏電流、clock tree 是固定成本，要 Vivado 功耗分析或實測才有數字。

### 系統整合

- `EvtDecoder → conv1` 轉接模組：正式專案接 GenX320 才用。N-MNIST 只用來確認模型能訓練、硬體能跑、能合成、運作正確，不會拿 GenX320 餵 N-MNIST(使用者 2026-11-15)。
    - `EvtDecoder` 送出的 `M_AXIS_TDATA`(`EventProcessor.sv` 第 143 行，2026-11-15 查到)：
        - 位元 63~57 補 0。
        - 位元 56~46 是 $x$(11 位元，0~319)，45~35 是 $y$(11 位元，0~319)。
        - 位元 34 是極性：0 負(OFF)、1 正(ON)。
        - 位元 33~0 是時間，單位 µs(34 位元)：高 28 位元是最近一筆 TIME_HIGH 封包，低 6 位元是事件自己帶的。
    - 極性直接當 $c$：訓練端讀 N-MNIST 也是 $c=0$ OFF、$c=1$ ON。握手 `TVALID`/`TREADY` 跟 `in_valid`/`in_ready` 同一套規則，直接接。
    - 座標(2026-11-15 定)：相機 320×320，conv1 輸入 `IN_ROWS`×`IN_COLS`。轉接模組做邊界比對：窗內的減掉起點送 conv1；窗外的照樣拉 `TREADY` 收下、不拉 `in_valid`，不造成反壓。
        - 不管感測器 ROI 有沒有開都保留：每軸兩個比較器加一個減法器；ROI 沒設好或重設回全畫面時，擋住超出範圍的座標(conv1 只測過範圍內)。
        - 窗的起點用 parameter，窗的大小就是 conv1 的 `IN_ROWS`、`IN_COLS`；起點設 0 就是不減。正式專案要執行中換窗再改成暫存器。
        - GenX320 有 ROI：感測器 V4L2 裝置的 `roi_set`(矩形窗)、`roi_roni`(窗內留或窗內排除)、`pxl_set`(逐像素)。窗外像素不產生事件，事件率在進 PL 之前就降下來。
    - µs 換 ms：用 floor，$t=\lfloor t_{\mu s}/1000\rfloor$，跟訓練端相同。
        - 電路定案(使用者 2026-11-15)：乘倒數，先右移 3 位(÷8)，再乘 274877907($\lceil 2^{35}/125\rceil$)取乘積第 35 位起的 `TIME_WIDTH` 位(÷125)；乘法放 DSP，乘法後 3 級暫存器。
            - 輸入 34 位元 µs(`EvtDecoder` 時間的完整範圍)，右移後 31 位元，乘積 60 位元；完整的商最大 17179869(25 位元)，留低 16 位元。
            - 常數多出來的誤差 $7x' < 2^{35}$($x'<2^{31}$)，34 位元的所有輸入都等於 $\lfloor t/1000\rfloor$。
            - 單獨量：DSP 4 顆、FF 4、LUT 1，延遲 4 拍、每拍收一筆，4.8 ns 餘裕 +2.847(量測見下面的表)。
        - 有自己的管線跟 valid，照「有邏輯才包模組」另開一個模組；放哪個資料夾、名字還沒定。
        - GenX320 不能改時間單位(2026-11-15 查)：Prophesee EVT 2.1 文件只寫 µs、34 位元；openeb 暫存器表 `ro/time_base_ctrl` 有 7 位元的 `us_counter_max`(openeb 寫 25，註解「Core clock is 25 MHz」)，官方沒有說明，照名字推是「幾個時脈算 1 µs」；要讓 1 ms 剛好 $2^k$ 格，一格要 $25000/2^k$ 個時脈，最多除到 8 得 3125，超過上限 127。
        - 網路上的做法(2026-11-15 查)：主流是乘倒數(MathWorks HDL Coder 文件)；查表法(de Dinechin 等)每步的表輸入是餘數加這步吃的位元，作者寫「Efficient for small constants only」，除 125 的餘數就 7 位元，超過 LUT6；UG901 Table 7-9 列 `/` 為 Supported，沒寫電路。
        - 四種做法單獨量(2026-11-15，scratchpad 量完已刪)：testbench 邊界值、1000 的倍數前後一格、隨機 1 萬筆共 16219 筆，上下游隨機交握，全部跟 $\lfloor t/1000\rfloor$ 的低 16 位元相同；反向測試把常數改成往下取整，4437 筆抓到。合成流程同 `synth_common.tcl`(out-of-context、埠延遲 0、DSP 設 `DONT_TOUCH`、預設指令)，4.8 ns 各跑一次布局繞線，數字是布局後：

            | 做法 | 乘法後幾級 | 4.8 ns 餘裕 | LUT | FF | CARRY8 | DSP | 延遲(拍) | 每筆佔幾拍 |
            |---|---|---|---|---|---|---|---|---|
            | A 乘倒數，DSP | 1 | +1.898 | 35 | 20 | 5 | 4 | 2 | 1 |
            | A 乘倒數，DSP | 2 | +1.927 | 35 | 37 | 5 | 4 | 3 | 1 |
            | A 乘倒數，DSP | 3 | +2.847 | 1 | 4 | 0 | 4 | 4 | 1 |
            | A 乘倒數，DSP | 4 | +2.847 | 1 | 19 | 0 | 4 | 5 | 1 |
            | A 乘倒數，DSP | 5 | +3.263 | 1 | 34 | 0 | 4 | 6 | 1 |
            | A 乘倒數，LUT | 1 | +0.721 | 301 | 49 | 42 | 0 | 2 | 1 |
            | A 乘倒數，LUT | 2 | +0.833 | 301 | 66 | 42 | 0 | 3 | 1 |
            | 直接寫 `/ 1000` | — | −1.667 | 380 | 17 | 42 | 0 | 1 | 1 |
            | B 長除法 | — | +3.316 | 41 | 55 | 0 | 0 | 26 | 26 |

            - A 的 31×29 位元乘法拆成 4 顆 DSP。乘法後 1、2 級時部分積在 slice 相加(5 個 CARRY8)；3 級以上 Vivado 把暫存器推進 DSP、在 DSP 之間串接相加，只剩 valid 位元在外面。
            - A 用 LUT 時多一級沒有幫助：沒開 retiming，暫存器留在乘法後面，乘法還是一拍做完(13 級邏輯)。
            - 直接寫 `/ 1000`：Vivado 合成成 22 級邏輯的組合除法器，4.8 ns 過不了。
            - B 每筆 26 拍(收進那拍 + 25 拍)，算的時候不收下一筆。Part 11 每筆樣本約 2000 筆輸入、conv1 擋上游約 3.8 萬拍，推算 conv1 平均每筆約 20 拍，B 比它慢。
            - 單獨量、各跑一次；接進整條網路後餘裕會變小。
    - 接相機時才碰到、還沒討論(2026-11-15 列出)：
        - 時脈：`EvtDecoder` 跑在 `pl_clk0`(約 125 MHz)，SaltNET 照 200 MHz 量。同一個時脈就是 SaltNET 降到 125 MHz；不同時脈中間要跨時脈 FIFO。
        - 反壓：`EvtDecoder` 幾乎不能擋 ESST 超過幾拍(擋久了 ESST 會丟事件，見 GENX320 TODO「已定案」)，conv1 會擋上游。相機量過每秒約 14 萬筆(預設 bias、人走動)到 100 萬筆以下，conv1 每秒吃得下幾筆還沒算。
        - PS 還要不要收相機事件：GENX320 定的是 `EvtDecoder` 只輸出一條串流接 AXI DMA，要接 CSNN 時重新接線。同時給 PS 跟 conv1 要分兩路，兩邊的 ready 怎麼合要另外想。
- PS → PL → PS 的系統檢查路徑(使用者 2026-11-15 提)：PS 送訓練端的事件(N-MNIST)進 PL 的網路，PL 把輸出送回 PS 看答案，確認整個系統串得起來。還沒設計，不卡 `EvtDecoder → conv1` 轉接模組。
    - 跟轉接模組的關係：PS 用 `EvtDecoder` 同一種 64 位元排法送，就能經過同一個轉接模組；N-MNIST 原始資料是 µs，硬體的 µs 換 ms 也會跟訓練端一起比到。談這條路徑時再定。
- 時間戳記繞回(2026-11-15 討論；方向定了，什麼時候做還沒定，agent 建議等正式專案接相機連續跑時再規劃成一個 Part)：
    - 1 問題：
        - 時間只有 `TIME_WIDTH` = 16 位元，只能存 0~65,535 ms，再往上從 0 數：65,536 存成 0，66,540 存成 1,004。
        - 硬體用時間只做一件事：每次更新算 $\Delta t$ = 這次時間 − 上次更新時間($t_{last}$)；$\Delta t$ 超過 75 時電位直接歸零。
        - 16 位元減法遇到負數會自動加 65,536，所以真實間隔小於 65,536 ms 都算得對。只有一顆神經元隔了 65,536 ms 以上才被更新才會錯。
        - 例：神經元 B 在 1,000 更新，下次在 66,540(存成 1,004)。硬體算 1,004 − 1,000 = 4，以為只隔 4 ms，留下早該歸零的電位；訓練端是 65,540，應該歸零。
        - conv 每顆神經元各自存 $t_{last}$(神經元記憶體一格 {$t_{last}$, $\hat V$})；FC 整層共用一個 $t_{last}$ 暫存器。
    - 2 為什麼不加寬：
        - 加寬只是把期限往後延(24 位元 4.66 小時、32 位元 49.7 天)；源頭 4.77 小時那一跳(第 9 項)不管多寬都會錯。
        - BRAM(照 BRAM 能設的寬度推算，沒合成)：神經元記憶體 16 位元 6 顆；24 位元 6 / 8 顆(飽和 / 繞回)；32 位元 10 顆。
        - 縮小 `TIME_WIDTH` 省 BRAM 也不划算：BRAM 一階一階省，最多省 2 顆(只有飽和版、W ≤ 9 時 conv1 塞進半顆)，掃描要快很多，門檻的餘裕也變小。
        - URAM(K26 有 64 顆，每顆固定 4K×72)：一個 bank 才 400~648 格，用不到兩成；這題不需要加寬，用不到。
    - 3 想法：把早該歸零的神經元清成 0(使用者 2026-11-15 同意)。
        - 依據：$\hat V_{new} = A\cdot\hat V + q$。$\Delta t$ 超過 75 時 $A=0$，得到 $q$；電位是 0 時不管 $A$ 多少也是 $q$。所以「電位是 0」跟「已經完全衰減」對之後每次更新的結果都一樣。
        - 趁一顆神經元早就該歸零、但還沒舊到 65,536 ms 時把電位寫成 0，之後不管 $\Delta t$ 被算成多少都對，跟訓練端逐位元一致。
        - lazy update 照舊：掃描不算衰減，只檢查是不是早就該歸零；衰減還是只在事件來時算。
    - 4 整個 conv 怎麼掃：
        - 每一層一個掃描；4 個 bank 同時掃同一個位址，一格一格輪，掃完最後一格回到第 0 格，一直重複。
        - 節奏：每 25 ms(事件時間)一個刻度。「現在」跨過一個刻度就掃一格、刻度往後加一格；一次跨過幾個刻度就補掃幾格，每一格都用當下的「現在」算。例：事件在 3、26、27、49、52 ms 進來 → 3 跨過 0，掃第 0 格(用 3 算)；26 跨過 25，掃第 1 格(用 26)；27、49 沒跨過 50，不掃；52 跨過 50，掃第 2 格(用 52)。若下一筆隔到 80 才來，一次跨過 50、75，補掃兩格，都用 80 算。
        - conv1 一個 bank 648 格、每 25 ms 一格，約 16 秒(P = 16,384 ms)整層掃完一遍；conv2 一個 bank 400 格，改成每 41 ms 一格，一樣 16 秒一遍。
        - 看「現在」不看時脈：年紀是用事件時間算的。PS 灌資料比真實時間快時(例如 160 秒的錄影 16 秒送完)，數時脈的 16 秒換成事件時間變成 160 秒，比一整圈還大，會整段漏掉。
        - 一次掃幾格做成參數：分散(一次 1 格，事件停約 7 拍)或一次掃完(一次 648 格，事件停約 3.3 µs；感測器規格上限每秒 1000 萬筆時這段會進來約 33 筆，conv1 的 FIFO 只放得下 16 筆，會擋住 `EvtDecoder`、相機那邊丟事件)。建議分散。
        - 判斷「現在」到了下一個刻度沒，不能直接比大小(2026-11-15 補)：
            - 問題：「現在」跟「下一個刻度」都只存 16 位元，都會繞回，而且不一定同時繞回。
            - 情況一，刻度先繞回：真實刻度 65,550 存成 14，現在 65,526。真實比較 65,526 ≥ 65,550 不成立，不該掃；直接比 65,526 ≥ 14 以為到了，刻度一路加 25 連掃約 2,600 格才停(多掃，不會算錯，但浪費)。
            - 情況二，現在先繞回：刻度 65,525，FIFO 收進真實時間 65,541 的事件，現在存成 5。真實比較 65,541 ≥ 65,525 成立，該掃；直接比 5 ≥ 65,525 以為沒到，要等現在再數到 65,525(約 65 秒)才掃，這段期間神經元可能舊到超過 65,536 沒被清，算錯。
            - 解法：算 (現在 − 刻度) mod 65,536，小於 32,768 就算到了。16 位元減法算出來是「真實差」或「真實差 + 65,536」：真實差是正的(到了)會是小的數，是負的(還沒到)會變成接近 65,536 的大數，所以用一半切就還原出正負號。情況一：65,526 − 14 = 65,512(就是 −24 + 65,536)，沒到；情況二：5 − 65,525 mod 65,536 = 16，到了。
            - 條件：真實差要在 −32,768 ~ +32,767 之間才分得出正負。掃描補完後刻度只比現在多不到 25，「現在」一次跳 J 後真實差大約是 J，所以要 J < 32,768。這條比第 9 項的前提(J < 16,384，從掃描上限算出來的)寬鬆，前提成立它就成立，不用另外加前提。
            - 這裡的 32,768 是 65,536 的一半(分正負號)，只能是這個值；跟門檻 32,768(下限 76 跟上限 49,152 之間挑的中間值，可以換)數字一樣但來源不同。
    - 5 掃一格做什麼：
        - 讀出這格的 {$t_{last}$, $\hat V$}；年紀 = 現在 − $t_{last}$(16 位元減法)；年紀 ≥ 32,768 而且電位不是 0 就寫 0，否則不動。電位已經是 0 的不用寫，結果本來就一樣；寫的時候寫全 0，可以共用 reset 清除那條寫入路徑。
        - 「現在」= conv1 的 FIFO 最新收進的事件時間，每一層都用這個值。conv2 不用自己 FIFO 的時間：conv1 都沒 fire 時 conv2 收不到事件，自己的時間停住，conv2 的神經元永遠不會被清。
        - 接相機時「現在」由轉接模組在每一筆收進的事件更新，包含 ROI 外會被丟掉的，看的是整顆感測器。
        - 「現在」晚幾拍到沒關係：用的值舊一點只是清得晚幾拍，往安全的方向偏；佈線太長可以在每層前面多一級暫存器。
    - 6 門檻為什麼是 32,768：
        - 下限：FIFO 裡排隊的事件時間比「現在」早。例：FIFO 是 [1,080(剛進來，就是現在), …, 1,050(下一筆，會打到 A)]，A 在 1,000 更新、電位 > 0。掃描算 A 的年紀是 80，門檻 76 就會清掉；但 1,050 那筆對 A 只隔 50 ms，應該算 $A[50]\cdot\hat V + q$(可能 fire)，清掉後只剩 $q$，錯。
        - 下限的條件：下一筆最早是 FIFO 裡最舊的 $t_x$，要 $t_x - t_{last} > 75$；掃描只知道「現在」，帶入得 現在 − $t_{last}$ > 75 + (現在 − $t_x$)，右邊就是門檻要超過的值。多層時 $t_x$ 要算到這一層前面所有還沒處理完的事件(例如 conv1 FIFO 裡的事件可能讓 conv1 fire、打到 conv2)。落後通常只有幾 µs，但硬體保證不了上限(PS 灌資料比真實時間快時會落後比較多)。
        - 上限：掃描算年紀也是 16 位元減法，真實年紀超過 65,536 後算出來又變小，掃描以為它還年輕，永遠不清。數線(`=` 不能清、`-` 能清)：`0 ====門檻------65535 0 ====門檻------65535 0`，每顆每 P 被看一次，要保證落在 `-` 那段：65,536 − 門檻 ≥ P = 16,384，門檻 ≤ 49,152。P 剛好一圈時每次都看到同一個位置，第一次落在 `=` 就永遠清不到。
        - 取中間 32,768：只想讓 P 大的話門檻越小越好，但下限的落後保證不了；取中間讓落後要超過 32 秒才出事，掃描也最慢可以 32 秒一遍。
    - 7 跟事件處理撞在一起時：
        - 掃描跟著「現在」走，「現在」只在事件進來時變，所以掃描輪到時通常事件正在處理(例如 conv1 一筆事件要一個通道接一個通道更新 8 個通道，每個通道「這一拍讀 → 過 3 拍寫回」，下一拍就讀下一個通道)。
        - 規則：事件已經讀出來、還沒寫回的那幾格先寫回(最多 3 拍)，這段期間事件不送新的讀；接著掃描讀、判斷、寫(約 4 拍)；掃描做完事件繼續。例：通道 1、2 已經讀了 → 第 3 拍通道 3 先不讀 → 第 4、5 拍通道 1、2 寫回 → 第 6 拍掃描讀第 k 格、第 8 拍拿到資料判斷、第 9 拍要清就寫 0 → 第 10 拍讀通道 3，繼續做完。
        - 為什麼掃描不能直接插進去：第 k 格可能剛好是通道 1、2 正在更新的格子，這時讀到的是寫回前的舊值，掃描根據舊值寫 0，會把事件剛寫好的新值蓋掉。不先比位址就不知道是不是同一格，所以一律等。
        - 為什麼不能讓事件一直先做：事件一直來的話掃描永遠插不進去。
        - 每掃一格事件停約 7 拍(35 ns)；剛好在掃描時進來的事件晚最多 7 拍開始。
    - 8 FC：
        - FC 整層共用一個 $t_{last}$ 暫存器，不用掃記憶體。一直算「現在 − FC 的 $t_{last}$」，超過 32,768 就把一個位元設成 1；下一筆事件進來時 10 顆全部當成 $\Delta t$ 超過 75($A=0$)，更新完清回 0。
        - FC 管線裡同時有好幾列在算，這個位元要跟著那筆事件的每一列帶下去，實作時再定。
    - 9 前提跟接受的情況：
        - 輸入至少每 16,384 ms 有一筆事件，不做「很久沒輸入」的處理(使用者 2026-11-15)。
            - 不成立時：「現在」停住、掃描也停，下一筆來時一次跳過 `-` 那段。例：B 在 1,000 更新後 65,540 ms 都沒有事件，66,540 那筆打到 B，算出 4。
            - 16,384 的來源：還沒被清的神經元年紀最多「門檻 + P」= 49,152；「現在」一次跳 J，加完要小於 65,536，所以 J < 16,384。
            - 為什麼不處理：事件相機畫面靜止時也會送雜訊事件。Graca & Delbruck(2021)：低光時雜訊事件更多；McReynolds 等(2023)：低於約 10 lux 時輸出以 shot noise 事件為主；OpenMV 的 GenX320 文件：靜止場景下不調 bias，雜訊事件會占多數。我們量過一般場景背景雜訊每秒 30~50 萬筆、低雜訊 bias 有人在動時每秒約 3.2 萬筆。PS 播放的錄影本身也帶雜訊事件；N-MNIST 每筆樣本會 reset。
            - 查不到的：GenX320 datasheet 第 42 頁的背景事件率要登入才看得到；「低雜訊 bias + 靜止畫面」沒量過。
            - 真的發生時：只有空白後第一次更新、算出的 $\Delta t$ 剛好繞進 0~75 的神經元錯一次。要處理的話，轉接模組看 34 位元完整時間，跟上一筆隔超過 16,384 ms 就先擋住、等網路清空、全部清成 0 再放進去(每一顆都已經完全衰減，結果一樣)。
        - 輸入事件的時間不會倒退(N-MNIST 讀進來時有排序；Prophesee 文件沒寫保證遞增)。
        - 源頭每 4.77 小時那一跳：接受，不做電路(使用者 2026-11-15 暫時定案)。
            - 問題：`EvtDecoder` 的 µs 時間 34 位元，數到 $2^{34}$ µs(約 4 小時 46 分)從 0 重新開始；換成 ms 是 17,179,869.184，不是 65,536 的整數倍，所以 16 位元的 ms 從 9,437 往回跳到 0(真實只過不到 1 ms)。
            - 影響：剛活動過的神經元算出 $\Delta t$ = (0 − 9,437) mod 65,536 = 56,099，電位歸零；「現在」看起來往前跳 56,099 ms，掃描也會把它們清成 0。等於整條網路那一瞬間 reset 一次，丟掉的最多是前 75 ms 累積的狀態，之後恢復正常。
            - 不能接受時的做法：轉接模組偵測 µs 從頭數了，把繞回前數到的量補進去，讓 ms 一直往上數(一個比較器、一個加法器、兩個小暫存器，除法器輸入多 1 位元要重新確認)；或時間單位改 1024 µs($2^{34}$ µs 剛好 $2^{24}$ 格，自然接得上，但訓練端要改)。
    - 10 代價：
        - 耗電(用 conv1 神經元記憶體的讀取次數估，沒跑功耗分析)：掃描每秒約 158 次；處理事件每秒最多約 450 萬次(相機每秒 14 萬筆 × 每筆最多 32 格)；沒輸入時不掃。對照：每 ms 更新全部神經元要每秒約 231 萬次讀、乘、寫。
        - 時間：每 25 ms 事件停 7 拍，約百萬分之 1.4。
        - 用量：每層一個位址計數器、一個刻度暫存器，每個 bank 一個比較器；還沒量。
        - 時序：讀位址前面多一個二選一(掃描的位址或事件的位址)，讀位址那條是之前記過的最長路徑之一(延後表 D2)，要合成才知道。
    - 11 會改到哪裡：
        - 頂層或轉接模組：存「現在」，接給每一層。
        - SaltConv：掃描的控制(刻度、位址、讓事件暫停)、每個 bank 的判斷。
        - NeuronMemory：讀位址多一個選擇；寫 0 共用 reset 清除那條路徑。
        - SaltFC：一個位元，跟著事件的每一列帶下去。
        - `DecayLookup` 不用改(現在用 `TIME_WIDTH` 位元無號減法算 $\Delta t$)。
    - 12 還沒決定的：
        - 什麼時候做(agent 建議等正式專案要連續跑時)。
        - 模組怎麼分、名字。
        - 怎麼驗證：模擬不可能真的跑 65 秒，大概要把 `TIME_WIDTH` 設小，門檻、刻度跟著縮，逼它很快繞回。
        - 一次掃幾格的預設值。
- 輸出層改 per-tensor(`out_granularity: per_tensor`，10 顆共用一個 $s$，使用者考慮過，2026-10-29 還沒決定)：
    - 好處：讀出 argmax 不用乘 $s_i$，直接比 $\hat V$，不需要乘法器。跟門檻無關：輸出層不 fire，本來就沒有門檻。
    - 不變：conv1、conv2 的量化跟 `.mem`、SaltConv 串接、`out_decay.mem`、SaltFC RTL。
    - 要重做：`out_weight.mem`；out 層 $i_V$ 可能變(繞回版重新校準，飽和版寫死 `out: 11` 要確認夠不夠)；`tb_fc_weight_lookup`、`tb_fc_neuron_memory`、`tb_salt_fc_no_spike` 的訓練端參數組；準確率、`reference.npz`。
    - 7 bits 時 per-tensor 掉多少沒量過(訓練端只有 4 bits 的舊資料：per-channel 0.8985、per-tensor 0.8830)。
    - 中間層要選 per-tensor 得改 `example/quant_run.py` 的 `quant_layer_specs` 跟 config，`salt_core` 的 `LayerQuantSpec.per_channel` 本來就逐層。
- 輸出層乘 $s_i$：$\text{score}_i=\hat V[i]\cdot s_i$ 是整個推論唯一的浮點運算。
    - 2026-10-22 定：不放在 FC 層裡。FC 只提供膜電位輸出(FC.md 第 6 節)，乘 $s_i$、argmax 由層外另外寫的模組處理，那個模組還沒設計；放 FPGA 內還是外部還沒定。
    - 2026-11-07：層外存每顆最新值的暫存器模組、「一筆更新完」脈衝定了(FC.md 第 6 節 ⑥)，argmax 從那裡讀；乘 $s_i$、argmax 本身還沒設計。
- 跟 `ps_host_if` 替換模組要不要融合：等兩邊資源用量(BRAM、LUT、功耗)出來再決定。

### 驗證

- 訓練端存的逐筆結果：每個量化資料夾的 `reference.npz`(val 前 2000 筆，量化時寫的)、`eval/test_outputs.npz`(test 全部 10000 筆，評估時寫的)，欄位相同。
    - 欄位：`labels`、`preds`、`v_final_int`(輸出層暫存器最終值，catch-up 之後)、`spike_count`(每層 spike 總數)、`truncated`(訓練端容量截斷)、`overflowed`(每層有沒有碰到暫存器範圍)。
    - 每筆樣本只有最後的結果跟總數，比不到逐次更新；逐筆比對靠答案腳本叫訓練端算(2026-11-11，見「Part 11」)。答案腳本拿 `test_outputs.npz` 對 spike 數跟 FC 最後的 $\hat V$。
    - 樣本用 test 前 10 筆(量化資料夾 `eval/test.yaml` 記的評估取樣)。這台的 `data/datasets/N-MNIST/Train` 已經有了(60000 筆，2026-11-11 確認)，要用 val 的話照訓練端 `example/quantize.py` 的抽法重抽就有，目前不需要。

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

- 流程、參數、量測結果都在 [`SaltConvSynthFlow.md`](../Concept/Layer-RTL/SaltConvSynthFlow.md)：共用流程 `SaltNET/scripts/synth_common.tcl`；兩層串接 `synth_salt_conv_net.tcl`、整條網路 `synth_salt_conv_fc_net.tcl`、極限測試 `synth_salt_stress_net.tcl`(都在 `scripts/net/`)；比較做法時的單層量測見「比較做法時的量測(單層)」。
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
    - `conv → FC`：換成 $\text{src}=o_c\cdot H_{out}W_{out}+o_y\cdot W_{out}+o_x$，中間一個轉接模組 `fc/ConvToFCAdapter`，放在 FC 輸入 FIFO 寫入端之前，先存一級暫存器再換算，由 top 例化，`SaltConv`、FC 層都不改(2026-10-22 定，FC.md 第 1 節；2026-11-09 跟純組合邏輯比過，維持暫存器版)。
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
