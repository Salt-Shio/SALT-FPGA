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
| 3 | 權重 BRAM 讀取與 tap 選擇 | 第 2 節「權重」 | 完成 | `WeightMemory.sv`、`WeightTapSelect.sv`、`tb_weight_lookup.sv`、`sources_1/mem/` |
| 4 | 神經元 BRAM($\hat V,t_{last}$)介面，一讀一寫兩個埠 | 第 2 節「神經元」、5.2、5.3 | 完成 | `NeuronMemory.sv`、`NeuronMemoryClear.sv`、`tb_neuron_memory.sv` |
| 5 | LIF 膜電位更新 | 第 3 節 | 完成 | `NeuronUpdate.sv`、`tb_neuron_update.sv` |
| 6 | bitmask 優先權排序與輸出 | 第 4 節 | 完成 | `SpikeSelect.sv`、`tb_spike_select.sv` |
| 6.5 | Part 2 補輸出窗左上角的 bank(`top_row_bank`、`left_col_bank`)給 Part 6 用 | 第 4 節補充 | 完成 | `CandidateAxis.sv`、`CandidateGrid.sv` 跟它們的 testbench、答案腳本 |
| 7 | pipeline FSM 整合，先做無腦版(含只走 bitmask 的反壓) | 5.1、5.2、5.4 前半、5.6、5.7 | 完成 | `SaltConv.sv`、`tb_salt_conv.sv`(8.1 拆成 `tb_salt_conv_*`) |
| 8.1 | 管線化：算完那一拍直接從 $s$ 挑、直接送下一個 $o_c$ 的讀位址(含快路徑的反壓) | 5.3、5.4 後半 | 完成 | `SaltConv.sv`、`tb_salt_conv_common.svh`、`tb_salt_conv_ready_{high,random,burst,alternate}.sv` |
| 8.2 | 讀取延遲 $R$ 做成參數，$R=2$ 用 BRAM 輸出暫存器 | 5.5「實作」 | 實作、驗證完，待使用者 review | `SaltConv.sv`、`NeuronMemory.sv`、`NeuronMemoryArray.sv`(新)、`WeightMemory.sv`、`tb_salt_conv_common.svh`、`gen_salt_conv_ref.py`、`run_tb_salt_conv.tcl` |
| 8.x | 拆計算($C$)、$o_c$ 重疊 | 5.5、第 5 節開頭 | 下一步，待規劃 | |

## 下一步：Part 8.2 之後的管線優化(還沒開始，待規劃)

- **分支狀態(2026-10-18)**：Part 8.2 的改動都在分支 `part8-read-latency`(從 `test` 的 `5507967` 開出)，還沒合併回 `test`。
    - 使用者還沒 review 8.2，review 完才把進度表改成完成、決定要不要合併回 `test`。
    - 使用者要求這個任務不 commit 到 `test`；之後的工作要開新分支還是接在 `part8-read-latency` 上，先問使用者。
    - 跟 `test` 的差異：`git diff test..part8-read-latency`。
- 下一個 session 的重點。Part 8 一次只處理一個策略或一個機制，規劃時先列出這次要做哪一個、怎麼量、怎麼驗證，給使用者確認。
- **建議的順序**(2026-10-18 跟使用者討論過)：先做 $C=2$ 的草稿量測(只合成、不驗證，做法見「驗證流程 → 合成量測」)，看把計算切開後時脈能高到哪裡；數字出來再決定要不要規劃 $o_c$ 重疊。
- 比較的做法照 Part 8.1 開頭的「比較的做法」；速度、資源的基準是 Part 8.1「結果」跟 Part 8.2「結果」。
- 讀現行 RTL：`SaltConv.sv` 照事件流程分 0~6 段(檔頭有目錄)；資料流程圖、狀態圖在 `docs/SNN/Concept/Layer-RTL/Conv-image/SaltConvDataflow.md`、`SaltConvControl.md`。
- **Part 8.2 的結論**：只做 $R=2$ 不划算。一個沒有 fire 的 $o_c$ 從 1 拍變 2 拍，時脈只高 2~10%，整體比 $R=1$ 慢 1.8~2 倍。
    - $R=2$ 只拿掉 BRAM 讀出那段約 1 ns；最長路徑換成從事件暫存器出發，經過 `NeuronUpdate` → `SpikeSelect` → 推進的判斷，8.5~9.4 ns，長度幾乎不變。
    - $R$ 留著當參數(預設 1)，現在不用：單獨用時脈只多一點，連「系統時脈被別的模組定得比較高、這一層要跟上」也幫不上。
    - 可能有用的時機(推估，沒量過)：拆計算之後每一級變短(例如 4~5 ns)，BRAM 讀出那 1 ns 占的比例才大；而且要有 $o_c$ 重疊，多的那 1 拍才不會加在每個 $o_c$ 上。
- **拆計算($C$)**：把 `NeuronUpdate` 那串切開，才碰得到現在的最長路徑。
    - $o_c$ 不重疊時，多拆一級每個 $o_c$ 就多 1 拍(5.5 的 $\text{gap}=(R+C-2)+\max(1,k)$)：$C=2$ 的時脈要超過 8.1 的兩倍、$R=C=2$ 要超過三倍，才比只做 8.1 快。
    - 跟著的：乘法器 DSP 還是 LUT(切在 DSP 內部暫存器上結論可能反過來，見「合成後要確認」)；事件暫存器可能每一級各一份；$C$ 變成參數。
- **$o_c$ 重疊**(下一個 $o_c$ 先讀、前一個還在算)：Conv.md 第 5 節開頭決定 5.1~5.5 先不做。
    - 只在拆級能把時脈拉高很多時才有意義：重疊後拆出來的級數不再加到每個 $o_c$ 上。
    - 「已定案設計 → 目前不做」的理由(省固定 2~3 拍)只在 $R=C=1$ 成立；$R+C>2$ 時重疊每個 $o_c$ 省 $R+C-2$ 拍。
    - 改動比 $R$ 大很多，同一時間會有好幾個 $o_c$ 在不同的級裡：
        - 輸出要照 $o_c$ 順序送：前一個 $o_c$ 的 fire 還沒送完時，後面已經在算的 $o_c$ 要等。
        - 下游 `out_ready=0` 時，路上的幾個 $o_c$ 都要停住。
        - 讀寫衝突：$OC$ 比管線級數小時，下一筆事件的同一個 $o_c$ 可能在前一筆寫回前就讀，跟現在 $OC=1$ 的問題同一種，範圍變大。
- 8.1、8.2 留下的待討論事項：Part 8.1「之後討論與評估」、Part 8.2「之後討論」。

## Part 8.2 讀取延遲 $R$(實作、驗證完，待使用者 review)

在分支 `part8-read-latency` 上做(2026-10-18 使用者要求，不 commit 到 `test`)。

### 目標與範圍

- 把讀取延遲 $R$(送出讀位址到資料可用的拍數)做成參數 `READ_LATENCY`，預設 1，行為跟 8.1 相同。
- $R=2$ 用 BRAM 內建的輸出暫存器，不佔一般 FF；量 $R=2$ 換到多少時脈，當作之後拆計算、$o_c$ 重疊的依據。
- 只做 $R$，不拆計算($C=1$)，$o_c$ 不重疊。

### 改的是什麼

- **控制**(`SaltConv.sv`)：無腦版之後的 `compute_cycle` 暫存器換成 `read_delay_flags`，$R$ 個 bit 的移位暫存器。
    - 開始一個 $o_c$ 那拍最低位放進 1，每拍往高位推；同一時間最多一個 bit 是 1。
    - 最高位是 1 就是 `compute_cycle`(算的那一拍)；其他 bit 有 1 就是 `waiting_read`(等資料)，這些拍子 `oc_done` 一律 0，不推進。
    - $R=1$ 時 `waiting_read` 是常數 0(generate)，電路跟 8.1 相同。
    - 讀位址、候選、bitmask、送出的邏輯都沒改；等資料的拍子 bitmask 是空的，不送出、不寫回。
    - 一個 $o_c$ 占 $(R-1)+\max(1,k)$ 拍；$OC=1$ 是 $(R-1)+\max(2,k)$ 拍。
- **記憶體**：讀出的第一級是 BRAM 本身的讀出暫存器，$R=2$ 時多一級，併進 BRAM 的輸出暫存器(`DOB_REG`)。
    - `NeuronMemoryArray.sv`(新)：一個 bank 的陣列 + 讀出暫存器，模組加 `keep_hierarchy = "soft"`。
    - `NeuronMemory.sv`：只留清除邏輯，例化 `NeuronMemoryArray`。
    - `WeightMemory.sv`：讀出管線同樣做法，整個模組加 `keep_hierarchy = "soft"`(模組裡只有位址計算、陣列、讀出暫存器)。
    - 為什麼要 `soft`、為什麼不用 XPM，見下面「BRAM 輸出暫存器併不進去」。
- **答案腳本、testbench、模擬腳本**：
    - `gen_salt_conv_ref.py`：`READ_LATENCIES = (1, 2)`，拍數 $=\sum\max(1,k)+(R-1)(N-1)$，$N$ 是 (事件, $o_c$) 的個數；`sample` 行改成 `<in> <out> <state> <R=1 拍數> <R=2 拍數>`。
        - 第一個 $o_c$ 的等待在「算的那一拍」之前，量拍數時不算在內，所以是 $N-1$ 次。
        - 重新產生後跟舊答案檔比對：只有 `sample` 行變了，$R=1$ 的拍數跟原本相同。
    - `tb_salt_conv_common.svh`：參數 `READ_LATENCY` 傳給 DUT、印在總結行；`REF_READ_LATENCY_MAX = 2`，超出就 `$fatal`；照 `READ_LATENCY` 挑拍數。
    - `run_tb_salt_conv.tcl`：每組參數各跑 `READ_LATENCY` = 1、2(四支各 18 組)。
    - `tb_salt_conv_common.svh` 加「算的那一拍讀出值」檢查，由來見「反向測試」。

### 草稿量測：只做 $R=2$ 划不划算(2026-10-18)

- 條件跟 Part 7、8.1 相同(xck26，out-of-context，10 ns，輸入輸出延遲 0，布局繞線後，最高時脈用 slack 換算)。這時記憶體還是推斷寫法、沒加 `soft`。

| 設定 | $R=1$ | $R=2$ | 一個沒 fire 的 $o_c$：$R=1$ → $R=2$ | LUT | FF |
|---|---|---|---|---|---|
| conv1 $w$=12 繞回 | 106.3 MHz | 108.2 MHz | 9.4 → 18.5 ns | 577 → 553 | 125 → 238 |
| conv1 $w$=9 飽和 | 100.5 MHz | 104.7 MHz | 10.0 → 19.1 ns | 893 → 824 | 125 → 201 |
| conv2 $w$=14 繞回 | 105.2 MHz | 114.8 MHz | 9.5 → 17.4 ns | 579 → 564 | 117 → 238 |
| conv2 $w$=11 飽和 | 102.4 MHz | 112.5 MHz | 9.8 → 17.8 ns | 558 → 559 | 117 → 226 |

- $R=1$ 跟 8.1 正式版差 2 MHz 以內，FF 相同：改成參數後 $R=1$ 的電路就是 8.1。
- 最長路徑：$R=1$ 從 BRAM 讀出出發，9.2~9.8 ns；$R=2$ 換成從事件暫存器 `event_time` 出發($\Delta t=t-t_{last}$ 是 `NeuronUpdate` 第一步)，8.6~9.4 ns，22~23 層。
- FF 多 76~121 個：`NeuronMemory` 的輸出暫存器沒有併進 BRAM，見下一小節。
- 結論見「下一步」：只做 $R=2$ 不划算，$R$ 留著當參數。

### BRAM 輸出暫存器併不進去(2026-10-18 查到可控的做法，Vivado 內部原因不明)

- 現象：$R=2$ 合成報 `Synth 8-7052`(no optional output register could be merged)，`NeuronMemory` 4 個 bank 的輸出暫存器做成一般 FF；`WeightMemory` 有併入。
- 實際是兩件事混在一起：
    - 合成時沒併入(印 `Synth 8-7052`)。
    - 合成時有併入，布局時 `place_design` 的 BRAM register optimization 判斷搬出來時序比較好，搬到 FF(`Physopt 32-665 ... registers were pushed out`)。UG904 寫明是預設行為，時序改善才搬，不用處理。conv1 飽和版「4 個 bank 有 1 個併入、沒印 `Synth 8-7052`」就是這種。
- 實驗(conv1 繞回版，$R=2$，只跑合成)：

| 實驗 | 結果 |
|---|---|
| `NeuronMemory` 單獨合成 | 併入 |
| 單獨合成，加讀出 → 運算 → 寫回同一個 bank 的回授 | 併入 |
| `SaltConv` 整個不攤平(`-flatten_hierarchy none`) | 併入 |
| `SaltConv` 照常攤平，只在 `NeuronMemory` 加 `keep_hierarchy` | 併入 |
| `SaltConv` 照常攤平，一次改一條 `NeuronMemory` 的接線(讀取開關、清除、寫入資料、寫入開關) | 4 條都沒用，還是不併入 |
| 攤平跟 `keep_hierarchy` 兩份 log 的訊息種類、次數、BRAM/DSP 對映表 | 除了 `Synth 8-7052` 本身完全相同；`Synth 8-7052` 在 Technology Mapping 階段印出，沒有原因 |
| 攤平後的 netlist | BRAM 讀出腳扇出 1、FF 的 CE 接常數 1、`DOB_REG=0`；照 UG949 列的條件(多扇出、reset、回授)應該可以併入 |

- 結論：上層攤平時，跨模組的最佳化讓輸出暫存器併不進 BRAM；是哪一步最佳化、為什麼，log 跟官方文件都沒寫，查不到。
- 試過 XPM(`xpm_memory_sdpram`，`READ_LATENCY_B=2`，UG974 寫明 2 會用輸出暫存器)：4 組設定合成都併入，時脈、LUT 跟推斷版差不多。
    - 讀 `xpm_memory.sv`(Vivado 2025.2)：第二級暫存器的寫法跟我們的一樣(多的 reset、enable 接常數後相同)；差別在 `xpm_memory_sdpram`、`xpm_memory_base` 模組上帶 `KEEP_HIERARCHY = "SOFT"`。UG901：`SOFT` 只留常數傳遞，其他跨模組邊界的最佳化都擋掉。
    - 所以 XPM 會併入跟上面 `keep_hierarchy` 的實驗是同一個機制。
    - XPM 用起來的限制：記憶體至少 2 個字(`XPM_MEMORY 40-22`，每個 bank 1 格的人工參數組會報錯)；`MEMORY_INIT_FILE` 只能給檔名、不能帶路徑，檔案要加進專案(UG974)，跟我們每組參數用路徑指定權重檔、不同資料夾檔名重複的做法衝突；模擬在專案模式下會自動編譯 XPM 函式庫。
