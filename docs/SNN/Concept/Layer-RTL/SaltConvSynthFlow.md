# SaltConv 合成與實作流程

量時序、資源用的流程，跟用到的每一個參數；量測結果在最後的「量測結果」。

## 範圍

- 對象(繞回版、飽和版各一份)：
    - 兩層串接 `SaltConvNet`(訓練端 conv1 → conv2)。
    - 整條網路 `SaltConvFCNet`(conv1 → conv2 → 轉接模組 → FC 輸出層 → 膜電位暫存器，SaltFC Part 12 起)。
    - 極限測試 `SaltStressNet`(BRAM 用到約一半時的餘裕，亂數權重，只合成不模擬，SaltFC Part 12)。
- 三支腳本共用同一套流程(`scripts/synth_common.tcl`)，差在頂層、參數、要報的路徑。
- 這是量測用的流程，不是正式整合：
    - 不接腳位、不出 bitstream(out-of-context)。
    - 時脈、輸入輸出延遲是量測用的假設，見「約束」。
- Vivado 專案 `SaltNET.xpr` 裡的 `synth_1`、`impl_1` 沒有在用，量測一律用下面的腳本。

## 檔案

| 檔案 | 內容 |
|---|---|
| `SaltNET/scripts/synth_common.tcl` | 共用流程：參數解析、讀 RTL、合成、約束、opt / place / route、出報告 |
| `SaltNET/scripts/net/synth_salt_conv_net.tcl` | 兩層串接的參數、要報的路徑 |
| `SaltNET/scripts/net/synth_salt_conv_fc_net.tcl` | 整條網路的參數、要報的路徑 |
| `SaltNET/scripts/net/synth_salt_stress_net.tcl` | 極限測試的資料檔、要報的路徑(網路形狀讀 `generics.txt`) |
| `SaltNET/scripts/net/SaltStressNet.sv` | 極限測試的頂層，只給合成用，不在 `sources_1/new` 底下、不加進 Vivado 專案 |
| `SaltNET/scripts/net/gen_salt_stress_net_mem.py` | 極限測試的網路形狀(只定義在這裡)、亂數權重與門檻檔、`generics.txt` |
| `SaltNET/SaltNET.srcs/constrs_1/new/salt_conv_impl.xdc` | 只給實作用的約束(目前只有乘法 DSP 的 `DONT_TOUCH`) |
| `SaltNET/SaltNET.srcs/sources_1/new/{lib,conv,fc,net}/*.sv` | RTL，四個資料夾全部讀進來，頂層用不到的模組不會合成 |
| `SaltNET/SaltNET.srcs/sources_1/mem/<量化版本>/*.mem` | 訓練端匯出的權重、門檻、衰減表；FC 的 `out_*.mem` 是 $n_{col}=4$ 打包 |
| `SaltNET/SaltNET.runs/stress_net_mem/<版本>/` | 極限測試的亂數資料檔、`generics.txt`，由 `gen_salt_stress_net_mem.py` 產生，不進版控 |

## 怎麼跑

```powershell
cd D:\Project\SALT-FPGA\SaltNET\SaltNET.runs
vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/net/synth_salt_conv_net.tcl -tclargs saturate 4.8
```

- 整條網路換成 `synth_salt_conv_fc_net.tcl`，極限測試換成 `synth_salt_stress_net.tcl`(先在 WSL 跑 `gen_salt_stress_net_mem.py`，用法在檔頭)。
- 第一個參數：`wrap` 或 `saturate`。
- 第二個參數：時脈週期(ns)，不給就是 4.8。
- 第三個參數(可省略)：`synth_only`，合成完就停，只出 `util_synth.rpt`、`bram_regs.txt`；調極限測試的 BRAM 數時用。
- 輸出在 `SaltNET.runs/<net | conv_fc_net | stress_net>_<版本>_<週期>/`，`SaltNET.runs` 不進版控。
- 不碰 `SaltNET.xpr`，可以跟模擬同時跑；兩個合成同時跑碰過 `Designutils 20-411`(vivado-usage skill 第 11 節)，一次跑一個。
- agent 從自己的 shell 跑要先拿掉 `NoDefaultCurrentDirectoryInExePath`(vivado-usage skill 8.6)。

## 工具

- Vivado 2025.2，non-project 模式(不開專案，全部用 Tcl 指令)。
- part `xck26-sfvc784-2LV-c`(KV260 的 K26 SOM)。

## 步驟與參數

| 步驟 | 指令 | 指定的參數 | 其他 |
|---|---|---|---|
| 讀 RTL | `read_verilog -sv` | `sources_1/new/` 底下 `lib/`、`conv/`、`fc/`、`net/` 的 `.sv` 全部；極限測試多讀 `scripts/net/SaltStressNet.sv` | 2026-11-14 前只讀 `lib/`、`conv/`、`net/` |
| 合成 | `synth_design` | `-top <頂層>`、`-part`、`-mode out_of_context`、每個設計參數一個 `-generic` | 其餘用預設，見下表 |
| 合成後報告 | `report_utilization`、`get_property DOA_REG / DOB_REG` | | `util_synth.rpt`；`bram_regs.txt` 每顆 BRAM 一行，輸出暫存器有沒有併進去(布局可能再搬出來) |
| 約束 | `create_clock`、`set_input_delay`、`set_output_delay`、`read_xdc` | 見「約束」 | 合成之後才讀，合成不受影響 |
| 邏輯最佳化 | `opt_design` | 無 | 預設：retarget、propconst、sweep、bram_power_opt |
| 布局 | `place_design` | 無 | 預設 directive；布局時的實體最佳化(PSIP)照預設開著，乘法 DSP 被約束擋住 |
| 繞線 | `route_design` | 無 | 預設 directive |
| 報告 | `report_timing_summary`、`report_timing`、`report_utilization` | | 見「看結果」 |

