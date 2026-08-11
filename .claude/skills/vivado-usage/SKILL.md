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

- 不要在裸的 `@(posedge clk)` 之後立刻驅動/取樣訊號,會跟 DUT 自己 `always_ff` 的 NBA 更新競態(race)。統一用 `tick()`(`@(posedge clk); #1;`)當作驅動/取樣的唯一入口。
- 檢查「握手是否成立」要在**跨越那個 clock edge 之前**取樣 ready 訊號,不要事後才看——事後看到 ready 掉下來,無法分辨是「因為剛被吃掉了」還是「其他原因本來就要掉」。
- 對下游長時間持有 `tready=0` 同時又要送一長串資料時,不要用單一 loop 從頭做到尾(送到 FIFO 滿會死鎖),改用 `fork...join`:一支負責送、一支平行觀察反壓再放行 `tready`。
