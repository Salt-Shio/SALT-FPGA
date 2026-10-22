# SaltConv 合成與實作流程

量時序、資源用的流程，跟用到的每一個參數。量測結果記在 [TODO](../../Todo/csnn_pl_implementation_todo.md)(Part 8.x、Part 9)，這裡只寫怎麼跑。

## 範圍

- 對象：兩層串接 `SaltConvNet`(訓練端 conv1 → conv2)，繞回版、飽和版各一份。
- 這是量測用的流程，不是正式整合：
    - 不接腳位、不出 bitstream(out-of-context)。
    - 時脈、輸入輸出延遲是量測用的假設，見「約束」。
- Vivado 專案 `SaltConv.xpr` 裡的 `synth_1`、`impl_1` 沒有在用(`synth_1` 的 top 還是 `CandidateGrid`)，量測一律用下面的腳本。

## 檔案

| 檔案 | 內容 |
|---|---|
| `SaltConv/scripts/synth_salt_conv_net.tcl` | 整個流程：讀 RTL、合成、約束、opt / place / route、出報告 |
| `SaltConv/SaltConv.srcs/constrs_1/new/salt_conv_impl.xdc` | 只給實作用的約束(目前只有乘法 DSP 的 `DONT_TOUCH`) |
| `SaltConv/SaltConv.srcs/sources_1/new/*.sv` | RTL，全部讀進來 |
| `SaltConv/SaltConv.srcs/sources_1/mem/<量化版本>/conv{1,2}_*.mem` | 權重、門檻、衰減表 |

## 怎麼跑

```powershell
cd D:\Project\SALT-FPGA\SaltConv\SaltConv.runs
vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/synth_salt_conv_net.tcl -tclargs saturate 4.8
```

- 第一個參數：`wrap` 或 `saturate`。
- 第二個參數：時脈週期(ns)，不給就是 4.8。
- 輸出在 `SaltConv.runs/net_<版本>_<週期>/`，`SaltConv.runs` 不進版控。
- 不碰 `SaltConv.xpr`，可以跟模擬同時跑；兩個合成同時跑碰過 `Designutils 20-411`(vivado-usage skill 第 11 節)，一次跑一個。
- agent 從自己的 shell 跑要先拿掉 `NoDefaultCurrentDirectoryInExePath`(vivado-usage skill 8.6)。

## 工具

- Vivado 2025.2，non-project 模式(不開專案，全部用 Tcl 指令)。
- part `xck26-sfvc784-2LV-c`(KV260 的 K26 SOM)。

## 步驟與參數

| 步驟 | 指令 | 指定的參數 | 其他 |
|---|---|---|---|
| 讀 RTL | `read_verilog -sv` | `sources_1/new/*.sv` 全部 | |
| 合成 | `synth_design` | `-top SaltConvNet`、`-part`、`-mode out_of_context`、每個設計參數一個 `-generic` | 其餘用預設，見下表 |
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
| `NeuronUpdate` | 乘積、捨入加 `use_dsp = "yes"` | 乘法一律用 DSP(2026-10-21 決定，見 TODO Part 9) |
| `NeuronUpdate` | 衰減表 `rom_style = "distributed"` | 用 LUT 查表，$M\times M$ 份同一拍各查各的 |
| `EventFIFO` | `ram_style = "distributed"` | 用 LUT 當記憶體 |
| `NeuronMemoryArray` | `ram_style = "block"`、模組 `keep_hierarchy = "soft"` | 神經元記憶體用 BRAM；保留模組邊界，$R=2$ 的第二級才併得進 BRAM 輸出暫存器(vivado-usage skill 第 10 節) |
| `WeightMemory` | `rom_style = "block"`、模組 `keep_hierarchy = "soft"` | 權重用 BRAM，原因同上 |

## 約束

| 約束 | 值 | 為什麼 |
|---|---|---|
| `create_clock -period` | 4.8 ns(可改) | 目標 5 ns(200 MHz)，手動留 0.2 ns 餘裕；只跑這個週期看過不過，不掃最高時脈 |
| `set_input_delay` / `set_output_delay` | 0 | 把網路的輸入輸出 port 當成邊界上的暫存器，只量設計內部的路徑；整合時要換成實際上下游的約束 |
| `salt_conv_impl.xdc` | 乘法 DSP(`*neuron_update/rounded_product`)設 `DONT_TOUCH` | 見下面；腳本確認 8 顆都套上，沒套上就報錯停止 |

- 為什麼擋住乘法 DSP：
    - `place_design` 的實體最佳化有一項 DSP Register optimization，會在布局初期用估計的延遲，把 DSP 裡的切點暫存器(PREG)搬到外面的一般暫存器。
    - 2026-10-21 飽和版 4.8 ns 實測，同一份 RTL、同一套流程：
        - 預設：搬了 1 顆，那顆的計算第 1 級變成最長路徑，繞線後 +0.028 ns。
        - 擋住：布局最佳化的其他項目只差 1 顆 BRAM 的暫存器搬動，繞線後 +0.136 ns。
    - 只擋這幾顆 DSP；BRAM 輸出暫存器的搬動照常讓工具決定。
    - cell 名稱裡 `neuron_update` 前面是 `.`(generate 區塊用點連接，例如 `conv1/row_banks[0].col_banks[0].neuron_update/rounded_product`)，條件寫成 `*/neuron_update` 會一顆都對不到，Vivado 只給 critical warning、照樣跑完(2026-10-22 第一次跑就這樣)。
    - 這個約束檔只在實作用：寫進 RTL 的 `dont_touch` 會在合成時就生效，可能連「切點暫存器併進 DSP」都擋掉(沒實測)。正式專案加這個檔案時要設 `USED_IN_SYNTHESIS false`。

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

## 看結果

- `info.txt`：
    - `route wns`：繞線後最差的餘裕，正的就是這個週期過了。
    - `dsp dont_touch`：被約束擋住的 DSP 數，確認約束有套上。
    - `conv1_to_conv2`、`conv2_to_conv1`：跨層兩條路徑最差的一條；`conv1_inside`、`conv2_inside`：層內最差的一條。
- `worst.rpt`：最差 10 條路徑的逐級延遲。
- `util.rpt`、`util_hier.rpt`：資源，後者分到每一層。

## 注意

- 同樣的輸入重跑會得到一模一樣的結果；但 RTL 或參數有一點改動，布局就可能不同，單次結果的變動約 ±0.2 ns，不能拿差 0.1~0.2 ns 下快慢的結論。
- 布局後的 FF 數不拿來比：BRAM 輸出暫存器每次搬出去的數量不同(vivado-usage skill 第 10 節)。