- 沒有跑 `phys_opt_design`，也沒有出 bitstream。
- `synth_design` 沒指定的選項都是預設值(`synth_design -help`，2025.2)：

| 選項 | 預設 | 意思 |
|---|---|---|
| `-directive` | default | 一般合成，不偏面積或速度 |
| `-flatten_hierarchy` | rebuilt | 合成時攤平最佳化，報告時再把階層還原 |
| `-global_retiming` | auto | 自動在組合邏輯前後搬暫存器 |
| `-resource_sharing` | auto | 自動共用運算器 |
| `-fsm_extraction` | auto | 自動辨識狀態機 |
| `-shreg_min_size` | 3 | 連續 3 個以上的暫存器才做成 SRL |
| `-max_dsp`、`-max_bram` | -1 | 不限制，用到 part 的上限 |

- RTL 裡指定資源、影響合成的屬性(不是工具參數，寫在程式碼裡)：

| 模組 | 屬性 | 作用 |
|---|---|---|
| `NeuronUpdate` | 乘積、捨入加 `use_dsp = "yes"` | 乘法一律用 DSP(2026-10-21 決定，見「量測結果 → 乘法一律用 DSP」) |
| `DecayLookup` | 衰減表 `rom_style = "distributed"` | 用 LUT 查表，$M\times M$ 份同一拍各查各的(2026-10-27 從 `NeuronUpdate` 拆出) |
| `EventFIFO` | `ram_style = "distributed"` | 用 LUT 當記憶體 |
| `NeuronMemoryArray` | `ram_style = "block"`、模組 `keep_hierarchy = "soft"` | 神經元記憶體用 BRAM；保留模組邊界，$R=2$ 的第二級才併得進 BRAM 輸出暫存器(vivado-usage skill 第 10 節) |
| `ReadOnlyMemory`(`WeightMemory` 例化) | `rom_style = "block"`、模組 `keep_hierarchy = "soft"` | 權重用 BRAM，原因同上；位址計算留在 `WeightMemory`，不框進去 |

## 約束

| 約束 | 值 | 為什麼 |
|---|---|---|
| `create_clock -period` | 4.8 ns(可改) | 目標 5 ns(200 MHz)，手動留 0.2 ns 餘裕；只跑這個週期看過不過，不掃最高時脈 |
| `set_input_delay` / `set_output_delay` | 0 | 把網路的輸入輸出 port 當成邊界上的暫存器，只量設計內部的路徑；整合時要換成實際上下游的約束 |
| `salt_conv_impl.xdc` | 乘法 DSP(`*neuron_update/rounded_product`)設 `DONT_TOUCH` | 見下面；腳本確認 `NeuronUpdate` 的 DSP 都套上(兩層串接 8 顆、整條網路 12 顆、極限測試 24 顆)，沒套上就報錯停止 |

- 為什麼擋住乘法 DSP：
    - `place_design` 的實體最佳化有一項 DSP Register optimization，會在布局初期用估計的延遲，把 DSP 裡的切點暫存器(PREG)搬到外面的一般暫存器。
    - 2026-10-21 飽和版 4.8 ns 實測：預設搬了 1 顆，繞線後 +0.028 ns；擋住之後 +0.136 ns。對照實驗見「量測結果 → 擋住乘法 DSP 的暫存器搬動」。
    - 只擋這幾顆 DSP；BRAM 輸出暫存器的搬動照常讓工具決定。
    - cell 名稱裡 `neuron_update` 前面是 `.`(generate 區塊用點連接，例如 `conv1/row_banks[0].col_banks[0].neuron_update/rounded_product`)，條件寫成 `*/neuron_update` 會一顆都對不到，Vivado 只給 critical warning、照樣跑完(2026-10-22 第一次跑就這樣)。
    - 這個約束檔只在實作用：寫進 RTL 的 `dont_touch` 會在合成時就生效，可能連「切點暫存器併進 DSP」都擋掉(沒實測)。正式專案加這個檔案時要設 `USED_IN_SYNTHESIS false`。
- 檢查只看 `NeuronUpdate` 的 DSP(2026-11-14 改)：FC 的 $n_{in}$ 不是 2 的次方、列數又多時，權重位址 $y\cdot n_{in}+\text{src}$ 會合成成 DSP(極限測試試 $n_{in}=576$ 時碰到，`C+(A:0x240)*B`)，那顆沒有切點暫存器可搬，不用擋。原本要求所有 DSP 都套上，碰到這種情況會停下。

## 設計參數

兩版共用：