- **定案(2026-10-18 使用者決定)**：改回推斷寫法，照 XPM 的做法自己加 `keep_hierarchy = "soft"`，可控性比較好。
    - 第一版整個 `NeuronMemory` 加 `soft`：會併入，但清除邏輯不能跟外面一起最佳化，LUT 多 18~68 個($R=1$ 也多)。
    - 改成跟 XPM 一樣只框陣列和讀出暫存器(拆出 `NeuronMemoryArray`)：LUT 回到跟原本推斷版差不多。
    - `WeightMemory` 整個模組加 `soft`，LUT 沒有增加，不用拆。
    - 「推斷 + `soft` 一定會併入」沒有官方文件明寫，靠下面每組設定合成後檢查 `DOB_REG` 確認。`XPM_MODULE = "TRUE"` 這個屬性不在 UG901 清單裡，XPM 有沒有另外的特殊處理查不到，所以不說兩者完全等價。

#### 結果(正式版：推斷 + `NeuronMemoryArray` 加 `soft`)

| 設定 | 最高時脈 | 一個沒 fire 的 $o_c$ | LUT | FF | 合成後用到輸出暫存器 | 布局後還在 BRAM 裡 |
|---|---|---|---|---|---|---|
| conv1 $w$=12 繞回 $R=1$ | 106.0 MHz | 9.4 ns | 581 | 125 | —($R=1$ 不用) | — |
| conv1 $w$=12 繞回 $R=2$ | 105.3 MHz | 19.0 ns | 567 | 210 | 5 顆全部 | 神經元 1/4、權重 1/1(其他被布局搬出) |
| conv1 $w$=9 飽和 $R=2$ | 109.1 MHz | 18.3 ns | 793 | 176 | 5 顆全部 | 神經元 2/4、權重 1/1 |
| conv2 $w$=14 繞回 $R=2$ | 113.5 MHz | 17.6 ns | 564 | 118 | 5 顆全部 | 全部 |
| conv2 $w$=11 飽和 $R=2$ | 105.1 MHz | 19.0 ns | 559 | 118 | 5 顆全部 | 全部 |

- $R=2$ 4 組都沒有 `Synth 8-7052`；$R=1$ 照舊有(本來就沒有輸出暫存器可併)。
- $R=1$ 的最終版只重量了 conv1 繞回；另外三組 $R=1$ 是用加 `soft` 之前的草稿量的(跟 8.1 差 2 MHz 以內、FF 相同)，最終版沒重量。要拿 $R=1$ 當基準比較時先補量。
- 時脈跟推斷版、XPM 版差 4 MHz 以內，在布局繞線的變動範圍內；BRAM、DSP 不變。
- `-lint` 只有 Part 5 記錄過的 `ASSIGN-6`；hold 照舊 -0.18 ns(輸入 port 進 FIFO，out-of-context 輸入延遲 0 造成)。

### 驗證(2026-10-18)

- `tb_neuron_memory` 9 組 ALL PASS($R=1$)。
- `tb_salt_conv_ready_{high,random,burst,alternate}` 各 18 組(9 組參數 × $R$=1、2)ALL PASS，涵蓋項目都碰到。
    - $R=2$ 的輸出事件、神經元狀態比對筆數跟 $R=1$ 相同；`ready_high` 的 $R=2$ 拍數全部對上答案。
    - `read_check_count` = 事件數 × $OC$(例如 conv1 20000 × 8 = 160000)，每個 $o_c$ 算的那一拍都有檢查。

### 反向測試(5 組人工參數 × 四支，$R=2$；跑完 `git checkout` 還原，確認跟 commit 相同)

| 改壞的地方 | 結果 |
|---|---|
| 等資料的拍子照樣推進(`oc_done` 不看 `waiting_read`) | 四支 × 5 組全部 FAIL |
| 只有神經元記憶體 $R=2$，權重記憶體固定 $R=1$ | 四支 × 5 組全部 FAIL |
| 算的那一拍取錯位元(`compute_cycle` 取 `read_delay_flags[0]`，提早一拍算) | 加讀出值檢查之前：K=1、S=2、$OC=3$ 那組只有 `high` 靠拍數抓到(719 對 720)，`random`、`burst`、`alternate` 判 PASS；加了之後四支 × 5 組全部 FAIL |

- 第一輪 `random` 有 4 組報 `Spawn failed: %1 不是有效的 Win32 應用程式`(vivado-usage skill 8.7 記過的偶發錯誤)，重跑正常。
- **K=1 那組為什麼沒抓到**(用帶監看的 `ready_high` 副本確認，每個算的那一拍比對讀出值跟記憶體陣列裡的內容)：
    - 讀錯只發生在每筆樣本的第一個 $o_c$：層從空著開始時，前一拍沒有送讀位址，提早一拍讀到的是記憶體出口的舊值。其他時候前一拍已經送了同一個 $o_c$ 的讀位址(每拍都讀)，提早算也讀到對的值。
    - 第 0 筆樣本讀到 X：這組是飽和版，模擬器把 `if` 條件裡的 X 當成不成立，`NeuronUpdate` 的飽和判斷走到最後一個分支(最大正數)，一定 fire 並歸零，寫回確定的 0；那顆神經元清除後本來就是 0，剛好等於答案。實際硬體沒有 X，讀到的舊值會讓結果不確定。
    - 第 1~3 筆樣本讀到上一筆樣本留下的舊權重：那幾筆的第一筆事件座標是奇數，K=1、S=2 碰不到任何輸出神經元，讀錯的權重沒用到。
    - 監看結果：正確 RTL 兩組參數(K=1、K=3)都是 0 次不同；改壞的 RTL，K=1 那組神經元 1 次、權重 4 次，全部在樣本的第一個 $o_c$。
- **補上的檢查**(2026-10-18 使用者同意)：每個算的那一拍，`NeuronUpdate` 用到的 $(\hat V,t_{last})$ 要等於 `NeuronMemoryArray` 陣列裡候選位址那一格(只比合法候選)，權重寬字要等於權重 ROM 的 $(o_c,c)$ 那一格。
    - 每個 bank 一個 process 複製兩個值(generate 的 bank 只能用常數 index 取，跟神經元狀態快照同一種做法)，主流程在取樣的最後觸發、比對，不影響原本的取樣時間點。

### 之後討論

- **讀取開關每拍都開，還是推進那一拍才開**：Part 8.1 留下的，$R=2$ 時等資料的拍子也會白讀一次，一起評估。
- **攤平後輸出暫存器為什麼併不進 BRAM**：Vivado 內部原因查不到；現在靠 `soft` 加上每次合成檢查 `DOB_REG` 確認。換 Vivado 版本後要再確認一次。
- **權重記憶體要不要改 XPM**：要先解決 `MEMORY_INIT_FILE` 只能給檔名的問題(權重檔改成不重複的檔名、加進專案，訓練端匯出的命名可能也要改)，目前不做。

## Part 8.1 管線化(完成)

Part 8 拆成小 Part，一次只處理一個策略或一個機制(2026-10-15 跟使用者確認)。
後面的小 Part 等前一個做完、量過速度再規劃，見「Part 8.1 之後」。

**比較的做法(使用者 2026-10-15 指定)**：不要問使用者「目標時脈多少、$R$、$C$ 設多少」。
- 由 agent 量出每種做法的速度(最高時脈、每筆事件幾拍、每秒幾筆事件)跟成本(LUT、FF、BRAM、DSP，延遲多幾拍，設計跟驗證多複雜)。
- 整理成「做法 → 速度 → 成本」的表給使用者選。能合成量的就量，不要只估。Part 7 合成用的 10 ns 只是量測用，不是目標。
- 比較標準是「一個 $o_c$ 平均花多少時間」= 拍數 ÷ 時脈，因為一筆事件要依序跑完 $OC$ 個 $o_c$。
    - 大部分 $o_c$ 沒有 fire，比 $k=0$ 的就夠：Part 7 訓練端每組 conv1 有 2 萬筆事件 × 8 = 16 萬個(事件, $o_c$)，fire 約 2.55 萬個，至少 84% 是 $k=0$；conv2 至少 97%。
    - 無腦版 $k=0$ 是 2 拍，116 MHz 下 17.2 ns。
    - $k\ge2$ 時每多一個 fire 多 1 拍，是輸出埠一拍只能送一筆的上限，任何做法都一樣。

### 目標

- $k=0$、$k=1$ 的 $o_c$ 從 2 拍變 1 拍；$k\ge2$ 從 $1+k$ 拍變 $k$ 拍(5.3 的 $\max(1,k)$)。
- conv1 一筆沒有 fire 的事件從 17 拍變 9 拍，conv2 從 33 拍變 17 拍(都含開頭讀 $o_c=0$ 的 1 拍)。

### 改的是什麼(2026-10-15 跟使用者確認)

一個 $o_c$ 的動作：① 送讀位址、② BRAM 讀出、③ `NeuronUpdate` 算 $s$、$\hat V_{new}$、④ 寫回、⑤ `SpikeSelect` 挑一個送出、⑥ 判斷送完還有沒有剩、⑦ 沒剩就送下一個 $o_c$ 的讀位址。
第 1 拍是送讀位址那一拍，也是前一個 $o_c$ 的最後一拍。

| 動作 | 無腦版 | 管線化 |
|---|---|---|
| ① 送讀位址 | 第 1 拍 | 第 1 拍 |
| ②③④ 讀出、算、寫回 | 第 2 拍 | 第 2 拍 |
| $s$ 存進 bitmask | 第 2 拍，整份存 | 第 2 拍，只存送不完剩下的 |
| ⑤⑥⑦ 挑、判斷、送下一個讀位址 | 第 3 拍，從 bitmask 挑 | 第 2 拍，直接從 $s$ 挑 |

- 只搬 ⑤⑥⑦，從第 3 拍搬到第 2 拍；第 3 拍沒事做，下一個 $o_c$ 早 1 拍開始。
- 能搬的原因是挑的來源從 bitmask 換成剛算出的 $s$，挑、判斷、送讀位址的規則都不變。
- 挑的來源看「是不是算完那一拍」，不看 $k$：算完那一拍挑 $s$，之後清剩下的拍子挑 bitmask(5.3 改動二的二選一)。
    - $k\le1$：第 2 拍就沒剩，同拍送 ⑦。
    - $k\ge2$：第 2 拍送最小的，剩下的存進 bitmask，送完最後一個那拍才送 ⑦。
    - `out_ready=0`：第 2 拍不送，整份 $s$ 存進 bitmask(5.4 後半)，之後跟 $k\ge2$ 剩下的一樣處理。

### 已知問題 1：送讀位址那條路徑變長(還沒量)

⑦ 送不送由 $s$ 決定，原本分在兩拍的兩條路徑接成一條。

| | 起點 | 經過 | 終點 | 長度 |
|---|---|---|---|---|
| 無腦版第 2 拍 | BRAM 讀出 | ③ `NeuronUpdate` | ④ BRAM 寫入、bitmask | 8~8.9 ns(Part 7，現在最長) |
| 無腦版第 3 拍 | bitmask | ⑤ `SpikeSelect` → ⑥ → ⑦ 選讀位址 → `CandidateGrid` | BRAM 讀位址 | 約 4 ns(Part 7 量的是 `out_ready` 起點那條，後半段相同) |
| 管線化第 2 拍 | BRAM 讀出 | ③ → ⑤ → ⑥ → ⑦ → `CandidateGrid` | BRAM 讀位址 | 直接相加超過 12 ns，沒量過 |

- ④ 寫回那條不變。`SpikeSelect` 單獨量約 1 ns(Part 6)。
- 時脈掉多少就吃掉多少「2 拍變 1 拍」換來的速度，掉一半等於沒省。
- 5.5 的 $C$ 拆級拆不到這段：決定讀不讀在最後一級。
- **已定案(2026-10-15)**：下一個 $o_c$ 的位址不等推進的判斷，寫在 Conv.md 5.3「改動四」。
    - 下一個 $o_c$ 是誰只看 $o_c$ 計數器、事件暫存器、FIFO 最前面那筆，拍子一開始就知道，位址可以跟算膜電位同時算，鏈從「選讀位址」斷開。
    - 讀取開關每拍都開、還是推進那一拍才開，還沒定，見下面「之後討論與評估」。
    - 逐拍表檢查過 $k=2$、`out_ready=0`、換事件(FIFO 原本空、中途來事件)，都不會錯。
    - 要多一個 1 bit 暫存器記「上一拍有沒有推進」(這拍是不是算完那一拍)，擋寫回跟 `SpikeSelect` 的 $s$ 來源，取代無腦版 `state == PROCESS` 的角色。
    - 讀位址來源改用「計數器是不是最後一個 / 沒事做」選 FIFO 或事件暫存器，不用 `take_new_event`。
    - 候選暫存器、計數器、事件暫存器、FIFO 拿事件還是只在推進時換。
    - 剛 reset 完計數器要停在最後一個，或用「沒事做」讓讀位址指向 FIFO；現在 RTL 的計數器沒有 reset 值。
    - FIFO 空時讀出端是沒寫過的記憶體，模擬會是 X，靠「這拍不算」擋住；也可以用 FIFO 的 `rd_valid` 擋讀取省電(不用等 $s$)，實作時決定。
- **還剩兩條要等 $s$ 的路徑(還沒量)**：
    - 推進的判斷：讀出 → ③ → ⑤ → ⑥ → 候選、計數器、事件暫存器、「上一拍有沒有推進」的 enable。
    - 輸出埠：算完那一拍 `out_valid`、`out_x`、`out_y` 直接從 $s$ 經 `SpikeSelect` 出來，沒有暫存器，一路走到下一層 `EventFIFO` 的寫入端。

### 已知問題 2：$OC=1$ 的讀寫衝突(已定案)

- 管線化後讀下一個 $o_c$ 跟寫這個 $o_c$ 在同一拍；$OC=1$ 時下一個 $o_c$ 是下一筆事件的 $o_c=0$，可能是同一顆神經元，讀出值不保證。是管線化本身的問題，跟讀位址的做法無關。
- **已定案(2026-10-15)**：$OC=1$ 時算完那一拍一律不推進，下一拍才推進，$\text{gap}=\max(2,k)$；只在 $OC=1$ 時產生這段電路。寫在 Conv.md 5.3「$OC=1$」。
    - 不選「撞到才多等」(位址比較接進推進的判斷，路徑更長)、forwarding(二選一接在最長路徑上，拆級後每一級都要轉)。
    - 驗證：人工參數組 1×1、$OC=1$ 每筆事件都撞同一顆神經元。
        - 原本的資料抓不到：唯一的 $o_c$ 套了「最後一個 $o_c$ 門檻壓低、一定 fire」，每筆都 fire 歸零，膜電位永遠是 0，讀到舊值也一樣是 0(反向測試只有拍數錯，見「實作與驗證」)。
        - 答案腳本改成 $OC=1$ 時權重至少 1、門檻比單筆權重上限高，累積幾筆才 fire；改完反向測試四支 testbench 都抓到膜電位錯。

### 草稿量測：管線化划不划算(2026-10-15)

- 草稿只求能合成，沒有跑模擬驗證；放在 session 暫存目錄，不進 repo。
    - 照 Conv.md 5.3、5.4、改動四、$OC=1$ 寫；無腦版的三個狀態換成兩個暫存器：`active`(有 $o_c$ 在做)、`compute_now`(上一拍有推進)。
    - 草稿用一個參數切三種讀位址做法，比較位址、讀取開關各自要不要等推進的判斷：
        - 位址、讀取開關都等(Part 7 的寫法直接搬過來)。
        - 只有位址不等(來源只看計數器是不是最後一個、有沒有事件在做)。
        - 都不等，每拍都讀(Conv.md 目前的寫法)。
