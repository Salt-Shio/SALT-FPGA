# SaltConv 合成與實作流程

量時序、資源用的流程，跟用到的每一個參數；量測結果在最後的「量測結果」。

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
| `NeuronUpdate` | 乘積、捨入加 `use_dsp = "yes"` | 乘法一律用 DSP(2026-10-21 決定，見「量測結果 → 乘法一律用 DSP」) |
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
    - 2026-10-21 飽和版 4.8 ns 實測：預設搬了 1 顆，繞線後 +0.028 ns；擋住之後 +0.136 ns。對照實驗見「量測結果 → 擋住乘法 DSP 的暫存器搬動」。
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

## 比較做法時的量測(單層)

- 規劃 Part 8 各種做法時用的，腳本沒有進 repo，每次在 session 暫存目錄重寫。
- non-project 模式，不動 `.xpr`。每組參數一個包裝 module：port 位寬寫死、例化 `SaltConv` 帶入整組參數，資料檔用絕對路徑。
- 6 組設定：訓練端 conv1、conv2 × 繞回、飽和(參數照 `run_tb_salt_conv.tcl` 的前 4 組)，加上 conv2 改成 K3 S1 P1(輸出 17×17，M=3)的繞回、飽和，沿用 conv2 的權重、門檻、衰減表。
    - 加 M=3 的理由：計算第 2 級有 `SpikeSelect`、「還有沒有剩」，會隨 $M^2$ 變長。
- 管線設定：(R, C, OVERLAP) 跟 `run_tb_salt_conv.tcl` 的 7 種相同(R1C1、R2C1 不重疊/重疊、R1C2 不重疊/重疊、R2C2 不重疊/重疊)。
- Tcl 步驟：
    - `read_verilog -sv` 讀 `sources_1/new/` 的全部 `.sv` 跟包裝 module。
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

### 現行 RTL：兩層串接(這支腳本，4.8 ns，2026-10-22)

| 版本 | WNS | 最長路徑 | conv1 → conv2 | conv2 → conv1 | LUT | FF | BRAM | DSP |
|---|---|---|---|---|---|---|---|---|
| 繞回 | +0.213 | conv2 內：計算第 1 級(到 DSP 的切點) | +0.553 | +1.149 | 1260(1.08%) | 668(0.29%) | 8(5.56%) | 8(0.64%) |
| 飽和 | +0.131 | conv2 內：FIFO 讀指標 → BRAM 讀位址 | +0.358 | +1.452 | 1282(1.09%) | 655(0.28%) | 8(5.56%) | 8(0.64%) |

- 8 顆乘法 DSP 都套上 `DONT_TOUCH`(PSIP 摘要表 DSP Register 列 Dont Touch 8)。百分比的分母是 xck26 整顆。
- 層與層之間兩條都不是最長路徑：
    - conv1 → conv2：起點 conv1 的 `cut_after_step2` 暫存器，終點 conv2 FIFO 的 `full`、`empty`、寫指標、distributed RAM 的 WE。
    - conv2 → conv1：起點 conv2 的 `full` 或 `clearing` 暫存器，終點 conv1 的 BRAM 讀取開關、管線暫存器的 CE。

### 乘法一律用 DSP(2026-10-21)

- Vivado 自己選時 $w$=9 用 LUT 做乘法，這一段時序一直最緊；DSP 用量很少(整顆 1248 個，兩層 8 個)，各層資源類型也一致。
- 兩層串接，4.8 ns，還沒擋 DSP 暫存器搬動：

| 版本 | WNS | 最長路徑 | conv1 → conv2 | conv2 → conv1 | LUT | FF | BRAM | DSP |
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
| `SpikeSelect` 用旋轉法，不用比較鍵法 | LUT 約 1/3~1/2、延遲約一半(conv1：17 對 55 LUT、1.05 對 1.98 ns；M=4：147 對 386 LUT) | 2026-10-11 |
| `EventFIFO` 資料陣列的寫入不放在有 reset 的 `always_ff` | 放在一起時推不出 distributed RAM，conv1 589 個 FF 裡約 464 個是 FIFO；改完 18 個 LUT 當記憶體 | 2026-10-12 |
| 管線化(算完那一拍直接送) | 沒有 fire 的 $o_c$ 快 1.8~1.9 倍，時脈只掉 3~11%；讀位址不等推進的判斷是關鍵(+7~15 MHz) | 2026-10-15 |
| 只做 $R=2$ 不划算 | 時脈 +2~10 MHz，一個沒 fire 的 $o_c$ 從 9.4 ns 變 18~19 ns | 2026-10-18 |
| BRAM 記憶體陣列加 `keep_hierarchy = "soft"` | 上層攤平時 $R=2$ 的輸出暫存器併不進 BRAM(`Synth 8-7052`)；加了之後 5 顆全部併入 | 2026-10-18 |
| $C=2$ 切在 ② 之後 | 6 組裡 5 組最快，兩級最平均；切在 ① 時暫存器被 DSP 的 AREG、BREG 吸收 | 2026-10-18 |
| $o_c$ 重疊用 A(停住)，不用 B(丟掉重讀) | B 時脈相同或略低(R2C2 重疊 6 組平均 158.3 對 158 MHz)、FF 3259 對 1933、conv1 拍數多 1~2% | 2026-10-19 |
| 時序改善 A+B($\Delta t=0$ 乘 1.0、`fires_left` 只看個數) | R2C2 重疊 6 組平均 160.8 → 175.5 MHz；C=2 的切點併進 DSP 的 PREG | 2026-10-21 |
| `WeightTapSelect` 保留 `tap < K` 檢查 | K=3、M=2 單獨合成：保留 84 LUT，拿掉 98 LUT | 2026-10-21 |