| 參數 | 值 |
|---|---|
| 網路輸入 | 2 通道、34×34 |
| conv1 | OC=8、K=3、S=2、P=1，輸出 17×17 |
| conv2 | OC=16、K=3、S=2、P=1，輸出 9×9 |
| FIFO 深度 | 兩層都是 16 |
| 衰減表深度 | 75 |
| 時間位寬、$b$、$f_V$、$f_a$ | 16、7、0、6 |
| 捨入 | round |
| 管線 | $R=2$、$C=2$、重疊 |

各版不同：

| 版本 | conv1 $i_V$ | conv2 $i_V$ | 溢位 | 資料檔 |
|---|---|---|---|---|
| `wrap` | 12 | 14 | 繞回 | `best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1` |
| `saturate` | 9 | 11 | 飽和 | `best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11` |

- 跟模擬腳本 `run_tb_salt_conv_net.tcl` 用同一組值。

整條網路 `SaltConvFCNet`：conv1、conv2 同上表，加上

| 參數 | 值 |
|---|---|
| FC 輸出層 | $n_{in}=1296$(頂層推出)、$n_{out}=10$、$n_{col}=4$、不 fire、開膜電位輸出 |
| FC 的 $i_V$ | 繞回 14、飽和 11 |
| FC 的 FIFO 深度、衰減表深度 | 16、75 |
| 資料檔 | 同上表的資料夾(飽和版的 `out_*.mem` 2026-11-14 匯出) |

- 跟模擬腳本 `run_tb_salt_conv_fc_net.tcl` 的前兩組相同。

極限測試 `SaltStressNet`(形狀只寫在 `gen_salt_stress_net_mem.py`，2026-11-14)：

| 層 | 輸入 | 輸出 | 其他 |
|---|---|---|---|
| conv1 | 2 通道 34×34 | 8 通道 17×17 | K3 S2 P1 |
| conv2 | 8 通道 17×17 | 16 通道 9×9 | K3 S2 P1 |
| conv3 | 16 通道 9×9 | 16 通道 4×4 | K3 S2 P0 |
| 轉接模組 | 16 通道 4×4 | $\text{src}$ 0~255 | |
| FC1 | 256 | 512 | $n_{col}=4$，fire，每顆一個門檻 |
| FC2 | 512 | 256 | $n_{col}=4$，fire，每顆一個門檻 |
| FC3(輸出層) | 256 | 10 | $n_{col}=4$，不 fire，開膜電位輸出 |
| 膜電位暫存器 | 10 顆 | | |

- $i_V$：conv1 繞回 12、飽和 9；其他層繞回 14、飽和 11。其他參數同上表(FIFO 16、衰減表 75、$R=2,C=2$ 重疊)。
- 權重是 $b$ 位元全範圍的亂數，門檻是 $1\sim2^{w-1}-1$ 的亂數，seed 0；兩版權重相同、門檻各抽。
- 衰減表借訓練端匯出的：conv1、conv2 用自己的，conv3 借 conv2 的，FC1~FC3 借 `out` 的。

## 看結果

- `info.txt`：
    - `route wns`：繞線後最差的餘裕，正的就是這個週期過了。
    - `dsp dont_touch`：被約束擋住的 DSP 數 / 全部 DSP 數，確認約束有套上。
    - 之後每行是一組路徑最差的一條(餘裕、資料路徑延遲、邏輯級數、起點 → 終點)，每組另有 `<組名>.rpt` 列最差 3 條：
        - `<a>_output_to_<b>`：a 送事件(或膜電位輸出)給下一個模組 b(`out_valid`、資料 → b 的 FIFO 或暫存器)。
        - `<b>_ready_to_<a>`：b 的反壓(b `in_ready` → a `out_ready` → a 停不停、寫不寫回)，沒有資料從 b 送回 a。轉接模組給上一層的 ready 經過 1 級 LUT 接 SaltFC 的 `in_ready`，所以另外報 SaltFC → 上一層 conv。
        - `<模組>_inside`：模組內最差的一條。
        - `fc*_weight_read_address`：FC 的任何暫存器 → 權重 BRAM 的位址腳(FIFO 最前面那筆 → $y\cdot n_{in}+\text{src}$)，SaltFC Part 4b 留的條件。
        - 轉接模組在 `info.txt` 叫 `adapter`(實例名 `conv_to_fc`)；合成時被攤平，`util_hier.rpt` 沒有它這一行。
- `worst.rpt`：最差 10 條路徑的逐級延遲。
- `util_synth.rpt`：合成後(布局前)的資源；比 LUT、FF 用這份。
- `bram_regs.txt`：合成後每顆 BRAM 的 `DOA_REG`、`DOB_REG`，讀出那一埠是 1 代表 $R=2$ 的第二級併進去了。
- `util.rpt`、`util_hier.rpt`：繞線後的資源，後者分到每一層。

## 注意

- 同樣的輸入重跑會得到一模一樣的結果；但 RTL 或參數有一點改動，布局就可能不同，單次結果的變動約 ±0.2 ns，不能拿差 0.1~0.2 ns 下快慢的結論。
- 布局後的 FF 數不拿來比：BRAM 輸出暫存器每次搬出去的數量不同(vivado-usage skill 第 10 節)。

## 比較做法時的量測(單層)