- 條件跟 Part 7 相同(xck26，out-of-context，10 ns，輸入輸出延遲 0，布局繞線後，最高時脈用 slack 換算)。無腦版重跑的 LUT、FF、時脈跟 Part 7 的表相同。
- 一個沒有 fire 的 $o_c$ 的時間：無腦版 2 拍、管線化 1 拍。

| 設定 | 無腦版 | 管線化：位址、讀取開關都等 | 管線化：只有位址不等 | 管線化：都不等 | 最後一欄比無腦版 |
|---|---|---|---|---|---|
| conv1 $w$=12 繞回 | 115.6 MHz，17.3 ns | 90.3 MHz，11.1 ns | 101.8 MHz，9.8 ns | 103.4 MHz，9.7 ns | 1.79 倍 |
| conv1 $w$=9 飽和 | 113.0 MHz，17.7 ns | 87.6 MHz，11.4 ns | 102.6 MHz，9.7 ns | 103.1 MHz，9.7 ns | 1.83 倍 |
| conv2 $w$=14 繞回 | 111.9 MHz，17.9 ns | 96.3 MHz，10.4 ns | 103.3 MHz，9.7 ns | 107.5 MHz，9.3 ns | 1.92 倍 |
| conv2 $w$=11 飽和 | 108.1 MHz，18.5 ns | 94.8 MHz，10.5 ns | 101.2 MHz，9.9 ns | 103.9 MHz，9.6 ns | 1.92 倍 |

- 換算成每秒能處理幾筆沒有 fire 的事件(連續處理，不算開頭 1 拍)：conv1 繞回 723 萬 → 1290 萬筆，conv2 繞回 350 萬 → 672 萬筆。
- 最長路徑：
    - 無腦版：讀出 → `NeuronUpdate` → 寫回，8.1~8.7 ns，17~19 層。
    - 位址、讀取開關都等：讀出 → … → `CandidateGrid` → BRAM 讀位址，9.9~10.8 ns，26~28 層，就是「已知問題 1」那條鏈。
    - 只有位址不等：讀出 → … → 推進的判斷 → BRAM 的 `read_enable`，9.1~9.3 ns，21~23 層。
    - 都不等：讀出 → … → 推進的判斷 → FIFO 讀指標、事件暫存器的 CE，9.1~9.5 ns，20~23 層。
    - 粗估(10~12 ns)比實測長，可能是 $s$ 比 $\hat V_{new}$ 早算好(後面還有 fire 歸零的選擇)，接在 $s$ 後面的那段跟寫回那條有一部分重疊；沒有逐段拆開確認。
- 輸出埠直接從 $s$ 出來的路徑：單層到輸出 port 8.0~8.8 ns；conv1 → conv2 串接(都不等，繞回版)，conv1 讀出 → conv2 `EventFIFO`(`full` 的 CE)8.99 ns，不是最長(最長是 conv2 自己的推進判斷 9.36 ns，104.8 MHz；串接的無腦版 107.8 MHz)。
- `out_ready` 起點：無腦版 3.9~4.6 ns，都不等的版本只剩 0.9~1.1 ns(讀位址不再接 `out_ready`)。
- 資源(都不等的版本)：LUT 584、934、576、556(無腦版 550、798、573、568)，FF、BRAM、DSP、CARRY8 都不變。conv1 飽和版多 136 LUT，原因沒查。
- `-lint`：只有 Part 5 記錄過的 `ASSIGN-6`。
- 結論：管線化划算，一個沒有 fire 的 $o_c$ 快 1.8~1.9 倍，時脈只掉 3~11%，FF、BRAM、DSP 不變。
    - 讓管線化變慢的是位址等判斷：位址改成不等，時脈多 7~15 MHz；讀取開關再改成不等，只多 0.5~4 MHz。
    - Conv.md 改動四原本寫「送不送要等 $s$，所以每拍都送才能斷開」，量測後改正(位址不等才是關鍵)。

### 之後討論與評估

- **讀取開關每拍都開，還是推進那一拍才開**(2026-10-15 使用者決定先記下來，之後討論)：
    - 每拍都開：讀取開關不用等推進的判斷，量起來稍快(時脈多 0.5~4 MHz，接近布局繞線的變動範圍)；卡住的拍子($k\ge2$、`out_ready=0`)會白讀記憶體，多耗電。
    - 推進才開：不會白讀；讀取開關接在推進的判斷後面，慢一點點。
    - 還沒評估：白讀的次數、多耗多少電。
- **testbench 重整**(2026-10-17 review 時討論)：`tb_salt_conv_common.svh` 的 `run_sample` 一個 task 把驅動、交握規則檢查、涵蓋統計、拍數、比對混在一起，看不出在測什麼。
    - 方向：共用可以(避免同一段檢查改四次)，但核心流程(餵資料、比輸出、比神經元狀態)要在一個地方看得完；涵蓋統計拆開，跟核心分開。
    - 不急著做，碰到要改 testbench 時一起處理。

### 實作與驗證(2026-10-15，使用者交代 2a~2d 一次做完，之後看 `SaltConv.sv` 理解)

- **RTL(`SaltConv.sv`)**：照草稿寫成正式版，草稿比較用的參數拿掉，註解補完整。
    - 無腦版的 IDLE / PROCESS / SENDING 換成兩個 1 bit 暫存器：`oc_in_progress`(有 $o_c$ 在做)、`compute_cycle`(這一拍讀出的是這個 $o_c$ 的資料：算、寫回、挑 $s$)。
    - `SpikeSelect` 的輸入 `pending` 是二選一：`compute_cycle` 時是 $s\land valid$，否則是 bitmask；bitmask 每拍存「這一拍做完剩下的」，`out_ready=0` 時就是整份。
    - 讀位址來源用 `next_from_fifo`(沒有 $o_c$ 在做，或這個 $o_c$ 是最後一個)選，只看暫存器；讀取開關 `read_enable` = 下一個 $o_c$ 有東西可做，每拍都讀(讀取開關待評估，見「之後討論與評估」)。
    - $OC=1$：`oc_done` 在 `compute_cycle` 那一拍強制 0，只在 $OC=1$ 時有這一項(常數比較，$OC\ge2$ 合成掉)。
    - 計數器、事件暫存器沒有 reset 值：沒有 $o_c$ 在做時讀位址一律指向 FIFO，不用計數器；bitmask 在沒有 $o_c$ 在做時存 0。
- **答案腳本(`gen_salt_conv_ref.py`)**：
    - 拍數改成 $\sum\max(1,k)$，$OC=1$ 時 $\sum\max(2,k)$；量法是第一個 $o_c$ 算的那一拍到最後一個 $o_c$ 送完那一拍。
    - 涵蓋行多一項 `stall_on_compute_cycle`(有 fire 就碰得到)：算的那一拍下游不收，是管線化新出現的情況(5.4 後半)。
    - 人工參數 $OC=1$ 改成累積幾筆才 fire(見「已知問題 2」的驗證)；$OC\ge2$ 的人工資料跟原本完全相同。
    - 重新產生答案檔：輸出事件、神經元狀態跟原本相同，只有拍數、涵蓋行變了(1×1、$OC=1$ 那組資料本身也變了)。