- 規劃 Part 8 各種做法時用的，腳本沒有進 repo，每次在 session 暫存目錄重寫。
- non-project 模式，不動 `.xpr`。每組參數一個包裝 module：port 位寬寫死、例化 `SaltConv` 帶入整組參數，資料檔用絕對路徑。
- 6 組設定：訓練端 conv1、conv2 × 繞回、飽和(參數照 `run_tb_salt_conv.tcl` 的前 4 組)，加上 conv2 改成 K3 S1 P1(輸出 17×17，M=3)的繞回、飽和，沿用 conv2 的權重、門檻、衰減表。
    - 加 M=3 的理由：計算第 2 級有 `ConvSpikeSelect`、「還有沒有剩」，會隨 $M^2$ 變長。
- 管線設定：(R, C, OVERLAP) 跟 `run_tb_salt_conv.tcl` 的 7 種相同(R1C1、R2C1 不重疊/重疊、R1C2 不重疊/重疊、R2C2 不重疊/重疊)。
- Tcl 步驟：
    - `read_verilog -sv` 讀 `sources_1/new/` 底下 `lib/`、`conv/` 的全部 `.sv` 跟包裝 module。
    - `synth_design -top <包裝> -part xck26-sfvc784-2LV-c -lint`，接著 `catch {close_design}`(`-lint` 跑完沒有開著的設計)。
    - `synth_design -top <包裝> -part xck26-sfvc784-2LV-c -mode out_of_context`。
    - `create_clock -period $period -name clk [get_ports clk]`；除了 `clk` 的輸入、全部輸出 `set_input_delay 0`、`set_output_delay 0`。
    - `opt_design`、`place_design`、`route_design`。
    - `report_timing_summary`、`report_timing -max_paths 1`(最長路徑)、`report_timing -from [get_ports out_ready]`、`report_utilization`(加 `-hierarchical` 看各模組)。
    - C=2 時另外看計算第 1 級(`report_timing -to` 切點暫存器)、第 2 級(`-from` 切點暫存器)；到 BRAM 讀位址(`-to` RAMB 的 `ADDR*` 腳)；前 10 條最長路徑(`-max_paths 10 -nworst 1`)。
- 乘法用 DSP 時查每顆 DSP 的 `PREG`：切點暫存器 `stage_decayed` 併進 DSP 時是 1。併進去之後「`-to` 切點暫存器」只剩 `stage_weight_code`，第 1 級要看最長路徑或 `-to` DSP。
- $R=2$ 要確認輸出暫存器：合成完(布局前)跟繞線後各查一次每顆 BRAM 的 `DOB_REG`；繞線後變 0 可能是布局搬出去的，看 log 有沒有 `Physopt 32-665`。
- 單獨合成子模組用 out-of-context(`synth_design -mode out_of_context`)，不然 port 會被當成晶片接腳算進 IOB。
- 最高時脈(2026-10-21 起，照 UG949「Assessing the Maximum Frequency of the Design」)：
    - 目標週期壓在預期時脈附近，每組跑幾個不同的目標(例如預期 ±0.4 ns 取 5 個)，每次重跑合成 + 布局繞線。
    - $\text{FMAX} = \max_i 1000/(T_i-\text{WNS}_i)$ MHz，$T_i$ 是第 $i$ 次的目標週期；必要時另列平均。不要壓到違規很大，實作工具會自動降低努力程度。
    - 比較兩個版本時，兩邊用同一組目標週期。
    - 單一 10 ns 目標的結果只能看最長路徑在哪、資源多少，不能拿來比快慢：餘裕 3~4 ns 時布局沒有壓力，同一份電路兩次可以差 0.8 ns(vivado-usage skill 第 12 節)。
    - 目標固定(現在是 5 ns)時只跑目標週期看過不過，不掃最高時脈。
- hold 有 -0.18 ns 的違規是輸入 port 進 FIFO，out-of-context 把輸入延遲設 0 造成的，不用管。
- 一次平行開 8 個 batch Vivado 時，出現過一組 `opt_design` 報空白的 `Synth 20-411`，單獨重跑就好。

## 量測結果

- 2026-10-21 之前(Part 7~8.x 前半)的時脈都是舊做法：固定 10 ns 目標、單次，用 $1000/(10-\text{WNS})$ 換算，偏低、單組有 ±10~20 MHz 的變動，只能看大方向。
- 每項的完整過程(實驗設計、每組數字、反向測試)在 commit `dc9b22a` 版本的 [TODO](../../Todo/csnn_pl_implementation_todo.md)，各 Part 的段落。

### 整條網路 `SaltConvFCNet`(4.8 ns，2026-11-14)

| 版本 | WNS | 最長路徑 | LUT(合成後) | FF(合成後) | BRAM | DSP |
|---|---|---|---|---|---|---|
| 繞回 | +0.301 | conv2 內：神經元 BRAM 讀出 → 計算第 1 級(乘法 DSP) | 1470(1.26%) | 859(0.37%) | 12.5(8.68%) | 12(0.96%) |
| 飽和 | +0.179 | conv1 內：計算第 2 級(加權重、飽和、比門檻)→ 停住 → 神經元 BRAM 讀取開關 | 1472(1.26%) | 817(0.35%) | 12.5(8.68%) | 12(0.96%) |

- 12 顆乘法 DSP 都套上 `DONT_TOUCH`。布局沒有搬 BRAM 輸出暫存器(`Physopt 32-670 No setup violation found`)，繞線後的 FF 就是合成後的數字；每顆 BRAM 讀出那一埠的輸出暫存器都併進去了。
- 每組路徑最差的一條(餘裕，ns)：

| 路徑 | 繞回 | 飽和 |
|---|---|---|
| conv1 送事件進 conv2 的 FIFO | +1.054 | +0.540 |
| conv2 反壓 conv1 | +1.672 | +1.573 |
| conv2 送事件進轉接模組 | +1.051 | +1.108 |
| 轉接模組反壓 conv2 | +1.928 | +1.959 |
| 轉接模組送事件進 SaltFC 的 FIFO | +1.906 | +2.071 |
| SaltFC 反壓轉接模組 | +3.143 | +3.232 |
| SaltFC 反壓經轉接模組到 conv2 | +1.812 | +1.731 |
| SaltFC 膜電位輸出 → 膜電位暫存器 | +2.884 | +2.913 |
| conv1 內 | +0.382 | +0.179 |
| conv2 內 | +0.301 | +0.206 |
| 轉接模組內 | +3.737 | +3.838 |
| SaltFC 內 | +0.608 | +0.443 |
| SaltFC 讀權重位址 | +1.183 | +1.233 |

- 各層(繞線後，繞回 / 飽和)：

| 模組 | LUT | FF | BRAM | DSP |
|---|---|---|---|---|
| conv1 | 569 / 573 | 214 / 214 | 5 | 4 |
| conv2 | 593 / 588 | 207 / 207 | 3 | 4 |
| SaltFC | 213 / 217 | 252 / 240 | 4.5 | 4 |
| 膜電位暫存器 | 0 / 0 | 157 / 127 | 0 | 0 |
| 轉接模組 | 攤平，沒有單獨一行 | 29(總數減各層) | 0 | 0 |

- 跟分段量的比：兩層串接 +0.281 / +0.205、conv2 → 轉接模組 → SaltFC +0.333 / +0.379、SaltFC 單層 +0.760 / +0.622；整條的差在單次 ±0.2 ns 的變動內，最長路徑一樣在 conv 層內，接上 FC 沒有多出更緊的路徑。
- SaltFC 讀權重位址 +1.18 以上，Part 4b 留的「卡住就把 `WeightMemory` 改成位址暫存器」不用做。

### 極限測試 `SaltStressNet`(4.8 ns，2026-11-14)

- 要回答的：BRAM 用到約一半時，各模組搶附近的 BRAM 位置，4.8 ns 還剩多少餘裕。不擋 BRAM 位置，讓工具從 144 顆裡挑；占掉其他 BRAM 的電路用到的 LUT、繞線沒有模擬，結果偏樂觀。

| 版本 | WNS | 最長路徑 | LUT(合成後) | FF(合成後) | BRAM | DSP |
|---|---|---|---|---|---|---|
| 繞回 | +0.151 | FC3(輸出層)內：$t$、$t_{last}$ → 算 $\Delta t$ → 查衰減表 → 衰減乘法 DSP | 2434(2.08%) | 1471(0.63%) | 73(50.69%) | 24(1.92%) |
| 飽和 | +0.092 | FC1 內：計算第 2 級(加權重、比門檻 → fire)→ 停住 → 28 顆權重 BRAM 的開關 | 2458(2.10%) | 1427(0.61%) | 73(50.69%) | 24(1.92%) |

- BRAM：conv1 5、conv2 3、conv3 3、FC1 30(權重 28、神經元 1、門檻 1)、FC2 30、FC3 2。FC1、FC2 的權重 32768 字 × 28 位元，Vivado 用 28 顆 BRAM 各放 1 位元(32K×1)。
- 布局時把 BRAM 輸出暫存器搬出來：繞回 14 顆 340 個 FF、飽和 16 顆 344 個 FF(繞線後 FF 1842、1783)。工具在布局時估到有路徑可能不過才做這項；實際網路是「沒有違規，不做」。
- 每個模組內最差的一條，跟實際網路比(餘裕，ns)：

| 模組 | 實際網路 繞回 | 極限測試 繞回 | 實際網路 飽和 | 極限測試 飽和 |
|---|---|---|---|---|
| conv1 | +0.382 | +0.257 | +0.179 | +0.171 |
| conv2 | +0.301 | +0.229 | +0.206 | +0.153 |
| conv3 | — | +0.242 | — | +0.136 |
| FC1 | — | +0.307 | — | +0.092 |
| FC2 | — | +0.290 | — | +0.225 |
| FC 輸出層 | +0.608 | +0.151 | +0.443 | +0.334 |

- 兩條 WNS 路徑：
    - 繞回 FC3 內：跟實際網路 SaltFC 內同一類路徑；邏輯延遲 2.538 對 2.980 ns 差不多，繞線 2.103 對 1.204 ns，多的是線變長。
    - 飽和 FC1 內：停住訊號要拉到 28 顆權重 BRAM，4.300 ns 裡繞線 2.965 ns(69%)。SaltFC Part 8 單層(權重 4 顆 BRAM)同一類路徑飽和版 +0.453。