- **testbench 拆成四支**，共用的部分放 `tb_salt_conv_common.svh`(各支 `` `include ``)：讀答案、接 DUT、比輸出事件跟神經元狀態、每拍的交握規則檢查、涵蓋計數、總結行。每支只寫驅動方式(四個函式)跟要求哪些涵蓋。機制照舊：一個 `initial` 流程。
    - 涵蓋要求照「這支的驅動方式一定碰得到」分配，第一輪照舊版四種模式加總的要求分，random、burst、alternate 有參數組碰不到，調整成下表：

| testbench | 下游 `out_ready` | 上游 | 另外比 | 要求的涵蓋 |
|---|---|---|---|---|
| `ready_high` | 一直 1 | 一直送 | 拍數 | FIFO 滿擋上游、清除期間送事件 |
| `ready_random` | 每拍隨機 | 7 成機率送；每筆收走後 2 成機率等整層空下來 | — | 五種被擋的位置、`out_valid=0` 時不收、空下來再接事件、清除期間送事件 |
| `ready_burst` | 連續 0、連續 1 各 1~80 拍交替 | 7 成機率送，不等 | — | 被擋時是算的那一拍、還剩 2 個以上、$o_c$ 最後一個、事件最後一個且 FIFO 有下一筆；`out_valid=0` 時不收、FIFO 滿擋上游、清除期間送事件 |
| `ready_alternate` | 0、1 交替 | 一直送 | — | `out_valid=0` 時不收、FIFO 滿擋上游、清除期間送事件 |

- 涵蓋要求調整的理由：
    - 「事件最後一個且 FIFO 空」：要上游停下來。原本放 burst(等整層空下來)，但整層空下來多半在下游「收」的那一段，接著那一筆在同一段就做完，$OC=3$ 的兩組 0 次；改放 random(下游每拍隨機，空下來後那一筆最後一個 $o_c$ 一半機會被擋)。
    - 「FIFO 滿擋上游」：burst 原本每 5 筆左右就等空下來，人工參數組塞不滿；改要求一直送的 high、alternate，burst 拿掉等空下來之後也要求。
    - alternate 不要求被擋的位置：`out_ready` 固定交替，fire 落在哪一拍跟參數綁死，例如 $OC=1$ 一筆 2 拍，算的那一拍永遠是 `out_ready=1`。
- **模擬腳本(`run_tb_salt_conv.tcl`)**：舊的 `tb_salt_conv.sv` 跟模擬集 `sim_salt_conv` 刪掉，四支各一個模擬集 `sim_salt_conv_ready_*`。
    - 一個 Vivado session 只跑一個模擬集：同一個 session 依序跑第二個模擬集時，`launch_simulation` 沿用第一個的檔案清單(編譯到第一支 testbench，elaborate 找不到 top)。
        - 原始碼依據：`<Vivado>/data/XilinxTclStore/tclapp/xilinx/xsim/sim.tcl` 的 `setup` 收到內部旗標 `-int_setup_sim_vars` 時不重新初始化變數、`usf_xsim_setup_simulation` 不重新抓檔案清單；什麼時候帶這個旗標由 C++ 端決定，看不到。記在 vivado-usage skill 8.8。
        - 腳本改成：只給一支 testbench 時在這個 session 跑；沒給或給多支時，每支 `exec` 一個子 Vivado，log 寫 `SaltConv.sim/<testbench>.log`。

#### 結果

- 模擬：`run_tb_salt_conv.tcl` 四支 × 9 組全部 ALL PASS，輸出事件、神經元狀態 0 錯誤，要求的涵蓋全部碰到。
    - 每組比對筆數跟 Part 7 相同：訓練端 conv1 約 2.5 萬筆輸出、2.3 萬筆神經元狀態，conv2 約 1.2 萬筆、1.3 萬筆；1×1、$OC=1$ 那組資料改過，52 筆輸出。
    - `ready_high` 的拍數 9 組全部對上答案($\sum\max(1,k)$，$OC=1$ 是 $\sum\max(2,k)$)：conv1 一筆沒有 fire 的事件 8 拍、conv2 16 拍(不含開頭讀 $o_c=0$ 的 1 拍)。
- 反向測試(人工參數 5 組 × 四支，跑完 RTL、答案檔都還原，`cmp` 確認跟原本相同)：

| 改壞的地方 | 結果 | 沒抓到的組合，為什麼 |
|---|---|---|
| 算的那一拍下游不收，還是清掉挑出的那個 | random、burst 全 FAIL；alternate 4 組 FAIL | high 下游從不擋；alternate 的 $OC=1$ 算的那一拍永遠是 `out_ready=1` |
| 不是算的那一拍也寫回 | 4 組 × 四支 FAIL；$OC=1$ 在 random、burst FAIL | $OC=1$ 在 high、alternate 算完只多 1 拍：那一拍讀出的是同拍讀寫的舊值，重算結果跟算的那一拍相同，寫回同一個值；random、burst 下游擋住多停幾拍，讀到新值再算一次就錯 |
| $OC=1$ 算的那一拍照樣推進 | 1×1、$OC=1$ 那組四支都 FAIL(膜電位錯 31~36 筆)，其他組 PASS | 其他組 $OC\ge2$，這條規則不起作用 |
| 換事件時讀位址的 x 用事件暫存器 | 4 組 × 四支 FAIL | 1×1 輸入座標永遠是 0，分不出來 |
| 答案檔改一筆輸出的 $t$ | 只有那一組 FAIL，四支各 1 筆 | — |

- 1×1、$OC=1$ 資料改之前，「$OC=1$ 算的那一拍照樣推進」只有 high 報拍數錯。用帶監看的 testbench 副本確認：讀寫相撞 236 次、確實讀到舊值(例如 $t_{last}$ 讀到 5，正確是 6)，但寫回的膜電位每次都是 0，舊值新值一樣。模擬裡同一拍讀寫同一格讀到舊值，另用小 testbench 直接測過。
- 合成(正式版，條件跟草稿相同)：

| 設定 | 最高時脈 | 一個沒有 fire 的 $o_c$ | LUT | FF | BRAM tile | DSP | 最長路徑 |
|---|---|---|---|---|---|---|---|
| conv1 $w$=12 繞回 | 104.4 MHz | 9.6 ns | 591 | 125 | 5 | 4 | 推進判斷 → FIFO 讀指標 CE，9.39 ns，23 層 |
| conv1 $w$=9 飽和 | 102.3 MHz | 9.8 ns | 934 | 125 | 5 | 0 | 同上，9.58 ns，22 層 |
| conv2 $w$=14 繞回 | 105.3 MHz | 9.5 ns | 556 | 117 | 3 | 4 | 推進判斷 → 事件暫存器 CE，9.31 ns，23 層 |
| conv2 $w$=11 飽和 | 102.6 MHz | 9.7 ns | 574 | 117 | 3 | 4 | 推進判斷 → FIFO `full` CE，9.56 ns，23 層 |

- 跟草稿差 1~2 MHz，在布局繞線的變動範圍內；FF、BRAM、DSP、CARRY8 跟無腦版相同。
- conv1 → conv2 串接 102.6 MHz；conv1 讀出 → conv2 `EventFIFO` 寫入 8.99 ns，不是最長。
- `out_ready` 起點最長 1.05~1.09 ns(無腦版 3.9~4.6 ns)。
- `-lint` 只有 Part 5 記錄過的 `ASSIGN-6`；`Synth 8-7052`(BRAM 沒併入輸出暫存器)照舊，$R=1$ 本來就沒有輸出暫存器可併；$R=2$ 見 Part 8.2。
- review 後(2026-10-17)：`SaltConv.sv` 照事件流程重排成 0~6 段(只動位置不動邏輯，排序比對程式碼行 + 四支 × 9 組重跑 ALL PASS)；補資料流程圖、狀態圖(`Conv-image/SaltConvDataflow.md`、`SaltConvControl.md`)，舊的無腦版狀態圖 `SaltConvFSM.drawio/.svg` 刪掉。

### Conv.md 已經寫到的(不用重新討論)

| 項目 | 狀態 | 位置 |
|---|---|---|
| 管線化跟快路徑的反壓一起做 | 已定案：ready=0 時這一拍不送，整批 $s$ 存進 bitmask | 5.4 後半 |
| 讀 $o_c+1$、寫 $o_c$ 同一拍 | 已定案：simple dual port，Part 4 已做好 | 第 2 節「記憶體型態」、5.3 改動三 |
| 同一拍讀寫的是不同 $o_c$，位址一定不同 | 已確認($OC=1$ 除外，見問題 2) | 第 2 節「記憶體型態」 |
| 換事件時規則不變 | 已定案 | 5.6 |
| 讀位址不等推進的判斷、「上一拍有沒有推進」暫存器 | 2026-10-15 定案(讀取開關待評估) | 5.3 改動四 |
| $OC=1$ 算完那一拍一律不推進 | 2026-10-15 定案 | 5.3「$OC=1$」 |

## Part 7 pipeline FSM 整合，無腦版(完成)

把 Part 1~6 的模組接成完整的 `SaltConv`，加上指揮每一拍做什麼的狀態機。

### 範圍

- 規格：Conv.md 5.1、5.2(無腦版逐拍表)、5.4 前半(只走 bitmask 的反壓)、5.6(換事件)、5.7(狀態機)。
- 一個 $o_c$ 占 PROCESS 1 拍 $+$ SENDING $\max(1,k)$ 拍，$k$ 是這個 $o_c$ fire 的個數。
    - conv1($OC=8$)一筆完全沒有 fire 的事件是 $1+8\times2=17$ 拍；conv2($OC=16$)是 $1+16\times2=33$ 拍。
- Part 8 才做：5.3 管線化(算的當拍直接送)、5.4 後半(快路徑的反壓)、5.5 讀取延遲一般化。

### 已定案的事項(2026-10-12 跟使用者確認)

1. **狀態機直接寫在 `SaltConv` 裡**，不另開模組。
    - 狀態機單獨拿出來沒有訓練端的答案可以比，最後都是測整個 `SaltConv`，拆出去沒有換到更好測。
2. **三個狀態 IDLE、PROCESS、SENDING**：狀態表、轉移條件寫在 Conv.md 5.7(原本的圖 `SaltConvFSM.drawio/.svg` 在 8.1 之後刪掉，現行狀態圖見 `Conv-image/SaltConvControl.md`)。
    - IDLE：等事件；FIFO 空、神經元記憶體清除中都停在這裡。
    - PROCESS：讀出的資料就緒，$M\times M$ 份 `NeuronUpdate` 算，合法候選寫回，$s\land valid$ 存進 bitmask。下一拍一定是 SENDING。
    - SENDING：`SpikeSelect` 挑一個送出，`out_ready=1` 才清 bit；bitmask 會變空時同拍送下一個 $o_c$ 的讀位址。
    - 送讀位址不是獨立的狀態，在 IDLE 或 SENDING 的最後一拍順便做。
3. **正在處理的事件存在事件暫存器**(Conv.md 5.7「事件暫存器」)。
    - 原因：換事件那一拍同時要用兩筆事件，送出舊事件最後一個 fire 要舊事件的 $t$，讀位址要新事件的 $x,y,c$；`EventFIFO` 一次只看得到最前面那一筆。
    - 送 $o_c=0$ 讀位址的那一拍從 FIFO 拿出事件，拍子結束時存進暫存器；這一拍的讀位址直接用 FIFO 最前面那筆，$o_c\ge1$ 的讀位址、算、送出的 $t$ 都用暫存器。
    - 代價：多 $x,y,c,t$ 的位寬，`SaltConv` 預設位寬是 $9+9+4+16=38$ 個 FF，加讀位址來源的二選一；換事件不多花拍數，跟 5.6 一致。
    - 不選「事件留在 FIFO、做完才拿掉、換事件多等 1 拍」：每筆事件多 1 拍，跟 5.6 不一致；Part 8 管線化時前一筆還在算、下一筆已經在讀，一定要有這個暫存器。
4. **反壓：`out_ready` 直接接進狀態機**，`out_ready=0` 時 SENDING 停在原地，不清 bit、不換 $o_c$、不送讀位址、不從 FIFO 拿事件。
    - 不能不管 `out_ready` 直接送：下一層收不下，spike 就丟了，下一層的膜電位跟訓練端不再一致。
    - 層與層之間不用另外加 skid buffer：每一層輸入端的 `EventFIFO` 就是 16 格的 skid buffer。
        - FIFO 的 `wr_ready = !full`，`full` 是暫存器，不看後面的 Conv。
        - `full` 是「現在是不是滿了」的準確狀態，上游只在有空格的那一拍送得進來，不會被塞爆。
        - Conv 從 FIFO 拿事件的條件裡有 `out_ready`，下一層收不下就不拿；已經拿進來的存在事件暫存器、bitmask，停住時都不變。
        - 第 3 點要靠 FIFO 讀出端是 FWFT：最前面那筆一直擺在 `rd_data` 上，Conv 同一拍看 `out_ready`、同一拍決定拿不拿，真的拿走之前資料都留在 FIFO 裡。
        - 一般模式(這一拍 `rd_en`，下一拍資料才出來)：資料出來時已經離開 FIFO，Conv 那一拍收不下就要另外一格存，等於讀出端要再加 skid buffer；每筆事件也多 1 拍。
    - 所以 ready 的組合邏輯路徑只從下一層 FIFO 的 `full` 走到這一層的狀態機為止，串幾層都一樣長。這條路徑在 Part 8 量，見「合成後要確認」。
    - 反壓最後會傳到 EvtDecoder，感測器那端能忍多久是另一件事，見待決事項的 `FIFO_DEPTH`。
5. **讀寫不會撞同一顆神經元**(已確認)：寫回只在 PROCESS，送讀位址只在 IDLE、SENDING 的最後一拍，兩者不會同一拍。
    - 換事件時，下一筆事件 $o_c=0$ 的讀位址最早在上一筆最後一次寫回(PROCESS)的下一拍，讀到的已經是寫回之後的值。
    - Part 8 讓讀 $o_c+1$ 跟寫 $o_c$ 同拍之後，要再檢查一次(Conv.md 第 2 節「記憶體型態」)。

### 要接起來的模組，跟前面各 Part 留給 Part 7 的事

- **`EventFIFO`**：`in_ready` 是 FIFO 的 `wr_ready`，`NeuronMemoryClear` 的 `clearing` 期間再強制成 0(Conv.md 第 2 節「清除」)。
- **事件暫存器、$o_c$ 計數器**：$o_c$ 接 `CandidateGrid` 的 `out_channel`、`WeightMemory` 的位址。
- **`CandidateGrid`**：送讀位址那一拍算出的候選存進候選暫存器，PROCESS、SENDING 都用這一份，到下一次送讀位址才換(Conv.md 5.7「候選存起來」)。
    - 存的是每個 bank 的 `valid`、`bank_addr`、$(o_y,o_x)$、$(k_y,k_x)$，跟 `top_row_bank`、`left_col_bank`。
    - tap 跟權重寬字對齊用的暫存器就是這一組(Part 3 定案)。
- **`WeightMemory` + `WeightTapSelect`**：送讀位址那一拍送 $(o_c,c)$，PROCESS 那一拍用存起來的 tap 選權重碼。
- **`NeuronMemory`**：每個 bank 一份，跟 `NeuronUpdate` 放在同一個 generate 迴圈；`NeuronMemoryClear` 一層一份，`clearing`、`clear_addr` 接進每個 bank。
    - 送讀位址那一拍 `read_enable` 接候選的 `valid`；PROCESS 那一拍寫回，寫入位址是存起來的 `bank_addr`(`tb_neuron_memory` 已經這樣接)。
    - 只寫回合法候選：`NeuronUpdate` 對不合法的候選也照算(Part 5 定案)。
    - $t_{last,new}=t$ 直接從事件暫存器接寫埠。
- **`NeuronUpdate`**：generate 複製 $M\times M$ 份。
    - 門檻依 $o_c$ 選：`$readmemh(THRESHOLD_FILE)` 載入，合成成 mux(「已定案設計 → 門檻與衰減表」)。
    - 門檻檔($w=9$、$11$ bits)讀進來有沒有截斷警告，這時候確認(Part 5 留下的)。
- **`SpikeSelect`**：`pending` 是 bitmask，bitmask 在 PROCESS 存 $s\land valid$(Part 6 定案)。
    - `out_valid` = 狀態是 SENDING 而且 `found`；`out_x`、`out_y` 是 `selected_x`、`selected_y`，`out_channel` 是 $o_c$，`out_time` 是事件暫存器的 $t$。
    - 送出成功(`out_valid && out_ready`)才用 `selected` 清掉 bitmask 的那個 bit。
    - `out_valid` 不能用到 `out_ready`，不然兩層之間會繞成組合邏輯迴圈。

### 驗證的做法(2026-10-12 跟使用者確認)

- **答案**：`scripts/gen_salt_conv_ref.py`，兩份答案互相比對，一致才寫答案檔。
    - 官方：訓練端 `ConvLayer.forward` + `QuantBackend`(整層的整數掃描，輸出事件流照 `stream.py` 排序)。佇列容量不夠會截斷，這時放大到 `diag.needed` 再跑。
    - 逐筆迴圈：照硬體的做法一筆事件、一個 $o_c$ 算，候選用訓練端 `_axis_candidates`，更新用 `apply_decay_table_int` + `process_event`。官方答案沒有的 $t_{last}$、每個 (事件, $o_c$) 的 fire 數 $k$(算拍數)從這裡來。
    - 訓練端的 `v_final` 多做了一步 catch-up：每顆神經元再衰減到樣本最後一筆事件的時間(權重 0)。硬體不做，所以 testbench 比 catch-up 之前的 $\hat V$；逐筆迴圈補上 catch-up 之後要等於官方的 `v_final`。
- **參數組**：
    - 訓練端 conv1、conv2 × 繞回、飽和 4 組，輸入是 test 的前 10 筆(量化資料夾 `eval/test.yaml` 記的評估取樣)；conv2 的輸入是訓練端 conv1 的輸出。
        - 每層 spike 數跟 `eval/test_outputs.npz` 比對；匯出的權重、門檻、衰減表檔跟 `model.npz` 比對。
        - 原本要用 val(跟 `reference.npz` 比)，這台機器只有 N-MNIST 的 `Test`，val 要從 `Train` 切，改用 test。
    - 人工 5 組：$M=1$($K=1,S=2$)；$M=3$($C$、$OC$ 不是 2 的次方，`FIFO_DEPTH=4`)；$K=5,S=2$($M=3$，$f_V=2$)；$M=4$(`FIFO_DEPTH=2`)；1×1 輸出、$OC=1$。`ROUND`、`SATURATE` 四種組合分散在各組。
        - 門檻大多壓低(同一個 $o_c$ 常有多個 fire)，最後一個 $o_c$ 權重取絕對值、門檻壓低(一定會 fire，換事件那一拍被擋住的情況才碰得到)。
- **testbench `tb_salt_conv.sv`**：每筆樣本用四種模式各跑一次，中間 `rst_n` 重來。
    - A：`out_ready` 一直是 1、輸入一直有，另外比拍數(第一個 PROCESS 到最後一個 SENDING 要等於 $\sum(1+\max(1,k))$，中間回 IDLE 多一拍也會被抓到)。
    - B：`out_ready` 每拍隨機、輸入隨機斷。
    - C：`out_ready` 隨機長度的連續 0、連續 1 交替(最長 80 拍，超過 FIFO 深度)；輸入隨機斷，偶爾等 SaltConv 整個空下來再送。
    - D：`out_ready` 每拍 0、1 交替、輸入一直有。
    - 四種模式都比：輸出事件逐筆照順序；樣本結束時每顆神經元的 $(\hat V,t_{last})$，直接從 `NeuronMemory` 的記憶體內容讀出來。
    - 每一拍檢查的協定規則：送不出去時下一拍 `out_valid` 還是 1、資料不變；同一拍改 `out_ready`，`out_valid` 不能跟著變；清除期間 `in_ready=0`、FIFO 沒收進事件；`out_valid`、`in_ready` 不是 X。上游清除期間也會拉高 `in_valid`。
    - 涵蓋率 8 項，要求的項目 0 次就 FAIL：下游不收的四種情況(這個 $o_c$ 還剩 2 個以上、$o_c$ 的最後一個、事件的最後一個且 FIFO 有下一筆、事件的最後一個且 FIFO 空)，加上 `out_valid=0` 時不收、FIFO 滿擋住上游、樣本中途回 IDLE 再接事件、清除期間送事件。
        - 前四項碰不碰得到由答案檔的 `coverage` 行決定(看 fire 分布)：$M=1$ 每個 $o_c$ 最多 1 個 fire、1×1 輸出只有 1 個 $o_c$，碰不到的那幾項不要求。
- **檔案**：`SaltConv.sv`、`tb_salt_conv.sv`、`scripts/gen_salt_conv_ref.py`、`scripts/run_tb_salt_conv.tcl`、`sim_1/new/ref/salt_conv_*`(答案檔、人工參數組的資料檔)。

### 結果

- 答案腳本：9 組的逐筆迴圈都跟官方整層 forward 逐位元一致(輸出事件序列、catch-up 之後的 $\hat V$)；訓練端 4 組的 spike 數跟 `eval/test_outputs.npz` 相同，匯出檔跟 `model.npz` 相同。
    - 訓練端每組 10 筆樣本：conv1 共 20000 筆事件、約 25500 個 fire；conv2 約 25500 筆事件、約 12000 個 fire。同一個 (事件, $o_c$) 最多 2 個 fire；人工參數組最多 15 個($M=4$)。
- 模擬：`run_tb_salt_conv.tcl` 9 組全部 ALL PASS，涵蓋率要求的項目全部有發生。
    - 訓練端 conv1 每組比對約 10 萬筆輸出事件、9 萬筆神經元狀態；conv2 約 4.8 萬筆、5.2 萬筆。
    - xsim 不支援 `$urandom(seed)`，用預設種子；連跑兩次涵蓋率的數字完全相同，亂數是固定的。
    - 門檻檔($w=9$、$11$ bits)模擬、合成都沒有截斷警告(Part 5 留下的)。
- 反向測試(人工參數 5 組，跑完 RTL、答案檔都還原)：
    - SENDING 不看 `out_ready`，照樣清 bit：5 組 FAIL；模式 A 沒錯，錯在 B 之後，協定檢查也抓到「上一拍送不出去，這一拍 `out_valid=0`」。
    - 換事件那一拍讀位址用事件暫存器：5 組 FAIL，模式 A 就錯。
    - bitmask 不跟 `valid` 做 AND：5 組 FAIL。
    - 不合法的候選也寫回：4 組 FAIL；1×1 那組 PASS，它的候選永遠合法，本來就分不出來。
    - 答案檔改一個輸出座標：只有那一組 FAIL，四種模式各報 1 筆。
- `EventFIFO` 的修正(Part 1 的模組，整合合成時才發現)：
    - 資料陣列 `mem` 原本寫在有非同步 reset 的 `always_ff` 裡，合成報 `Synth 8-7137`(Set、reset 同優先)，推不出 distributed RAM，16 格 × 29 bits 全部變成暫存器(conv1 589 個 FF 裡約 464 個)。
    - `mem` 的寫入移到沒有 reset 的 `always_ff`；reset 期間就算寫進去，`w`、`r`、`empty` 都被 reset，讀不到，介面行為不變。
    - 改完 `tb_event_fifo` ALL PASS(540 筆)，`tb_salt_conv` 9 組重跑 ALL PASS；合成變成 18 個 LUT 當記憶體，FF 降到 121~129 個。
    - 依據：UG949「Memory arrays should not be reset」、非同步 reset 會讓暫存器推不進 RAM primitive；UG901 Coding Guidelines「Do not asynchronously set or reset registers」。
        - 「保持原值」為什麼被做成同時有 set、reset 的暫存器，官方文件沒寫工具內部的做法，查不到確定的說明。
    - 另外照 `WeightMemory`、`NeuronMemory` 的做法，`mem` 加上 `(* ram_style = "distributed" *)`(UG912 RAM_STYLE：「infer distributed LUT RAMs」)，資源類型寫明，不交給 Vivado 依大小判斷。
        - 2026-10-13 跟 `NeuronMemory` 拆分一起重跑模擬、合成：一樣是 18 個 LUT 當記憶體，FF 少 4 個(見下面合成表)。
        - 少的是有非同步 reset 的 FF(FDCE 25→21)，RTL 統計少一個 4-bit 暫存器。用不加屬性的 `EventFIFO` 副本配新的 `NeuronMemory` 合成 conv1 繞回版，FF 回到 129，所以是屬性造成的，不是 `NeuronMemory` 拆分。少的是哪個暫存器、為什麼，沒有查到。
- out-of-context 合成(xck26，non-project，包裝 module 寫死參數；10 ns 時脈，輸入輸出延遲設 0，布局繞線後)。2026-10-13 `NeuronMemory` 拆成單一 bank、`EventFIFO` 加 `ram_style` 之後重跑：

| 設定 | LUT(其中當記憶體) | FF | CARRY8 | BRAM | DSP | 最長路徑 | 最高時脈 | `out_ready` 起點最長 |
|---|---|---|---|---|---|---|---|---|
| conv1 $w$=12 繞回 | 550(18) | 125 | 20 | 5 個 RAMB36 | 4 | 8.14 ns，17 層 | 116 MHz | 4.62 ns，8 層 LUT |
| conv1 $w$=9 飽和 | 798(18) | 125 | 44 | 5 個 RAMB36 | 0 | 8.36 ns，19 層 | 113 MHz | 4.60 ns，8 層 LUT |
| conv2 $w$=14 繞回 | 573(18) | 117 | 20 | 1 個 RAMB36 + 4 個 RAMB18 | 4 | 8.36 ns，17 層 | 112 MHz | 3.97 ns，7 層 LUT |
| conv2 $w$=11 飽和 | 568(18) | 117 | 20 | 1 個 RAMB36 + 4 個 RAMB18 | 4 | 8.68 ns，19 層 | 108 MHz | 3.91 ns，7 層 LUT |

- 改之前(2026-10-12)：LUT 556、799、573、566，FF 129、129、121、121，最高時脈 116、107、113、109 MHz，`out_ready` 起點 4.08、4.63、3.93、3.79 ns；BRAM、DSP、CARRY8 相同。時脈、路徑長度的差別在布局繞線的變動範圍內，資源只差上面 `ram_style` 的 4 個 FF 跟幾個 LUT。

- 合成的觀察：
    - 最長路徑都是 `NeuronMemory` 讀出 → `NeuronUpdate` → 寫回同一個 bank，約 8~8.9 ns；最高時脈是用 10 ns 的 slack 換算的。Part 8 拆管線從這裡下手。
    - conv1 $w$=9 的乘法做成 LUT(0 DSP、LUT 多約 240)，跟 Part 5 單獨合成時一樣，是 Vivado 依位寬自己選的(見「合成後要確認」的乘法器)。
    - `-lint`：每組 1~2 個 `ASSIGN-6`，都是 Part 5 記錄過、刻意丟掉的高位(`shifted_product`、`unfitted`)。
    - hold 檢查有 30 個端點不過(-0.18 ns)，起點全部是輸入 port 進 FIFO 的資料陣列：out-of-context 把輸入延遲設成 0 造成的，實際接上一層時訊號從暫存器出來，有 clock-to-Q 的延遲。

### code review 要改的地方

`SaltConv.sv` 的 review 在 2026-10-13 走完；testbench、答案腳本還沒 review。
另外三條 reviewer 註解(第 86 行 `out_valid`、第 161 行預設值放 default、第 387 行 `oc_done` 的寫法)討論後不改，註解已拿掉。

1. **`NeuronMemory` 改成單一 bank，跟 `NeuronUpdate` 放進同一個 genvar 迴圈**(2026-10-13 使用者提出，已改完，等使用者確認)。
    - 目的：一個 bank 的讀 → 算 → 寫回寫在同一個地方；`memory_read_enable`、`memory_membrane`、`memory_last_time`、`memory_write_enable`、`memory_write_time` 這幾個二維陣列拿掉，改成迴圈內的區域訊號。行為不變。
    - 清除計數器只有一份，接進每個 bank。拆成獨立的小模組 `NeuronMemoryClear`(做法 A1)，`SaltConv` 例化一份。
        - 不直接寫在 `SaltConv` 裡(A2)：`tb_neuron_memory` 沒有 `SaltConv`，測不到計數器「剛好清 `BANK_DEPTH` 拍」；拆成模組之後 Part 4 的檢查、答案檔原封不動繼續用。
        - 不選每個 bank 各留一份計數器：$M\times M$ 份一樣的計數器，`clearing` 也有 $M\times M$ 個要挑一個接給 `in_ready`。
    - `NeuronMemory`、`NeuronMemoryClear` 的參數直接收 `BANK_DEPTH`，單一 bank 不用知道層的形狀。
    - 改的檔案：`NeuronMemory.sv`、`NeuronMemoryClear.sv`(新)、`SaltConv.sv`、`tb_neuron_memory.sv`(一份計數器 + generate $M\times M$ 個 bank)、`tb_salt_conv.sv`(快照路徑改成 `dut.row_banks[r].col_banks[c].neuron_memory.bank`)、`run_tb_neuron_memory.tcl`(第一次跑時把 `NeuronMemoryClear.sv` 加進 sources_1)、TODO Part 4。答案腳本、答案檔沒動。
    - 結果：`run_tb_neuron_memory.tcl` 9 組 ALL PASS；`run_tb_salt_conv.tcl` 9 組 ALL PASS，比對筆數跟改之前相同；合成見上面的表。
        - `run_tb_salt_conv.tcl` 第一次跑時，第 1 組 elaborate 報 `Spawn failed: %1 不是有效的 Win32 應用程式`(compile 有過)，原封不動重跑就正常，原因不明，記在 vivado-usage skill 8.7。

## Part 6 bitmask 優先權排序與輸出(完成)

規格在 Conv.md 第 4 節：同一拍同一個 $o_c$ 有 0~$M\times M$ 顆 fire，每拍在還沒送的裡面挑 $(o_y,o_x)$ 最小的送出。

接 Part 2、Part 5 的地方：每個 bank 的 `NeuronUpdate` 的 `spike`($s$)、`CandidateGrid` 的 `valid`、`out_y`、`out_x`($o_y,o_x$)。

送出順序跟訓練端一致：`model_operation_quant.md` 第 5 節規定同一筆事件的多個 fire 照神經元編號 $o_c\cdot H_{out}W_{out}+o_y\cdot W_{out}+o_x$ 由小到大(訓練端 `salt_core/stream.py` 的 lexsort)。
硬體外層依序跑 $o_c$，每個 $o_c$ 內比 $(o_y,o_x)$，順序相同。
同一拍不同 bank 的 $(o_y,o_x)$ mod $M$ 不同，不會平手。

定案的事項(2026-10-11 跟使用者確認)：

1. **模組範圍**：Part 6 只做純組合邏輯的選擇器，bitmask 暫存器、`out_valid/out_ready` 交握、$o_c$、$t$ 放 Part 7。
    - 暫存器什麼時候存、存什麼，無腦版跟 5.3、5.4 不同，放在 FSM 那邊，Part 8 改管線時不用改選擇器介面。
2. **`valid`**：選擇器只收一條待送 mask `pending`，$s\land valid$ 由上層做。
    - Part 5 定了不合法的候選照算，所以這個 AND 一定要有；暫存器存的已經是濾過的值，選擇器再收 `valid` 是重複的。
3. **找最小的電路**：兩種都做、比較合成結果後，定案用旋轉法(2026-10-11)，比較鍵法的檔案已刪。
    - 比較鍵法(Conv.md 第 4 節現在的寫法)：$key_j=\{\overline{pending_j},o_y,o_x\}$，兩兩比較的樹狀結構取最小。
    - 旋轉法：
        - 窗：一筆事件在一個 $o_c$ 的候選，在輸出面上框住 $M\times M$ 格(每軸連續 $M$ 個座標)，每一格各在不同的 bank。
        - $(o_y,o_x)$ 由小到大，就是把窗由左上往右下讀。
        - 窗裡第 $k$ 列(最上面是第 0 列)的 bank 列編號是 $(\texttt{top\_row\_bank}+k)\bmod M$，行同理；`top_row_bank`、`left_col_bank` 是窗左上角那格的 bank。
        - 照這個順序做優先權編碼器，第一個 `pending=1` 的就是答案，不比座標。
        - 窗左上角的 bank 由 Part 6.5 從 `CandidateAxis`、`CandidateGrid` 接出來；比較階段還沒有時由答案檔提供。
4. **port**：
    - 輸入 `pending[r_y][r_x]`、`out_y`、`out_x`(沿用 `CandidateGrid` 的 unpacked array)、`top_row_bank`、`left_col_bank`。
    - 輸出 `found`(有沒有東西可送)、`selected[r_y][r_x]`(one-hot，上層用它清 bit，`found=0` 時全 0)、`selected_y`、`selected_x`。
5. **驗證**：
    - 答案用訓練端的候選規則(`axis_candidate_lists`)產生真實的 $(o_y,o_x)$，照神經元編號排序。
    - 每個有候選的 $(y,x)$，合法 bank 的子集合當 `pending`，$2^n\le512$ 時窮舉，否則抽樣；不合法 bank 的座標填亂數，不能被選到。
    - testbench 每拍比對 `found`、`selected`、座標，清掉答案的那個 bit 再比下一個，直到全 0。
    - 參數：conv1、conv2($M=2$)，人工 $M=1$($S>K$)、$M=3$、$M=4$、1×1 輸出；兩種寫法跑同一份答案。
    - 反向測試；out-of-context 合成兩種寫法，加暫存器包一層量布局繞線後的路徑延遲。
6. **檔案**：`SpikeSelect.sv`(旋轉法)、`tb_spike_select.sv`、`scripts/gen_spike_select_ref.py`、`scripts/run_tb_spike_select.tcl`。
    - 比較階段旋轉法叫 `SpikeSelectRotate.sv`、比較鍵法叫 `SpikeSelect.sv`；定案後刪掉比較鍵法，旋轉法改名成 `SpikeSelect`，port `first_row_bank`、`first_col_bank` 改名 `top_row_bank`、`left_col_bank`，testbench 拿掉 `USE_ROTATION`。

文件：Conv.md 第 4 節「補充：怎麼用電路做」已改成旋轉法(窗、由左上往右下讀、窗左上角推出讀的順序、優先權編碼器)；5.3 原本說「比較器」「比較邏輯」的地方改成「優先權編碼器」。

定案後重跑(改名之後)：

- 答案檔重新產生，跟改名前逐位元相同(只改名稱)。
- `run_tb_spike_select.tcl` 8 組全部 ALL PASS，elaborate 只有已知的 `VRFC 10-3532`。
- `-lint` 4 組(conv1、conv2、$M=3$、$M=4$)0 個訊息；LUT 17、15、84、147，跟下表旋轉法相同。

比較階段的結果：

- 模擬：`run_tb_spike_select.tcl` 跑 8 組參數 × 兩種寫法共 16 組，全部 ALL PASS。
    - 參數：conv1、conv2($M=2$)；$M=3$ 13×11、$M=3$ 64×64(座標 6 bits)；$M=4$；$M=3$ 且 $S>1$；$M=1$($S>K$)；1×1 輸出。
    - 答案腳本對每個事件座標確認「照窗由上往下(由左往右)的順序」跟「依座標排」順序相同(旋轉法的前提)，8 組都成立。
    - 答案檔共約 9 MB，最大的是 $M=3$ 64×64 約 5 MB。
    - elaborate 只有已知的 `VRFC 10-3532`(`glbl` 沒有這些參數)。
- 反向測試(conv1、$M=3$ 13×11 兩組，跑完 RTL、答案檔都還原)：
    - 比較鍵法 key 最高位不取反：兩組 FAIL(沒亮的 bank 座標填 0 會贏)。
    - 比較鍵法先比 $o_x$ 再比 $o_y$：兩組 FAIL。
    - 旋轉法 y 軸不看窗左上角的列編號(當時叫 `first_row_bank`)、一律從 bank 0 開始：兩組 FAIL。
    - 旋轉法改成 column-major 掃：兩組 FAIL。
    - conv1 答案檔一個 case 的送出順序對調：那一組報 3 筆 `MISMATCH`、FAIL，另一組 PASS。
- 合成比較(xck26，non-project，out-of-context；LUT 是模組單獨合成，延遲是輸入輸出各包一層暫存器、布局繞線後用 2 ns 時脈的 slack 換算)：
    - `-lint` 8 組都是 0 個訊息。

| 設定 | 寫法 | LUT | CARRY8 | 路徑延遲 | 邏輯 / 繞線 | 邏輯層數 |
|---|---|---|---|---|---|---|
| conv1($M=2$，17×17) | 比較鍵法 | 55 | 3 | 1.98 ns | 0.98 / 1.00 ns | 6 |
| | 旋轉法 | 17 | 0 | 1.05 ns | 0.45 / 0.59 ns | 2 |
| conv2($M=2$，9×9) | 比較鍵法 | 46 | 3 | 2.02 ns | 1.11 / 0.90 ns | 6 |
| | 旋轉法 | 15 | 0 | 0.99 ns | 0.47 / 0.52 ns | 2 |
| $M=3$，64×64 | 比較鍵法 | 183 | 9 | 4.46 ns | 2.17 / 2.12 ns | 12 |
| | 旋轉法 | 84 | 0 | 1.66 ns | 0.65 / 1.02 ns | 3 |
| $M=4$，64×64 | 比較鍵法 | 386 | 18 | 4.84 ns | 2.43 / 2.25 ns | 13 |
| | 旋轉法 | 147 | 0 | 3.09 ns | 1.28 / 1.81 ns | 9 |

- 合成的觀察：
    - 旋轉法每組都比較少、比較快：LUT 約 1/3~1/2，延遲約一半，不用 CARRY8。
    - 比較鍵法的成本隨座標位寬、bank 數一起長：每一層比較器都是 $1+$`OUT_Y_WIDTH`$+$`OUT_X_WIDTH` 位元的大小比較(走 CARRY8)。旋轉法只看 `pending` 跟 $\log_2 M$ 位元的起點，座標只經過最後的多工器。
    - 旋轉法 $M=4$ 的最長路徑是 `pending` → `selected`(9 層)：16 個 bank 依名次逐一判斷 `!found` 的優先權鏈。實際的 conv1、conv2 是 $M=2$，用不到。
    - 旋轉法的代價不在這個模組：起點 bank 要從 `CandidateAxis` 輸出($m_{max}$ 已經有，多一個 +1 mod $M$)，Part 7 的管線暫存器每軸多存 $\log_2 M$ 位元。

## Part 6.5 Part 2 補輸出窗左上角的 bank(完成)

目的：`SpikeSelect` 要的 `top_row_bank`、`left_col_bank` 現在沒有模組輸出，由 Part 2 補上。
算法見 Conv.md 第 4 節補充「窗左上角的 bank 從哪裡來」：每一軸是 $(m_{max}+1)\bmod M$，`CandidateAxis` 已經算出 $m_{max}$(`max_bank`)。

要做的事：

1. **`CandidateAxis`**：多一個輸出，值是 $(m_{max}+1)\bmod M$，位寬 $\lceil\log_2 M\rceil$(至少 1 bit)。
    - 只看事件座標，跟有沒有合法候選無關，一律有值。
2. **`CandidateGrid`**：y 軸那個接出來當 `top_row_bank`，x 軸那個接出來當 `left_col_bank`，各一個值，不是每個 bank 一份。
3. **驗證 `CandidateAxis`**：`gen_candidate_axis_ref.py`、`tb_candidate_axis.sv` 每行多一個欄位，`run_tb_candidate_axis.tcl` 重跑全部參數。
4. **驗證 `CandidateGrid`**：`gen_candidate_grid_ref.py`、`tb_candidate_grid.sv` 每行多兩個欄位，`run_tb_candidate_grid.tcl` 重跑全部參數。
5. **其他例化 `CandidateGrid` 的地方**：`tb_neuron_memory.sv` 不用新輸出，port 留著不接；重跑 `run_tb_neuron_memory.tcl` 確認沒受影響。
6. **答案腳本共用同一個函式**：$(m_{max}+1)\bmod M$ 現在寫在 `gen_spike_select_ref.py` 的 `window_start_bank`，改成放在一個地方，其他腳本 import，不複製。
7. **反向測試**：輸出改成 $m_{max}$(少加 1)，`CandidateAxis`、`CandidateGrid` 都要 FAIL。
8. **合成**：out-of-context 合成 conv1、conv2 參數的 `CandidateGrid`，`-lint`，LUT 跟改之前比。
9. **文件**：TODO「已定案設計 → 候選計算」的輸出欄位清單補上這個值。

定案的事項(2026-10-11 跟使用者確認)：

- **port 名稱**：`CandidateAxis` 用 `min_bank`，跟內部的 `max_bank` 成對；`CandidateGrid` 用 `top_row_bank`、`left_col_bank`，跟 `SpikeSelect` 相同。
    - `max_bank` 是窗最大座標 $o_{max}$ 的 bank，`min_bank` 是窗最小座標 $o_{max}-(M-1)$ 的 bank，$=(\texttt{max\_bank}+1)\bmod M$。
    - 註解要寫明：不是 Conv.md 第 2 節 $o_{min}$ 的 bank。
        - $K$ 不是 $S$ 的倍數時，有些 $i$ 只被 $M-1$ 個輸出蓋到，$o_{min}$ 比窗最小大 1。例如 conv1 $i=4$：窗是 $o=1、2$，$o_{min}=2$。
        - $o_{min}$ 在 RTL 裡沒有算，也沒有變數存它。
    - 不用 `valid_min_bank`：窗最小那格常常不合法(例如上面的 $o=1$、靠影像上緣的負座標)，名字會說反。

- **答案從哪裡來**：Python 產生。訓練端沒有「窗」這個概念，沒有現成函式可以直接算出這個值。
    - 答案用公式 $(\lfloor(i+P)/S\rfloor+1)\bmod M$ 算；同時用訓練端 `_axis_candidates` 的合法候選檢查「從這個 bank 往後循環的順序 = 座標由小到大」，兩邊一致才寫答案。
- **`tb_spike_select` 改成例化 RTL 的 `CandidateGrid`**：
    - `top_row_bank`、`left_col_bank`、`out_y`、`out_x` 由 `CandidateGrid` 依事件座標算出來接進 `SpikeSelect`(`tb_neuron_memory` 也是這樣做)，一起測到兩個模組的編號規則接得起來。
    - 答案檔的值留著，跟 `CandidateGrid` 算出來的互相比對。

結果：

- 檔案：
    - RTL：`CandidateAxis.sv` 多 `min_bank`，`BANK_INDEX_WIDTH` 從模組內部移到參數區，port 才能用；`CandidateGrid.sv` 多 `top_row_bank`、`left_col_bank`。
    - 答案腳本：`gen_candidate_axis_ref.py` 新增 `axis_min_bank`(公式)、`check_min_bank_order`(拿訓練端的合法候選檢查順序)，`gen_candidate_grid_ref.py`、`gen_spike_select_ref.py` 都 import 這兩個；`gen_spike_select_ref.py` 原本自己的 `window_start_bank`、`check_window_order` 刪掉。
    - 答案檔格式：axis 每行 `in_coord` 後面多 `min_bank`；grid 每行 `in_x` 後面多 `top_row_bank left_col_bank`；spike_select 每個 bank 多一個 `valid` 欄位(四個欄位 `valid pending out_y out_x`)。
    - `tb_spike_select.sv` 例化 `CandidateGrid`(`OUT_CHANNELS=1`，$o_c$ 不影響要用的輸出)，先比 `CandidateGrid` 的窗左上角、每個 bank 的 `valid`、合法 bank 的座標，再比 `SpikeSelect`。
- 答案腳本對每組參數的每個座標確認「從 `min_bank` 往後循環的順序 = 座標由小到大」，全部成立。
- 模擬，全部 ALL PASS，elaborate 只有已知的 `VRFC 10-3532`：
    - `run_tb_candidate_axis.tcl` 8 組、`run_tb_candidate_grid.tcl` 7 組、`run_tb_spike_select.tcl` 8 組。
    - `run_tb_neuron_memory.tcl` 9 組：`tb_neuron_memory` 沒接新的 port，沒有新的警告。
- 反向測試(`min_bank` 改成直接等於 `max_bank`，少加 1；跑完已還原)：
    - axis、grid、spike_select 三支腳本都 FAIL，第一筆 `MISMATCH` 都是窗左上角的值；spike_select 的錯誤數比只錯窗左上角多，`SpikeSelect` 的送出順序也錯了。
    - 只有 $M=1$ 的參數組 PASS(axis 的 $K=1,S=2$、$K=2,S=3$，grid、spike_select 的 $K=1,S=2$)：只有一個 bank，`min_bank`、`max_bank` 都是 0，本來就分不出來。
- out-of-context 合成 `CandidateGrid`(xck26)，`-lint` 0 個訊息：
    - conv1：109 → 120 LUT(多 11)；conv2：105 → 105 LUT。都是 0 CARRY8、0 DSP。

## Part 5 LIF 膜電位更新(完成)

規格在 Conv.md 第 3 節(①~④)：一顆神經元收到一筆事件，算出 $\hat V_{new}$ 跟有沒有 fire。

接 Part 3、Part 4 的地方：`WeightTapSelect` 的 `weight_code`($q$)、`NeuronMemory` 的 `read_membrane`、`read_last_time`($\hat V,t_{last}$)，算出的 $\hat V_{new}$、$t$ 接 `NeuronMemory` 的寫埠。

定案的事項(2026-10-11 跟使用者確認)：

1. **模組切法**：`NeuronUpdate` 只算 1 顆神經元，上層(Part 7)用 generate 複製 $M\times M$ 份。
    - $M\times M$ 顆之間沒有互相影響，也沒有像 `NeuronMemory` 清除計數器那種共用的東西。
2. **衰減表**：放在 `NeuronUpdate` 裡，`$readmemh(DECAY_FILE)` 載入，每一份 `NeuronUpdate` 各帶一份。
    - 每顆的 $\Delta t$ 不同，本來就要 $M\times M$ 份查表電路(Conv.md 第 3 節 ①)。
3. **門檻**：`threshold` 是 `NeuronUpdate` 的輸入。
    - 依 $o_c$ 選門檻的電路留到 Part 7，門檻檔($w=9$、$11$ bits)的截斷警告也到那時確認。
4. **延遲**：純組合邏輯，同一拍算完，不拆多拍；要拆幾級到 Part 8 看 timing。
5. **port**：
    - 輸入 `weight_code`($q$)、`membrane`($\hat V$)、`last_time`($t_{last}$)、`event_time`($t$)、`threshold`($\hat v_{th}$)。
    - 輸出 `spike`($s$)、`new_membrane`($\hat V_{new}$)。
    - $t_{last,new}=t$ 只是接線，由上層直接接 `NeuronMemory` 的寫埠，不從模組輸出。
    - 不收 `valid`：不合法的候選照算，寫不寫回、送不送出由上層決定。
6. **參數**：沿用 `SaltConv` 的名稱。
    - `WEIGHT_WIDTH`、`MEMBRANE_INT_WIDTH`、`MEMBRANE_FRAC_WIDTH`、`DECAY_FRAC_WIDTH`、`DECAY_TABLE_DEPTH`、`TIME_WIDTH`、`ROUND`、`SATURATE`、`DECAY_FILE`。
    - `ROUND`、`SATURATE` 四種組合都要能合成。
7. **$t<t_{last}$**：只有時間戳記繞回才會發生，繞回還沒討論。
    - 先用 `TIME_WIDTH` 位元無號減法算 $\Delta t$，模組註解寫明，不替繞回做決定。
8. **驗證**：
    - 答案用訓練端的整數更新函式產生，testbench 逐筆比對。
    - 參數：`ROUND` × `SATURATE` 四種組合 × conv1、conv2 的位寬；人工參數 $f_V>0$、$f_a$ 不同、$\Delta t_{\max}$ 很小。
        - 訓練端只有 $f_V=0$，函式不支援 $f_V>0$ 的話，答案怎麼來再跟使用者確認。
    - 必測邊界：
        - $\Delta t=0$、$1$、$\Delta t_{\max}$、$\Delta t_{\max}+1$。
        - 負的 $\hat V$ 在 round 時往更負的方向捨。
        - 加完 $q$ 往上、往下溢位，繞回、飽和各一次。
        - $\hat V'=\hat v_{th}$ 要 fire。
        - $q$ 的最大、最小值。
    - 位寬小的參數組直接窮舉。
    - 反向測試：改壞 RTL 或答案檔，確認會 FAIL。
    - out-of-context 合成 conv1、conv2 參數，記錄 LUT、DSP，看衰減表吃多少 LUT。
9. **檔案**：`NeuronUpdate.sv`、`tb_neuron_update.sv`、`scripts/gen_neuron_update_ref.py`、`scripts/run_tb_neuron_update.tcl`、`sim_1/new/ref/` 的答案檔。

結果：

- 答案來源：訓練端 `salt_core.quant.codes.apply_decay_table_int` + `salt_core.quant.scan.process_event`，支援 truncate、飽和、$f_V>0$，人工參數也用同一套。
- 模擬：`run_tb_neuron_update.tcl` 跑 8 組參數 × `ROUND` × `SATURATE` 共 32 組，全部 ALL PASS。
    - 訓練端 4 組：$w$=12、14、9、11，衰減表用 `sources_1/mem/` 匯出的檔，答案腳本會確認它跟 `model.npz` 相同。門檻除了隨機值也用這層實際的逐 channel 門檻。
    - 人工 4 組：
        - $b$=3、$w$=4、$f_a$=3、$\Delta t_{\max}$=2、`TIME_WIDTH`=2：全部窮舉(V̂、q、門檻、所有 $t\ge t_{last}$ 的組合)。
        - $b$=2、$w$=2、$f_a$=1、$\Delta t_{\max}$=1：位寬下限，全部窮舉。
        - $f_V$=2、$b+f_V$ 比 $w$ 寬：V̂、q、$\Delta t$ 窮舉。
        - $w$=21、$f_a$=12(乘積 33 bits)：邊界值組合加 2 萬筆隨機。
    - 人工衰減表最後一格(查表的上界)不能是 0，不然跟「超過表深度 A=0」分不出來(反向測試抓到的漏洞，已修)。
    - 反向測試(每種跑窮舉組 4 種模式 + conv1 $w$=9 round 飽和，跑完 RTL、答案檔都還原)：
        - $\Delta t=0$ 也去乘衰減：5 組全部 FAIL。
        - round 不加半格：`ROUND=1` 的 3 組 FAIL，`ROUND=0` 的 PASS。
        - 飽和時正溢位改成繞回：`SATURATE=1` 的 3 組 FAIL，`SATURATE=0` 的 PASS。
        - fire 判斷 `>=` 改成 `>`：5 組全部 FAIL。
        - 超過表深度的判斷 `>` 改成 `>=`：5 組全部 FAIL。
        - 答案檔改一個值：那一組報 1 筆 `MISMATCH`，FAIL。
    - 有一次(改答案檔那輪)一組沒動到的參數在 xsim 執行了 `source tb_neuron_update.tcl`，testbench 卻沒有任何輸出就結束，腳本判成失敗；之後全部 32 組重跑、反向測試重跑都沒再出現，原因不明。
    - elaborate 有 `VRFC 10-3532`(同 Part 4，`glbl` 沒有這些參數)。`$readmemh` 讀衰減表沒有截斷警告。
- out-of-context 合成(xck26，non-project 模式)，`$readmemh` 都讀取成功：

| 設定 | LUT | CARRY8 | DSP | FF | 組合邏輯延遲 |
|---|---|---|---|---|---|
| conv1 $w$=12，round、繞回 | 83 | 5 | 1 | 0 | 5.65 ns |
| conv1 $w$=9，round、飽和 | 143 | 11 | 0 | 0 | 5.66 ns |
| conv2 $w$=14，round、繞回 | 88 | 5 | 1 | 0 | 5.77 ns |
| conv2 $w$=11，round、飽和 | 86 | 5 | 1 | 0 | 5.77 ns |
| conv1 $w$=12，truncate、繞回 | 83 | 5 | 1 | 0 | 5.65 ns |
| conv1 $w$=12，truncate、飽和 | 88 | 5 | 1 | 0 | 5.81 ns |
| conv1 $w$=12，round、飽和 | 88 | 5 | 1 | 0 | 5.81 ns |

- 合成的觀察：
    - $w$=9 的乘法被做成 LUT(143 LUT、0 DSP)，其他都用 1 個 DSP：乘法器用哪種資源由 Vivado 依位寬決定，跟 `WeightMemory` 指定 `rom_style` 之前的情況一樣。DSP、LUT 誰快的量測見「合成後要確認」的「乘法器用 DSP 還是 LUT」。
    - round 跟 truncate 的用量相同，加半格併進 DSP 裡了。
    - 衰減表的 LUT 用量包在上表的 LUT 總數裡，沒有單獨拆出來。
    - 組合邏輯延遲約 5.7 ns(只算這個模組，不含 BRAM 讀出、繞線)，要拆幾級到 Part 8 再看。
- `-lint`：每組 1~2 個 `ASSIGN-6`(有些 bit 沒被讀)，都是刻意丟掉的高位：
    - `shifted_product` 第 $w$ 位以上：$D$ 一定放得進 $w$ 位元(Conv.md 第 3 節 ②)，高位只是符號延伸。
    - `unfitted` 第 $w$ 位以上：繞回本來就只取低 $w$ 位，只在 `SATURATE=0` 時出現。

## Part 4 神經元 BRAM($\hat V,t_{last}$)介面(完成)

規格在 Conv.md 第 2 節「神經元」：

- $M\times M$ 個 bank，bank $(o_y\bmod M,\ o_x\bmod M)$，bank 內位址由 `CandidateGrid` 的 `bank_addr` 給，每個 bank 一律 $OC\times G_y\times G_x$ 格。
- 換樣本、實驗重來時所有神經元回到 $(0,0)$：`rst_n` 釋放後逐位址清 0，清除期間不收事件。

定案的事項(2026-10-09 跟使用者確認)：

1. **模組切法**：`NeuronMemory` 一個模組包 $M\times M$ 個 bank 跟清除邏輯，port 照 `CandidateGrid` 用 `[r_y][r_x]` 的 unpacked array。
    - 清除要一個共用計數器同時寫所有 bank，放同一個模組。
    - **2026-10-13 Part 7 code review 改掉**：`NeuronMemory` 改成單一 bank，上層 generate $M\times M$ 份；清除計數器拆成 `NeuronMemoryClear`，一層一份，接進每個 bank；參數改成直接收 `BANK_DEPTH`。見 Part 7「code review 要改的地方」第 1 條。
    - 運算(Part 5)、哪一拍讀寫(Part 7)都不在這裡。
2. **打包**：一格 $\{t_{last},\hat V\}$，$\hat V$ 在低位，寬 $w+$`TIME_WIDTH`；port 上兩個欄位分開，打包拆包在模組內。
    - 參數直接收 `MEMBRANE_WIDTH`($w$)，記憶體用不到 $i_V$、$f_V$ 的切法。
3. **$t_{last}$ 存完整 `TIME_WIDTH`**：時間戳記繞回還沒討論，少存位元等於先替它做決定。
4. **一讀一寫兩個埠**(simple dual port)：5.3 管線化一定要；無腦版只是讀寫不在同一拍。原本寫的「先做單埠無腦版」不做，到 Part 8 不用改介面。
    - 同一個 bank 同一拍讀寫同一個位址，讀出的值不保證，由上層避開(Conv.md 第 2 節「記憶體型態」)。
5. **讀取**：同步讀 1 拍，`read_enable` 每個 bank 各一條，`read_enable=0` 時保持上一次的值，跟 `WeightMemory` 一致。上層接 `valid`，沒有候選的 bank 不讀。
6. **清除**：`rst_n` 非同步觸發、同步釋放(同 `EventFIFO`)。
    - `rst_n=0` 期間 `clearing=1`；釋放後第 $n$ 個 posedge 每個 bank 的位址 $n-1$ 寫 0，寫完 `BANK_DEPTH-1` 後 `clearing` 變 0。
    - 釋放後 `clearing=1` 剛好 `BANK_DEPTH` 拍：conv1 648 拍、conv2 400 拍。
    - 清除期間外部寫入一律忽略。
7. **驗證**：Python 產生答案，每一拍的讀出值都要對上(見下方結果)。

結果：

- 模擬：`scripts/gen_neuron_memory_ref.py` 產生答案，`scripts/run_tb_neuron_memory.tcl` 跑 9 組參數，全部 ALL PASS。
    - testbench 例化 `CandidateGrid` + `NeuronMemory`(2026-10-13 起是 `NeuronMemoryClear` + $M\times M$ 份單一 bank 的 `NeuronMemory`，檢查跟答案檔不變)，讀寫位址都由 RTL 的 `CandidateGrid` 算；上一拍的 `valid`、`bank_addr` 存起來當這一拍的寫入位址(5.3 的時序，讀取延遲 1 拍)。
    - 五段：清除 → 全部讀一遍(全 0)→ 隨機讀改寫 → 全部讀一遍(最後寫的值)→ 再清除、全部讀一遍(全 0)。
        - 隨機讀改寫：隨機事件，$o_c$ 照 $0\sim OC-1$；讀出後下一拍寫回隨機值，涵蓋 $w$ 位元有號、`TIME_WIDTH` 位元的上下限；隨機插空拍，讀寫撞到同一顆神經元時也插空拍。
        - 每一拍比對：有候選的 bank 比讀出值，沒有候選的 bank 比保持值，每個 bank 的 `valid` 也跟 Python 比。
        - 清除期間每個 bank 都送全 1 的外部寫入，要被忽略。
    - 參數：conv1($w$=12、9)、conv2($w$=14、11)，`TIME_WIDTH=16`；人工 5 組：$M=3$、$M=4$、$S>K$ 的 $M=1$、字寬 38 bits、輸出 1×1 且 $OC=1$(每一步都撞到上一步的寫)。$w$ 最小 2、`TIME_WIDTH` 最小 1。
    - 反向測試(conv1 繞回版、1×1 兩組，跑完 RTL、答案檔都還原)：
        - 清除期間不忽略外部寫入：全部讀一遍讀到全 1，FAIL。
        - 讀取不看 `read_enable`：沒有候選的 bank 讀到 X，FAIL。
        - 清除少清一格：`clearing` 早一拍變 0，最後一格沒清到，FAIL。
        - 答案檔改一個預期值：那一行報 1 筆 `MISMATCH`，FAIL。
    - 答案檔總共約 15 MB，最大的是 conv1 約 2.6 MB。
    - elaborate 有 `VRFC 10-3532`(`glbl` 沒有 `KERNEL_SIZE` 參數可以覆寫)：generic 也被套到 `glbl`，總結行印出的參數跟 generic 一致，參數有套到 testbench。
- out-of-context 合成(xck26，non-project 模式，不動 `.xpr`)，`-lint` 四組都是 0 個訊息：

| 設定 | BRAM | LUT | FF |
|---|---|---|---|
| conv1，$w$=12 | 4 個 RAMB36(每個 bank 648×28，推成 1024×28) | 91 | 11 |
| conv1，$w$=9 | 4 個 RAMB36 | 85 | 11 |
| conv2，$w$=14 | 4 個 RAMB18(2 個 tile) | 90 | 10 |
| conv2，$w$=11 | 4 個 RAMB18 | 84 | 10 |

- 合成報 `Synth 8-7052`(BRAM 沒有併入輸出暫存器)，跟 `WeightMemory` 相同，到 Part 8 一起看。(Part 8.2：$R=1$ 本來就沒有輸出暫存器；$R=2$ 的處理見 Part 8.2)

## Part 3 權重 BRAM 讀取與 tap 選擇(完成)

規格在 Conv.md 第 2 節「權重」：

- 權重 BRAM 唯讀，位址 $(o_c,c)$ 攤平，深度 $OC\times C$。
- 每個位址存一整個 kernel：$K\times K$ 個權重碼打包成一個寬字，寬 $K\times K\times b$。
- 讀出寬字後，每個候選用自己的 $(k_y,k_x)$ 選出 tap 位置 $k_y\times K+k_x$ 的權重碼，是讀出後的 $K\times K$ 選 1 多工，不是另一次定址。
- 同一拍的 $M\times M$ 個候選共用同一個寬字($o_c$、$c$ 相同)，各自做一次多工。

接 Part 2 的地方：

- `CandidateGrid` 每組輸出的 `tap_y`、`tap_x` 就是 $(k_y,k_x)$，`valid=0` 的組不能用。
- $o_c$ 跟 `CandidateGrid` 的 `out_channel` 是同一個值(之後由 Part 7 的計數器給)，$c$ 是輸入事件的 `in_channel`。

開始寫 RTL 之前要先定：

1. **權重檔格式**：已定，寫在 Conv.md 第 2 節「權重」的「檔案格式」。匯出程式的分工見下方「權重匯出格式」。
2. **讀取延遲怎麼呈現**：已定，拆成兩個模組，tap 延遲 1 拍的 register 不放在這兩個模組裡。
    - `WeightMemory`：同步讀取的 ROM，這一拍送 $(o_c,c)$，下一拍輸出 $K\times K\times b$ 位元寬字。
    - `WeightTapSelect`：純組合邏輯，輸入寬字跟 $M\times M$ 組 $(k_y,k_x)$，輸出 $M\times M$ 個權重碼。tap 超出 $0\sim K-1$ 時輸出 0。
    - tap 是送 $(o_c,c)$ 那一拍算出來的，要存 1 拍才跟寬字對齊。這個 register 由上層放，跟候選的位址、座標、valid 存在同一組 register，不在 `WeightTapSelect` 內部另存一份。
    - 驗證用一個 testbench 同時例化兩個模組，不另寫暫時的 top。
        - 只驗一件事：RTL 讀出的權重等於 Python 用訓練端邏輯算出的 $q[o_c,c,k_y,k_x]$。
        - Python 對每組 $(o_c,c)$、每個事件座標 $(y,x)$，用訓練端的候選規則算出每個 bank 的 valid、$(k_y,k_x)$ 跟 $q[o_c,c,k_y,k_x]$。
        - testbench 照答案檔一行一拍：送 $(o_c,c)$，下一拍把每個 bank 的 $(k_y,k_x)$ 直接接到 `WeightTapSelect`，比對 valid=1 的 bank。
        - 答案不經過打包：conv1、conv2 直接取 `model.npz` 的 $q$；人工參數由答案檔腳本產生隨機 $q$，同一份 $q$ 匯出 `.mem` 跟寫答案。
        - 不另外測 RTL 自己的寫法細節(`read_enable=0` 保持、tap 超出範圍輸出 0、bank 之間 tap 接錯)：沒有模型答案可以對照，接 `CandidateGrid` 的部分到 Part 7 用真實事件再測。

結果：

- 權重檔：訓練端 `python -m tools.export_fpga` 匯出到 `SaltConv.srcs/sources_1/mem/<量化資料夾>/`，繞回版、飽和版各一份。
    - 兩版的權重、衰減表內容相同；門檻寬度不同(12、9 bits)，但都是 3 個 hex 字元，內容也相同。
- 模擬：`scripts/gen_weight_lookup_ref.py` 產生答案，`scripts/run_tb_weight_lookup.tcl` 跑 9 組參數，全部 ALL PASS。
    - conv1、conv2 各用兩版的權重檔跑一次。
    - 人工參數 5 組：$C$、$OC$ 不是 2 的次方；$K=1,4,5,7$；寬字 4、80、150、441 bits；`IN_CHANNEL_WIDTH` 比需要的寬。
    - 反向測試：把 conv1 繞回版權重檔一個位址的最高 hex 字元改掉(清掉 tap 8 的 bit 5)，那組報 289 筆 `MISMATCH`、FAIL，腳本 exit 1。
    - 答案檔 conv1 約 2.8 MB、conv2 約 5.6 MB。
- 命名調整(Part 2 的檔案也一起改，`candidate_axis`、`candidate_grid` 重跑全部 PASS)：
    - `BANK_COUNT` 改成 `AXIS_BANK_COUNT`：值是每一軸的 bank 數 $M$，不是 bank 總數 $M\times M$。
    - `WeightMemory` 的 `DEPTH`、`ADDR_WIDTH` 改成 `WEIGHT_DEPTH`、`WEIGHT_ADDR_WIDTH`，跟 `BANK_DEPTH`、`BANK_ADDR_WIDTH` 同一種命名。
- out-of-context 合成(xck26)，`-lint` 三個都是 0 個訊息：
    - `WeightMemory` 用 `(* rom_style = "block" *)` 固定成 BRAM，不交給 Vivado 依大小判斷，各層同一種資源才好比較功耗、用量。
        - 不指定時 conv1(深度 16)會被做成 32 LUT + 63 FF，conv2(深度 128)是 1 個 RAMB36。
        - 指定後 conv1、conv2 都是 1 個 RAMB36，0 LUT。
        - 合成報 `Synth 8-7052`：BRAM 沒有併入輸出暫存器，timing 可能不是最好。加輸出暫存器會讓讀取延遲變 2 拍，屬於 Conv.md 5.5 的 $R\ne1$，到 Part 8 再看。(Part 8.2 做成參數 `READ_LATENCY`)
    - `WeightTapSelect` $K=3,S=2$($M=2$，4 個 9 選 1)：112 LUT。

## 驗證流程(Part 1、2 用的做法，Part 3 之後照做)

- **答案檔**：Python 腳本用訓練端的函式產生，放 `SaltConv.srcs/sim_1/new/ref/`。
    - 環境是 WSL 的 conda 環境 `jax`(`~/miniconda3/envs/jax/bin/python`)。
    - 範例：`scripts/gen_candidate_grid_ref.py`。
- **testbench**：讀答案檔逐筆比對，不一致印出輸入、欄位、預期值、實際值，最後印一行總結(`ALL PASS` / `FAIL`)。
    - 參數用 generic 帶入，答案檔目錄用 `-testplusarg REF_DIR=` 帶入。
    - 範例：`tb_candidate_grid.sv`。
    - **Part 8 之後：一個 testbench 的目標要小而明確**(2026-10-13 使用者定的)。目標不是「這個模組對不對」，而是「這個模組在某一種情況(某種反壓方式、某個狀態)下對不對」，不同情況拆成不同檔案。
        - 機制維持現有寫法(一個 `initial` 流程，negedge 給值、posedge 前檢查)，不改用多個並行 process、SVA 這類新機制：之前多個 process 的寫法出過很多錯。
        - 怎麼拆由規劃時評估。拆不開的不硬拆，例如反壓下「資料有沒有少、有沒有亂」還是要對答案，交握規則跟對答案不一定能分成兩支。
        - 起因：`tb_salt_conv` 一支同時測計算結果、拍數、4 種反壓模式、交握規則、8 項涵蓋率，review 時看不懂，模式怎麼選也沒能好好討論。Part 8.1 已拆成四支(一種驅動方式一支，共用部分放 `tb_salt_conv_common.svh`)。
    - **一個 Vivado session 只跑一個模擬集**(2026-10-15 踩到)：同一個 session 跑第二個模擬集，`launch_simulation` 會沿用第一個的檔案清單。多支 testbench 要連續跑，每支開一個 batch Vivado(見 vivado-usage skill 8.8、`run_tb_salt_conv.tcl`)。
- **跑模擬**：一個 testbench 一個模擬集，`scripts/run_tb_*.tcl` 跑所有參數組，共用流程在 `scripts/sim_common.tcl`。
    - 多組參數一律用 batch 模式跑；從 GUI 的 Tcl Console 跑，連續 elaborate 會不定時出現 `Spawn failed`(原因不明)。
    - GUI 只用來跑 testbench 預設參數的單組模擬、看波形。
- **Vivado 的已知陷阱**記在本機的 `.claude/skills/vivado-usage/SKILL.md`(不進 repo)。
    - 最常碰到的是：GUI 開著專案時，外面用 batch 改的專案設定會被 GUI 存檔蓋掉。GUI 開著就在專案副本上跑，不要動正式專案的 `.xpr`。
- **單獨合成子模組**用 out-of-context(`synth_design -mode out_of_context`)，不然 port 會被當成晶片接腳算進 IOB。
- **合成量測**(Part 7 起量速度、資源都用這套；腳本沒有進 repo，每次在 session 暫存目錄重寫)：
    - non-project 模式，不動 `.xpr`。每組參數一個包裝 module：port 位寬寫死、例化 `SaltConv` 帶入整組參數，資料檔用絕對路徑。
    - 4 組設定：訓練端 conv1、conv2 × 繞回、飽和，參數照 `run_tb_salt_conv.tcl` 的前 4 組，資料檔在 `SaltConv.srcs/sources_1/mem/<量化資料夾>/`。
    - Tcl 步驟：
        - `read_verilog -sv` 讀 `sources_1/new/` 的全部 `.sv` 跟包裝 module。
        - `synth_design -top <包裝> -part xck26-sfvc784-2LV-c -lint`，接著 `catch {close_design}`(`-lint` 跑完沒有開著的設計)。
        - `synth_design -top <包裝> -part xck26-sfvc784-2LV-c -mode out_of_context`。
        - `create_clock -period 10.000 -name clk [get_ports clk]`；除了 `clk` 的輸入、全部輸出 `set_input_delay 0`、`set_output_delay 0`。
        - `opt_design`、`place_design`、`route_design`。
        - `report_timing_summary`、`report_timing -max_paths 1`(最長路徑)、`report_timing -from [get_ports out_ready]`、`report_utilization`(加 `-hierarchical` 看各模組)。
    - 最高時脈用 10 ns 的 slack 換算：$1000/(10-\text{WNS})$ MHz；10 ns 只是量測用，不是目標。
    - $R=2$ 要確認輸出暫存器：合成完(布局前)跟繞線後各查一次每顆 BRAM 的 `DOB_REG`；繞線後變 0 可能是布局搬出去的，看 log 有沒有 `Physopt 32-665`(見 Part 8.2)。
    - hold 有 -0.18 ns 的違規是輸入 port 進 FIFO，out-of-context 把輸入延遲設 0 造成的，不用管。
    - 一次平行開 8 個 batch Vivado 時，出現過一組 `opt_design` 報空白的 `Synth 20-411`，單獨重跑就好。
    - 從 agent 的 shell 跑 Vivado 要先 `env -u NoDefaultCurrentDirectoryInExePath`(vivado-usage skill 8.6)。

## 專案狀態備註

- `synth_1` 是 out-of-context，top 是 `CandidateGrid`。之後單獨合成別的子模組，改 top 就好。

## 待決事項

### 量化與數值

- **`FIFO_DEPTH`**：反壓、不丟事件的策略已定，深度要看目標 clock 頻率跟 conv2/compress 的實際輸入事件率，這兩個數字還沒有。
- **FPGA 上實際省多少功耗**：運算量少 20 倍不等於功耗少 20 倍，漏電流、clock tree 是固定成本，要 Vivado 功耗分析或實測才有數字。

### 合成後要確認

- **`NeuronUpdate` 的乘法器用 DSP 還是 LUT(Part 8 決定)**：
    - 問題：$A\cdot\hat V$ 沒有指定資源，Vivado 依位寬自己選，$w$=9 用 LUT、其他用 DSP，各層、各版本資源類型不同，用量跟功耗不好比。
    - 指定方法：在乘積訊號上加 `(* use_dsp = "yes" *)` 強制用 DSP、`"no"` 強制用 slice logic(UG901 2025.2「Multipliers Implementation」)。
    - 量測(2026-10-11，xck26，non-project，暫存目錄的 RTL 副本，正式 RTL 沒加屬性)：
        - 輸入、輸出各包一層暫存器，量暫存器 → `NeuronUpdate` → 暫存器；合成、布局、繞線後，用 2 ns 時脈的 slack 換算路徑延遲。
        - 都是 round；$w$=12、14 繞回，$w$=9、11 飽和(各自量化版本實際的設定)。

| 位寬 | 乘法器 | LUT | CARRY8 | DSP | 路徑延遲 | 邏輯 / 繞線 | 最高時脈 |
|---|---|---|---|---|---|---|---|
| conv1 $w$=12 | DSP | 73 | 5 | 1 | 5.35 ns | 3.54 / 1.82 ns | 181 MHz |
| | LUT | 153 | 13 | 0 | 5.10 ns | 2.74 / 2.36 ns | 190 MHz |
| conv2 $w$=14 | DSP | 76 | 5 | 1 | 5.56 ns | 3.62 / 1.95 ns | 175 MHz |
| | LUT | 172 | 15 | 0 | 5.42 ns | 2.69 / 2.73 ns | 179 MHz |
| conv1 $w$=9 | DSP | 78 | 5 | 1 | 5.66 ns | 3.74 / 1.92 ns | 172 MHz |
| | LUT | 148 | 11 | 0 | 5.30 ns | 2.52 / 2.78 ns | 183 MHz |
| conv2 $w$=11 | DSP | 83 | 5 | 1 | 5.73 ns | 3.56 / 2.17 ns | 170 MHz |
| | LUT | 158 | 13 | 0 | 5.32 ns | 2.75 / 2.57 ns | 182 MHz |

- 乘法器量測的結果：
    - 不拆管線的版本，LUT 每組都比較快(0.14~0.43 ns，最高時脈高 2~7%)，代價是每顆多 70~95 LUT、6~10 CARRY8。
    - 一層 $M\times M=4$ 份：DSP 版 4 個 DSP，LUT 版多 300~400 LUT；晶片總量 117,120 LUT、1,248 DSP。
    - DSP 慢在邏輯延遲(多約 1 ns)：純組合邏輯沒用到 DSP 內部暫存器，訊號直接穿過 `DSP_A_B_DATA → PREADD → MULTIPLIER → ALU → OUTPUT` 每一級。
    - 還沒量：Part 8 拆管線時，乘法如果切在 DSP 內部的暫存器上，DSP 的延遲可能大幅下降，結論可能反過來，要再量一次才決定。
- **衰減表 ROM 的 LUT 用量**：$M\times M$ 份組合邏輯查表電路，吃太多再回頭檢討。
- **`out_ready` 進到狀態機的路徑(Part 7 量過，Part 8 管線化後再量)**：
    - 路徑：下一層 FIFO 的 `full` 暫存器 → 層與層之間的線 → `oc_done`(這個 o_c 送完了)→ 狀態、$o_c$、bitmask、事件暫存器、候選暫存器、FIFO 讀指標的 enable，跟 `NeuronMemory`、`WeightMemory` 的讀取 enable、讀位址。
    - Part 7 量到的(見 Part 7 結果)：最長的一條是 `out_ready` → `oc_done` → `take_new_event` → 讀位址選 FIFO 還是事件暫存器 → `CandidateGrid` → BRAM 讀位址，7~8 層 LUT、3.8~4.6 ns，10 ns 時脈還有 4.9~5.8 ns 餘裕，不是最長的路徑。
        - 原本估「1~2 層 LUT 加 fan-out」是錯的：漏算了讀位址的來源由 `take_new_event` 選，後面還要經過整個 `CandidateGrid`。
    - 太長時的辦法：
        - 讀位址不等 `out_ready`：SENDING 期間不寫神經元記憶體，每一拍都先送下一個 $o_c$ 的讀位址，重讀不會出錯。(2026-10-15 Part 8.1 採用位址不等的部分，讀取開關待評估，見 Conv.md 5.3 改動四)
            - 讀位址的來源改用 `last_channel` 選(下一個 $o_c$ 是不是新事件只看這個，不用等送完)，`CandidateGrid` 跟 BRAM 的位址、enable 就都不接這條。
            - 候選暫存器、事件暫存器、FIFO 讀指標還是要等 `oc_done`：`SpikeSelect` 還在用目前的候選，事件還沒真的拿走。
        - 在 `SaltConv` 輸出加 2 格 skid buffer：狀態機看的 `out_ready` 改成 skid buffer 自己的暫存器，下一層的 `full` 只走到 skid buffer；代價是 2 格 × 一筆輸出事件的寬度，輸出晚 1 拍。
- **`CandidateAxis` 的除法、`CandidateGrid` 的乘常數**：除以 $S$、除以 $M$ 不是 2 的次方時，UG901 沒寫會用 LUT 還是 DSP；乘常數也一樣。
    - `CandidateAxis` 單獨合成，$K=3,S=1$：LUT，0 DSP。
    - `CandidateGrid` 預設參數($K=3,S=1,P=1$，64×64，$OC=16$，$M=3$)，out-of-context：306 LUT、54 CARRY8，0 DSP。
    - 其他參數(包括實際的 conv1、conv2)合成後看 utilization，必要時加 `USE_DSP="no"`。
- **`.mem` 左邊補的 0 會不會出截斷警告**：權重檔已確認不會。
    - xsim(寬字 63、150、441 bits)跟合成(63 bits)都沒有截斷警告，合成 log 是 `$readmem data file ... is read successfully`。
    - 門檻檔($w=9$、$11$ bits)要等 Part 5 讀進 RTL 時再看一次。

### 權重匯出格式(已定，conv 層已實作)

- 已定：
    - 每層三個 `$readmemh` 用的 hex 檔：權重寬字、$\hat v_{th}[o_c]$、$A[\Delta t]$。
        - Vivado 合成只收 `$readmemh`、`$readmemb` 兩種(UG901 Table 24)，選 hex。
    - 格式規格只寫在 Conv.md 第 2 節「權重」、「門檻」，第 3 節 ① 的「檔案格式」，這裡不重複。
        - 位址 $o_c\times C+c$，任意 $C$ 都用乘常數，不補到 2 的次方。
        - tap $k_y\times K+k_x$ 放在寬字第 $(k_y\times K+k_x)\,b$ 位元起，tap 0 在最低位。
        - 二補數，一行一個位址，固定 $\lceil\text{位元數}/4\rceil$ 個 hex 字元，最左邊補 0。
    - 匯出程式由訓練端寫，docstring 指到 Conv.md，不在訓練端文件另寫一份規格。
    - 程式位置：打包函式放 `salt_core` 新模組(輸入陣列、輸出 `.mem`)，`tools/export_fpga.py` 只負責讀 `model.npz`。SALT-FPGA 測非 2 的次方參數時，答案檔腳本 import 同一個打包函式產生隨機權重的 `.mem`。
    - 輸入輸出：輸入一個量化資料夾，`--out-dir` 指定輸出；每層 `<層>_weight.mem`、`<層>_threshold.mem`、`<層>_decay.mem`；只匯出 conv 層。
    - 匯出時檢查：$q$ 超出 $b$ 位元、同一個 $o_c$ 的 $\hat v_{th}$ 不全相同或超出 $w$ 位元、衰減表超出 $f_a$ 位元，都 raise。
    - `.mem` commit 進 SALT-FPGA(例如 `SaltConv.srcs/sources_1/mem/<版本>/`)，繞回版、飽和版各一份。
    - 訓練端 `salt_core/tests/` 加手算小例子驗證打包。
- 訓練端 `model.npz` 存的是 $q$(形狀 `(OC, C, K, K)`)、`decay_table_int`、`v_th_int`。$\hat v_{th}$ 逐神經元存，同一個 output channel 值相同。
- 訓練端 TODO 的「量化模型的匯出格式」已改成指向 Conv.md，FC 層等 FC.md。

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

### 量化方案

- `SaltConv` 是通用模組：捨入(`ROUND`)、溢位處理(`SATURATE`)兩種都支援，由例化端用參數選，不選定一版。
- 訓練端目前給了兩版，$f_V=0$，所以 $w=i_V$：
    - 繞回版：conv1 12 bits、conv2 14 bits，test 0.9222。驗證跟 test 都沒碰到範圍，繞回不會真的發生。
    - 飽和版：conv1 9 bits、conv2 11 bits，test 0.9229。幾乎每筆樣本都會碰到範圍，硬體要逐位元夾住。
    - 其他都相同：$b=7$、$f_a=6$、$f_V=0$、捨入用 `round`，衰減表、門檻、權重碼也相同。

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
- 現在是 distributed RAM 版(`(* ram_style = "distributed" *)`，資料陣列的寫入放在沒有 reset 的 `always_ff`)，輸出遵守 valid/ready 交握，外部不假設任何固定延遲。
    - 之後深度開大換 BRAM(讀取多 1 clock)，只要改 `EventFIFO` 內部把 `valid` 延後對齊，外部不用動。
- 讀出端必須維持 FWFT(2026-10-12 定)：`rd_data` 直接是最前面那一筆，`rd_valid && rd_ready` 那一拍才移走。
    - 靠它成立的兩件事(Part 7 已定案第 3、4 項)：
        - 反壓：狀態機同一拍看 `out_ready`、同一拍決定拿不拿事件，不用在讀出端另加 skid buffer。
        - 事件暫存器：送 $o_c=0$ 讀位址那一拍，直接用 FIFO 最前面那筆的 $x,y,c$，換事件不多花拍數。
    - 換 BRAM 時，`EventFIFO` 內部要多一格輸出暫存器，先把下一筆讀出來放著，對外維持 FWFT。
- 寫入端 `wr_ready = !full`，`full` 是暫存器，不看讀出端：上一層看到的 ready 不會跟這一層的狀態機串在一起，層與層之間不用另加 skid buffer(Part 7 已定案第 4 項)。

### 候選計算(`CandidateAxis`、`CandidateGrid`)

- 拆成單軸子模組，參數 $K,S,P,O_{max}$，y、x 各例化一次。上層做 $M\times M$ 配對跟 bank 內位址攤平。
    - 候選條件兩軸獨立，只有位址攤平要兩軸合併。
    - 單軸可以窮舉驗證。
    - 非正方形 kernel 只要兩個實例傳不同參數。
- 輸出 $M$ 組，第 $r$ 組就是 bank $r$($o\bmod M=r$)的候選，每組帶 $\{valid,\ o,\ \lfloor o/M\rfloor,\ k\}$。
    - $o\bmod M$ 就是組的編號，不另外輸出。
    - $k$ 在這裡一起算好，給 Part 3 選權重 tap。
- 輸出 port 每個欄位各自一個 unpacked array：`valid`、`out_coord`、`bank_offset`、`tap`，長度 `AXIS_BANK_COUNT`，位寬用模組參數算。
    - 另外一個值 `min_bank`：窗最小座標 $o_{max}-(M-1)$ 的 bank，$(m_{max}+1)\bmod M$，給 `SpikeSelect` 用(Part 6.5 加的)。
    - 不用 struct：要多一個共用巨集 `.svh`，上層兩軸位寬不同還要各開 generate block，專案其他地方也沒用 struct。
- 兩軸配對獨立成子模組 `CandidateGrid`，可以單獨窮舉驗證。
    - 輸入 $(y,x)$ 跟這一拍的 $o_c$，輸出 $M\times M$ 組 `valid`、`bank_addr`、$(o_y,o_x)$、$(k_y,k_x)$。
    - 另外輸出窗左上角的 bank `top_row_bank`、`left_col_bank`，就是 y 軸、x 軸的 `min_bank`(Part 6.5 加的)。
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
    - 這個理由只在 $R=C=1$ 成立，拆級之後不成立，見「Part 8.1 之後」。

## 參考文件

- [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md)：conv 分支事件驅動 RTL 的完整推導。
- [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)：FC 分支，還沒開始。
- [`Concept/model_operation_quant.md`](../Concept/model_operation_quant.md)：硬體看這份，整數版的參數、單筆事件更新、候選規則、多層串接、輸出層讀出。
- [`Concept/model_operation_float.md`](../Concept/model_operation_float.md)：浮點推導。
- 訓練端 `D:\Project\Spiking-Affine-Lazy-Training`：單狀態仿射 LIF 加 associative scan 平行掃描訓練，conv/FC 都支援，N-MNIST 約 92%。