- 跨層最緊：FC1 送 spike 進 FC2 +0.492 / +0.312、conv2 送事件進 conv3 +0.462 / +0.479，都不是最長路徑。讀權重位址 FC1 +0.705 / +0.832、FC2 +0.589 / +0.896，權重大到 28 顆 BRAM 也沒卡住。
- 解讀：
    - BRAM 用到一半，4.8 ns 兩版都過；換成 5 ns，同一份布局還剩 0.29~0.35 ns。
    - 整體 WNS 比實際網路少 0.15 / 0.09，在單次 ±0.2 ns 的變動內，光看 WNS 不能說互搶吃掉多少。
    - 掉得超過變動範圍的兩處都在 FC：FC 輸出層的衰減乘法路徑(+0.608 → +0.151，多的是繞線)、停住訊號拉到權重 BRAM 的路徑(同類路徑 +0.453 → +0.092)。conv 層幾乎沒變。
    - 只跑 4.8 ns 一次只能說過不過、大概剩多少；要知道能跑多快，照「比較做法時的量測」的最高時脈做法多跑幾個週期。
- 沒做的：沒有模擬(FC 接 FC 在模擬裡沒跑過)，沒有跟訓練端比對。

### FC 權重的 BRAM 數是一階一階跳的(2026-11-14)

- 極限測試原本想把 FC1 的輸出從 512 加寬到 576，把 BRAM 從 73 補到 84 附近，合成出來是 129：
    - 512 時 FC1 權重 128 列 × 256 = 32768 字，每字 28 位元，28 顆 BRAM(32K×1)。
    - 576 時 144 列 × 256 = 36864 字，Vivado 把唯讀記憶體的深度補到 2 的次方(ROM 報告寫 65536x28)，每個位元 2 顆，56 顆；FC2 的輸入變 576，一樣 56 顆。
    - 補成 65536 字時兩顆串接，$R=2$ 的第二級併不進 BRAM(`Synth 8-7052` 報了 100 次)。
- 所以 $n_{col}=4$ 時 FC 權重的 BRAM 數只看深度落在哪個 2 的次方之內；設計大的 FC 時，權重深度(列數 × $n_{in}$)最好剛好在 2 的次方以內。
- 同一次 FC2 的 $n_{in}=576$、列數 64，位址 $y\cdot576+\text{src}$ 合成成 1 顆 DSP；之前的 FC($n_{row}=3$)是 LUT。

### 合成共用流程改寫的驗證(2026-11-14)

- `synth_salt_conv_net.tcl` 改成用 `synth_common.tcl`，讀 RTL 多了 `fc/`。同一份 RTL，改前(git HEAD 的腳本)、改後各跑繞回、飽和：`info.txt`、`util.rpt`、`util_hier.rpt`、`timing_summary.rpt`、`worst.rpt` 除了表頭(日期、指令)逐行相同；跨層兩份報告只差表頭指令多了 `-quiet`，所以分隔線長度不同。
- 結果跟 2026-10-27 相同(繞回 +0.281、飽和 +0.205)：conv 的 RTL 之後沒改。

### 現行 RTL：兩層串接(這支腳本，4.8 ns，2026-10-27)

| 版本 | WNS | 最長路徑 | conv1 輸出 → conv2 | conv2 反壓 → conv1 | LUT | FF | BRAM | DSP |
|---|---|---|---|---|---|---|---|---|
| 繞回 | +0.281 | conv2 內：神經元 BRAM 讀出 → 計算第 1 級(乘法 DSP) | +0.892 | +1.494 | 1196(1.02%) | 421(0.18%) | 8(5.56%) | 8(0.64%) |
| 飽和 | +0.205 | conv1 內：神經元 BRAM 讀出 → 計算第 1 級(乘法 DSP) | +0.708 | +1.712 | 1199(1.02%) | 421(0.18%) | 8(5.56%) | 8(0.64%) |

- 8 顆乘法 DSP 都套上 `DONT_TOUCH`。百分比的分母是 xck26 整顆。
- 這次是 SaltFC Part 6 之後：`NeuronUpdate` 的 ① 拆成 `lib/DecayLookup`，SaltConv 每個 bank 例化 `DecayLookup` + `NeuronUpdate`。
    - 合成後(布局前)跟改動前比：`report_utilization` 逐行相同(LUT 繞回 1233、飽和 1231，FF 421，BRAM 8，DSP 8)，每顆 BRAM 的 `DOA_REG`/`DOB_REG` 相同。
    - 這次布局沒有搬 BRAM 輸出暫存器(`Physopt 32-670 No setup violation found. BRAM Register Optimization was not performed.`)，所以 FF 就是合成後的 421。
    - 改動前(Part 5 之後，同一天)：繞回 +0.283、LUT 1207、FF 597；飽和 +0.254、LUT 1197、FF 525。FF 多的是布局時搬出的神經元 BRAM 輸出暫存器(繞回 6 顆 176 個、飽和 4 顆 104 個)。WNS 差在單次 ±0.2 ns 的變動內，不拿來說時序變好或變差。
    - 再之前(2026-10-25，Part 4a 之後)：繞回 +0.319、LUT 1243、FF 421；飽和 +0.128、LUT 1290、FF 679。
    - 4.8 ns 這次 WNS 比改動前小，所以改動前(git HEAD 取出)、改動後各再跑一次 4.6 ns(比 4.8 緊，逼布局找好的)。FMAX = 1000/(目標 − WNS)，報兩個目標裡最好的(UG949)：

| 版本 | RTL | 4.8 ns WNS | 4.6 ns WNS | 4.6 ns 布局後 LUT / FF | FMAX(兩次取最好) |
|---|---|---|---|---|---|
| 繞回 | 改動前 | +0.283 | +0.065 | 1250 / 684 | 221.4 MHz |
| 繞回 | 改動後 | +0.281 | +0.300 | 1205 / 625 | 232.6 MHz |
| 飽和 | 改動前 | +0.254 | +0.022 | 1246 / 622 | 220.0 MHz |
| 飽和 | 改動後 | +0.205 | +0.344 | 1240 / 665 | 235.0 MHz |

    - 4.8 ns 改動後略差，4.6 ns 改動後比較好，兩邊差距都在 0.3 ns 以內，是同一份電路布局的變動，不是改動造成的；不拿來說時序變好。
    - 4.6 ns 四次布局都有把神經元 BRAM 的輸出暫存器搬到外面的 FF，所以 FF 比合成後的 421 多。
- 最長路徑兩版都是「神經元 BRAM 讀出 → 計算第 1 級的乘法 DSP」，跟改動前同一類。
- 層與層之間兩條都不是最長路徑：
    - conv1 輸出 → conv2：起點 conv1 的乘法 DSP 輸出(`rounded_product`)，終點 conv2 FIFO 的 `full` 暫存器的 CE(兩版；Part 5 那次繞回版是 `empty`)。
    - conv2 反壓 → conv1：起點 conv2 的 `clearing` 暫存器，終點 conv1 神經元 BRAM 的寫入開關 `ENBWREN`。
    - 2026-10-25 那次：conv1 輸出 → conv2 起點是 `cut_after_step2`，終點還有寫指標、distributed RAM 的 WE；conv2 反壓 → conv1 起點還有 `full`，終點是 BRAM 讀取開關、管線暫存器的 CE。

### 乘法一律用 DSP(2026-10-21)

- Vivado 自己選時 $w$=9 用 LUT 做乘法，這一段時序一直最緊；DSP 用量很少(整顆 1248 個，兩層 8 個)，各層資源類型也一致。
- 兩層串接，4.8 ns，還沒擋 DSP 暫存器搬動：

| 版本 | WNS | 最長路徑 | conv1 輸出 → conv2 | conv2 反壓 → conv1 | LUT | FF | BRAM | DSP |
|---|---|---|---|---|---|---|---|---|
| 繞回 | +0.260 | conv1 內：FIFO 讀指標 → BRAM 讀位址 | +0.725 | +1.464 | 1266 | 620 | 8 | 8 |
| 飽和，Vivado 自己選 | −0.118 | conv1 內：計算第 1 級(LUT 乘法) | +0.211 | +1.551 | 1607 | 645 | 8 | 4 |
| 飽和，強制 DSP | +0.028 | conv1 內：計算第 1 級，進 DSP 後被搬出來的切點暫存器 | +0.539 | +1.490 | 1276 | 631 | 8 | 8 |

- 繞回版兩層、飽和版 conv2 本來就是 DSP，所以只重跑飽和版。
- 決定之前的單模組量測(2026-10-11，`NeuronUpdate` 不拆管線，輸入輸出各包一層暫存器)：LUT 乘法每組快 0.14~0.43 ns，代價是每顆多 70~95 LUT、6~10 CARRY8；DSP 慢在純組合邏輯穿過 DSP 內部每一級。拆管線、切點併進 PREG 之後這個比較不成立。

### 擋住乘法 DSP 的暫存器搬動(2026-10-21~22)

- 誰搬的：`place_design` 的 Physical Synthesis In Placer(PSIP)裡的 DSP Register optimization，預設開著，在 Global Place Phase 2(延遲用估的)決定。
- 飽和版、4.8 ns、同一份 RTL 和流程(同樣輸入重跑結果完全相同，兩次可以直接比)：

| | 預設(搬了) | 8 顆乘法 DSP 設 `DONT_TOUCH` |
|---|---|---|
| 布局後 WNS | +0.216 | +0.317 |
| 繞線後 WNS | +0.028 | +0.136 |
| bank (1,0) 進切點(計算第 1 級) | +0.028 | +0.144 |
| bank (1,0) 出切點(計算第 2 級 → `stall` → BRAM 讀取開關) | +0.344 | +0.255 |

- 搬了之後進切點那段慢 0.116 ns、出切點那段快 0.089 ns；不准搬時本來就是進切點比較緊，搬了等於把延遲加到比較緊的一邊。
- `place_design -psip_options`(只關單一項)xck26 不支援(`Vivado_Tcl 4-2585`)，所以用 `DONT_TOUCH`。
- 單次布局的結果，只能說這一次搬了比沒搬差，不保證每次都差。

### 單層 4.8 ns(2026-10-21，`fa64a5d`)

- 用「比較做法時的量測」的包裝 module 量，R2C2 重疊，每組一次；比「乘法一律用 DSP」早，conv1 飽和的乘法還是 LUT。

| 設定 | WNS | LUT | FF | BRAM | DSP |
|---|---|---|---|---|---|
| conv1 繞回 | +0.351 | 606(0.52%) | 214(0.09%) | 5(3.47%) | 4(0.32%) |
| conv1 飽和 | +0.080 | 976(0.83%) | 352(0.15%) | 5(3.47%) | 0(0%) |
| conv2 繞回 | +0.308 | 638(0.54%) | 267(0.11%) | 3(2.08%) | 4(0.32%) |
| conv2 飽和 | +0.232 | 620(0.53%) | 207(0.09%) | 3(2.08%) | 4(0.32%) |
| M=3 繞回 | +0.287 | 1314(1.12%) | 551(0.24%) | 10(6.94%) | 9(0.72%) |
| M=3 飽和 | +0.242 | 1327(1.13%) | 490(0.21%) | 10(6.94%) | 9(0.72%) |

- 最長路徑：4 組是計算前一半(到併進 DSP 的切點暫存器)；conv1 飽和是 FIFO 讀指標 → 讀不讀 → BRAM 讀取開關；M=3 繞回是 FIFO → CandidateGrid → BRAM 讀位址。
- 布局後的 FF 不拿來比：`place_design` 每次把幾顆 BRAM 的輸出暫存器搬成一般 FF 都不一樣，差 50~200 個。

### 兩層串接的延遲(模擬拍數，2026-10-22)

- `tb_salt_conv_net_ready_high`(下游一直收，輸入用最快速度餵)，10 筆 test 樣本，每筆 2000 筆輸入事件。拍數定義見 `tb_salt_conv_net_common.svh` 檔頭。

| 項目 | 繞回版 | 飽和版 |
|---|---|---|
| reset 之後清除神經元記憶體 | 648 拍 | 648 拍 |
| 第一筆輸入到全部做完 | 40050 ~ 41256 拍 | 40429 ~ 41512 拍 |
| 最後一筆輸入被收下 → 全部做完 | 559 ~ 768 拍 | 559 ~ 768 拍 |
| conv1 有東西要送、conv2 不收的拍數 | 23656 ~ 24827 | 24024 ~ 25080 |
| 對照：conv1 單獨跑 | 16124 ~ 16178 | 16130 ~ 16178 |
| 對照：conv2 單獨跑 | 40041 ~ 41239 | 40421 ~ 41495 |

- 串接比 conv2 單獨跑只多 8~33 拍：瓶頸是 conv2(每筆樣本收到約 2500 筆事件，每筆 16 個 $o_c$)，FIFO 加深不會變快。
- 5 ns 時脈下一筆樣本約 0.21 ms；這 10 筆樣本最後一筆事件的時間戳記是 67~151 ms。
- 下游會擋時：第一筆到全部做完 41731 ~ 43404 拍(`ready_random`)、52113 ~ 58099 拍(`ready_burst`)。

### 設計決定的量測依據(2026-10-07~21)

| 決定 | 量到的 | 時間 |
|---|---|---|
| `WeightMemory` 指定 `rom_style = "block"` | 不指定時 conv1(深度 16)做成 32 LUT + 63 FF、conv2 是 1 個 RAMB36；指定後都是 1 個 RAMB36 | 2026-10-07 |
| `ConvSpikeSelect` 用旋轉法，不用比較鍵法 | LUT 約 1/3~1/2、延遲約一半(conv1：17 對 55 LUT、1.05 對 1.98 ns；M=4：147 對 386 LUT) | 2026-10-11 |
| `EventFIFO` 資料陣列的寫入不放在有 reset 的 `always_ff` | 放在一起時推不出 distributed RAM，conv1 589 個 FF 裡約 464 個是 FIFO；改完 18 個 LUT 當記憶體 | 2026-10-12 |
| 管線化(算完那一拍直接送) | 沒有 fire 的 $o_c$ 快 1.8~1.9 倍，時脈只掉 3~11%；讀位址不等推進的判斷是關鍵(+7~15 MHz) | 2026-10-15 |
| 只做 $R=2$ 不划算 | 時脈 +2~10 MHz，一個沒 fire 的 $o_c$ 從 9.4 ns 變 18~19 ns | 2026-10-18 |
| BRAM 記憶體陣列加 `keep_hierarchy = "soft"` | 上層攤平時 $R=2$ 的輸出暫存器併不進 BRAM(`Synth 8-7052`)；加了之後 5 顆全部併入 | 2026-10-18 |
| $C=2$ 切在 ② 之後 | 6 組裡 5 組最快，兩級最平均；切在 ① 時暫存器被 DSP 的 AREG、BREG 吸收 | 2026-10-18 |
| $o_c$ 重疊用 A(停住)，不用 B(丟掉重讀) | B 時脈相同或略低(R2C2 重疊 6 組平均 158.3 對 158 MHz)、FF 3259 對 1933、conv1 拍數多 1~2% | 2026-10-19 |
| 時序改善 A+B($\Delta t=0$ 乘 1.0、`fires_left` 只看個數) | R2C2 重疊 6 組平均 160.8 → 175.5 MHz；C=2 的切點併進 DSP 的 PREG | 2026-10-21 |
| 權重選 tap 保留 `tap < K` 檢查(當時在 `WeightTapSelect`，2026-10-27 起寫在 SaltConv 每個 bank 的 generate 區塊) | K=3、M=2 單獨合成：保留 84 LUT，拿掉 98 LUT | 2026-10-21 |
