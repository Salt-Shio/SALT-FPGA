# CSNN on FPGA 實作調查

調查日期：2026-08-20
範圍：CSNN (Convolutional Spiking Neural Network) 在 FPGA 上的實作方式，重點在膜電位更新與 BRAM banking 策略。

專案目標平台：AMD Kria KV260 (XCZU5EV) + Prophesee GENX320 事件相機。詳見專案記憶 `project_targets`。
XCZU5EV 資源：144 個 BRAM36 block (~5.1Mb)、1248 DSP、117120 LUT。GENX320 感測器介面約占 50 個 BRAM block，CSNN 加速器本體可用約 94 個 BRAM36 block。

## 膜電位規格與更新方式

| 專案 | 膜電位精度 | 更新方式 | 特殊優化 |
|---|---|---|---|
| Spiker / Spiker+ | 16-bit (3 frac + 13 int) | Clock-driven，每 cycle 都更新 | V_rest 平移到 0V 省一項運算；τ/dt 取 2^-10，除法變 shift |
| DeepFire2 | 8-bit 權重，累加後比 threshold | Clock-driven，AND 用暫存器同步 reset 實現（不占 LUT） | 無獨立乘法器，spike 是二值；輸入層用 DSP 做 8-bit 乘法 |
| FireFly v2 | 不落地儲存整層膜電位 | On-the-fly：spike 即算即生，time loop 移到 neuron loop 內側 | 兩階段 neurodynamics unit 處理跨 timestep 遞迴依賴 |
| SCNN (multi-structure) | 4-bit (1 sign + 1 int + 2 frac) | Clock-driven | neuron-state BRAM 只存一整行 pixel 份量，不存整張 feature map |
| snn-fpga (開源) | 8-bit | 序列化，每 cycle 處理一個 16-神經元 tile | tile 依 postsynaptic index 排序存放 |

## BRAM / URAM Banking 策略

| 專案 | Banking 粒度 | 取捨重點 |
|---|---|---|
| DeepFire2 | 每個平行 PE/kernel core 配獨立 BRAM block；例：112 神經元/4kB BRAM，切 8 bank，14 神經元/bank | 記憶體切淺 = 平行度高；切深 = 省資源但吞吐降。深層(feature map小)用 URAM（級聯後頻率影響小），淺層(feature map大)用 BRAM |
| SCNN | 每個平行運算 thread 各自一塊 neuron-state BRAM + weight BRAM | thread 級別 banking，行級（非整層）膜電位儲存，大幅降低大 feature map 的記憶體需求 |
| FireFly v2 | 不做傳統 banking，靠 dataflow 重排避免存整層 | systolic array + slow-to-fast gearbox（運算陣列跑 2 倍頻）換取免存膜電位 |
| snn-fpga | 16 神經元打包成一個 128-bit word/tile | 省 BRAM 數量，但犧牲平行存取，序列化處理 |

## 資源 / 效能數字

| 專案 | FPGA | 頻率 | BRAM | 備註 |
|---|---|---|---|---|
| Spiker | Artix-7 | 100 MHz | 45/140 (32%) | 400 神經元全平行，215 μs/image (MNIST) |
| DeepFire2 | UltraScale+ (多 SLR) | 最高 600 MHz | 依層動態分配 (BRAM+URAM) | ImageNet 可跑，>1500 fps |
| FireFly v2 | UltraScale | 系統 300MHz / 運算陣列 500-600MHz | 最小化（免存膜電位） | DSP 效率 1.33x DeepFire2，功耗效率 1.42x 現有最強方案 |
| SCNN (LeNet-small) | 未指名型號 | 100 MHz | 60.5 blocks | 1605 fps, 0.65 mJ/image, 99.1% MNIST acc |
| snn-fpga | Basys3 (Artix-7, 低階板) | 100 MHz | 40.5/140 (~29%) | 0.52 ms/MNIST image |

## 共通模式（跨所有論文）

- LIF 模型為主流，浮點全部換 fixed-point。
- τ 取 2 的冪次 → shift 取代除法。
- 二值 spike → 突觸乘法退化成 AND，或直接用權重累加取代乘加。
- 到達 threshold 觸發 spike → 用同步 reset 訊號歸零，不用額外運算。
- Clock-driven（每 cycle 更新）是主流，event-driven 較少見（複雜度高、但省功耗）。

## 各論文架構重點

### DeepFire2 — split-kernel mapping
- 針對超大型網路（ImageNet 等級）與多 SLR (super logic region) 的大型 FPGA。
- 核心貢獻：把同一層的 kernel 用 (κ, ω) 兩個維度拆到多個 SLR，平衡各 SLR 的資源使用，減少跨 SLR 的訊號穿越。
- Neuron core 一次處理 8-bit 平行 spike；AND 運算利用暫存器的同步 reset 腳位實現，比第一代 DeepFire 省大量 LUT。
- 論文：https://arxiv.org/pdf/2305.05187
- 無公開原始碼。

### FireFly v2 — spatiotemporal dataflow，不存膜電位
- 把 time-step 迴圈移到 neuron loop 內、spatial loop 外，讓 spike 即時算即時吐（on-the-fly），因此不需要把整層膜電位存在片上記憶體。
- 四維平行度：output channel (M)、input channel (V)、pixel (N)、time step (S)。
- Systolic array 核心用 DSP48E2 的 SIMD/cascade 特性做突觸電流累加，透過 slow-to-fast gearbox 讓運算陣列跑在系統時脈的 2 倍 (500-600MHz)。
- 支援非二值 spike（residual connection 產生的 multi-bit spike、average pooling 的 fractional spike），用 bit-serial 分解成多輪二值計算再 shift-merge 合併回去。
- 論文：https://arxiv.org/pdf/2309.16158
- 原始碼：https://github.com/adamgallas/FireFly-v2 （已 clone 到 `repos/FireFly-v2`，Chisel/Scala 實作）

### Spiker / Spiker+ — 精簡邊緣裝置設計
- 目標是壓低硬體複雜度，跑在資源有限的邊緣板子（Artix-7）。
- Clock-driven，每個 timestep 對所有神經元平行更新（400 神經元全平行）。
- 用單一 LFSR 產生所有輸入的隨機數（原本每個 input 各自一個 RNG），大幅省面積，準確度只掉 2.19%。
- Spiker+ 是後續發展的開源框架，涵蓋訓練、優化、VHDL 自動生成全流程。
- 論文：https://arxiv.org/pdf/2201.06993
- 原始碼：https://github.com/smilies-polito/Spiker （已 clone 到 `repos/Spiker`，Python 生成 VHDL）

### SCNN multi-structure compatible
- 支援 LeNet/ResNet 等不同拓樸，用可選用模組（如 shortcut group）達成相容性。
- neuron-state BRAM 只存輸出 feature map 一整行 pixel 份量的膜電位，不用存整張，是它對大 feature map 的關鍵省記憶體手法。
- 二值 spike 卷積直接退化成權重累加，完全不需要乘法器。
- 論文：https://pmc.ncbi.nlm.nih.gov/articles/PMC12511070/
- 無公開原始碼。

### snn-fpga — 低階板開源實作
- 目標平台 Digilent Basys3（低階 Artix-7），適合直接讀懂全部程式碼、當作學習範例。
- 16 個神經元打包成一個 128-bit 的 tile，依 postsynaptic neuron index 排序存放，讓更新時記憶體存取連續。
- Control unit 序列化處理，每 cycle 處理一個 tile，不是全平行，這是低資源板子下的取捨。
- 論文：https://arxiv.org/html/2507.07284v1
- 原始碼：https://github.com/im-afan/snn-fpga （已 clone 到 `repos/snn-fpga`）

## 本地 repo 位置

```
repos/
├── FireFly-v2/   # Chisel/Scala, systolic array, 500-600MHz spike engine
├── Spiker/       # Python -> VHDL 生成框架 (Spiker+)
└── snn-fpga/     # 低階板 (Basys3) 參考實作
```

## 待深挖方向（尚未展開）

- FireFly v2 的 spatiotemporal dataflow 迴圈重排細節（`src/` 內的 systolic array RTL）。
- DeepFire2 的 split-kernel BRAM cascade 邏輯（無原始碼，只能從論文圖表推）。
- Spiker+ 的 VHDL 自動生成流程，如何從 Python 網路定義映射到 BRAM 配置。

## 綜合評比

評分準則：難度/使用量等主觀分級用 低/中/高/極高，客觀數字附帶來源數據。

| 專案 | 實做難度 | 資源使用量 | 模型準確率 | 吞吐量 | 能效 | 可擴展性 | 原始碼可及性 |
|---|---|---|---|---|---|---|---|
| **Spiker/Spiker+** | 低 — 單一神經元模型、clock-driven、無跨晶片複雜度 | 低 — Artix-7 上 55% LUT / 32% BRAM，僅 400 神經元 | 中低 — MNIST 73.96~78.58%（為省資源犧牲精度：單 LFSR、5-bit 權重） | 中 — 215 μs/image | 中 — 13 mJ/image，但 0.041 μJ/synapse（非該類最佳） | 低 — 固定小網路規模，未展示 CSNN 卷積層 | 高 — Spiker+ 主動維護，Python→VHDL 全流程 |
| **DeepFire2** | 極高 — 需手動規劃 split-kernel 跨 SLR 映射、多晶粒時序收斂 | 高（絕對值）但效率佳 — 可動態依層調整 BRAM/URAM，資源利用率近 80% | 高 — 可跑到 ImageNet 規模 CSNN | 極高 — >1500 fps（ImageNet 等級模型） | 高 — 比前代提升近 10 倍 | 極高 — 專為超大型網路 + 多 SLR 設計 | 無 — 無公開碼，只能靠論文圖表 |
| **FireFly v2** | 極高 — 四維 spatiotemporal dataflow 迴圈重排、2 倍頻 gearbox、bit-serial 非二值 spike 分解，微架構最複雜 | 中 — 免存膜電位大幅省片上記憶體，但需 UltraScale + DSP48E2 資源 | 高 — 支援 SOTA 演算法（ResNet-level、殘差、average pooling） | 極高 — FPGA-SNN 中最高時脈 (500-600MHz)，1.67-2x 於前代 | 最高 — DSP 效率 1.33x DeepFire2，功耗效率 1.42x 業界最強方案 | 高 — 明確支援非二值運算與深層殘差結構 | 中高 — 有碼但 Chisel/Scala，非主流 HDL，上手門檻高 |
| **SCNN multi-structure** | 中高 — clock-driven 本體不難，但要支援 LeNet/ResNet 多拓樸需額外可配置模組 | 低 — LeNet-small 僅 9.88%~小比例資源，行級膜電位儲存省很多 | 高 — MNIST 99.1%，Fashion-MNIST 84.7%，YOLO 變種可用 | 高 — 1605 fps (LeNet-small) | 高 — 0.65 mJ/image，ResNet 變種功耗僅 CPU 的 16.77% | 中 — 支援多結構，但複雜度隨拓樸增加 | 無 — 無公開碼 |
| **snn-fpga (開源)** | 低 — 序列化控制、tile 打包，架構單純，適合當教材 | 極低 — 低階 Basys3 板，29% BRAM，13k LUT（含 CPU） | 未知 — 論文聚焦速度/穩健性，未見明確準確率數字 | 低中 — 0.52 ms/image（序列化犧牲平行度） | 高（絕對功耗低） — 0.381W | 低 — 明確以低階板為目標，非大型網路取向 | 高 — 全碼公開、結構最容易讀懂 |

### 額外指標補充

**膜電位儲存效率**（CSNN 特有、比一般 ANN 更值得看的指標）
- FireFly v2 > SCNN（行級儲存）> DeepFire2/Spiker（整層存但有 banking）> snn-fpga（打包但序列化存取）

**上手/學習曲線**
- 想直接抄代碼練手：snn-fpga > Spiker+ > FireFly v2（其他兩篇無碼）
- 想學進階架構技巧（split-kernel、spatiotemporal dataflow）：DeepFire2、FireFly v2 論文本身資訊量最大，即使沒碼也值得精讀

**工具鏈成熟度**
- Spiker+：最完整，涵蓋訓練→量化→VHDL 生成，商用/教學皆可直接套用
- FireFly v2：Chisel 生態需要額外學習成本（sbt/Scala），但架構參數化程度高，改配置較有彈性
- snn-fpga：Python build script + 手寫 HDL，工具鏈簡單但擴充需自己改

**論文與硬體對應的透明度（reproducibility）**
- 有碼三個（Spiker+、FireFly v2、snn-fpga）數字都能對照原始碼驗證
- DeepFire2、SCNN 只能相信論文報告數字，banking 策略等細節得靠圖表反推，實作前要有心理準備可能有落差

### 一句話總結

- 要學「效能天花板怎麼做」：看 **FireFly v2**（免存膜電位 + 微架構優化），但難度最高。
- 要學「怎麼把設計 scale 到大網路」：看 **DeepFire2** 的 split-kernel/SLR 分配思路。
- 要有能跑、能改、能讀的完整代碼練手：從 **snn-fpga** 開始，再進階看 **Spiker+**。
- 要做多拓樸相容（LeNet/ResNet 切換）的省記憶體技巧：參考 **SCNN multi-structure** 的行級膜電位儲存。

---

# 動態手勢辨識（事件相機 + CSNN）調查

調查日期：2026-08-20
範圍：鎖定「事件相機輸入 + FPGA 硬體」的手勢辨識實作，優先找跟 KV260/GENX320 這類 Zynq UltraScale+ + Prophesee 感測器組合貼近的案例。

## 專案總表

| 專案 | 演算法 | 硬體平台 | 資料集/準確率 | 延遲/吞吐 | 資源使用 | 更新方式 | 原始碼 |
|---|---|---|---|---|---|---|---|
| **HOMI** | CNN（非 SNN） | Zynq UltraScale+ MPSoC + Prophesee **IMX636**（GENX320 同廠感測器） | DVS Gesture: 94.0%(Net70) / 88.51%(Net16) | 1ms(Net16, 1000fps) / 3.6ms(Net70, 278fps) | 65.7K LUT(31%), 205 BRAM, 14 DSP | Clock-driven CNN 推論 | 未找到公開 repo |
| **HOTS FPGA** | Time-Surface (非 SNN) | Zynq-7100 (可縮到 Zynq-7020) | NavGestures-sit 6手勢: 93.3~94.1%（vs 軟體 94.5%） | 0.5~6.7 μs，77mW | 僅 18/755 BRAM (2%), 8351 LUT (3%) | Event-driven，逐 event 處理 | 演算法本身有 Python repo，FPGA RTL 未公開 |
| **LSM (Liquid State Machine)** | SNN，reservoir computing | FPGA（512 LIF 神經元，另一版本 343 神經元） | DVS128 Gesture: 97.42%(4-bit,512神經元) / 98.42%(343神經元版) | 3.97ms，比 TrueNorth 方案快 26x | 未取得完整數字（論文付費牆） | 未知，reservoir 通常 event-driven | 未找到公開 repo |
| **結構化稀疏 + Early-Stop SNN** | SNN (modified LIF) | Xilinx **ZCU104**（同為 Zynq UltraScale+ 家族） | DVS128-Gesture 79.0%＠50% sparsity；N-MNIST 96.0% | 未取得完整數字（論文付費牆） | 神經元數 1024~4096（依 sparsity 動態） | **Event-driven**，非 clock-driven | 未找到公開 repo |
| **Binary SNN Accelerator** | Binary SNN (BNN×SNN 訓練法) | 未確認是否為 FPGA（論文摘要語焉不詳，付費牆無法完整驗證） | IBM DVS Gesture: 95.49% | 1.1 μJ/inference | 未取得完整數字 | Temporal pooling 減少 timestep | 未找到公開 repo |
| **SCRNN**（僅演算法，非硬體） | Spiking 卷積 + 遞迴（自回饋）架構 | 無 FPGA 實作，僅提及與 Loihi 相容的可能性 | DVS Gesture: 96.59%(10類) / 90.28%(11類) | — | — | 遞迴隱狀態與膜電位共同更新 | 演算法用 SLAYER framework，無 FPGA 碼 |

## 重點筆記

**HOMI 是目前找到跟你硬體最接近的案例**（Zynq UltraScale+ + Prophesee 感測器），但它是 CNN 不是 SNN。
值得參考的不是神經網路本體，而是**前級事件資料處理管線**：
- EVT 3.0 格式解碼
- Dual-port BRAM (16-bit × 16384 depth) 做 ping-pong 緩衝
- 用查表法把感測器原始解析度（1280×720）降到 128×128，不用真的產生中間影格
- 三個獨立 clock domain（感測器介面 / 前處理 / 推論）避免事件遺失

這段前處理邏輯無論你最後用 CNN 還是 SNN 做辨識，大概率都要自己刻一份類似的，可以當設計參考。GENX320 本身解析度是 320×320（比 IMX636 的 1280×720 小很多），事件率通常也較低，前處理的 BRAM 壓力應該比 HOMI 的案例小。

**HOTS 的 BRAM 使用效率是這幾篇裡最誇張的**（755 個 block 只用 18 個），因為它用逐 pixel 的 timestamp 而不是逐 neuron 的膜電位，記憶體深度=感測器解析度、寬度=timestamp bit 數，跟前面 CSNN 那幾篇「膜電位存 BRAM」的邏輯完全不同賽道。如果你的手勢辨識只需要「有沒有動、往哪動」這種粗粒度特徵，HOTS 這種非 SNN 的 time-surface 前處理可以當作事件相機端的降維手段，再接一個小 CSNN 分類頭，BRAM 壓力會小很多。

**結構化稀疏+Early-Stop 這篇是目前唯一真正 event-driven（非 clock-driven）的 SNN 手術**，這點對事件相機特別關鍵：GENX320 輸出本來就是稀疏事件流，如果加速器還是 clock-driven（每 cycle 都更新，不管有沒有事件），就浪費了事件相機「稀疏、低功耗」的本質優勢。可惜細節在付費牆後面，只能先記下線索：ZCU104（同 Zynq UltraScale+ 家族）、1024~4096 神經元、DVS128-Gesture 79.0%＠50% sparsity。之後如果要深入這條路線，建議想辦法拿到 IEEE 全文或找作者要 preprint。

**LSM (reservoir computing) 這條路線跟你的「自回饋網路」方向可能有交集**：LSM 的核心概念本來就是隨機遞迴儲備池（不用訓練遞迴權重，只訓練輸出層），343~512 個神經元就能在 DVS128 Gesture 上做到 97~98% 準確率，訓練成本遠低於一般 backprop 訓練的 SNN。如果之後 NERF 攔截那個方向要重新考慮訓練方式，這個系列值得回頭看。

## 待確認/受阻項目

- 三篇論文（LSM 完整硬體細節、結構化稀疏+Early-Stop 完整資源數字、Binary SNN Accelerator 的平台是否真為 FPGA）卡在 IEEE/ACM 付費牆，WebFetch 回傳 403，數字不完整，不要直接拿去做設計依據。
- 目前找到的 5 篇裡，沒有一篇是「事件相機直接接 CSNN 做手勢辨識、且有公開 FPGA 原始碼」的案例，都得靠論文文字或自己重新實作。

---

# Event-driven 膜電位惰性更新與 FIFO 反壓調查

調查日期:2026-08-23
範圍:conv IP 的 fire/reset 判斷是否需要每個 timestep 掃描全部神經元(會跟事件更新 pipeline 搶 BRAM port,可能造成 FIFO 堆積)、以及輸入事件 FIFO 反壓/丟事件的策略,查其他 SNN-FPGA 實作怎麼處理。

## 惰性 decay / event-driven fire-check 相關

使用者自行下載到 `docs/SNN/Concept/論文/` 的兩篇,已讀完整全文,取代了原本只靠 WebSearch 摘要的猜測(下面標記「已更正」的地方是原始摘要猜錯的部分)。

| 論文 | 平台 | 關鍵機制 | 存取狀態 |
|---|---|---|---|
| Event-driven Recurrent SNN Architecture for FPGA(ICONS 2022,Sankaran et al.) | FPGA(Zynq UltraScale+ ZCU104) | **已更正**:不是時間戳記式惰性 decay。Decay 用移位暫存器算固定量,只在收到 layer 間的 request-acknowledge 信號時觸發一次(不按真實時間算指數衰減);正確性靠「REQ 到了以後先把 input spike queue 完全清空,才做閾值比對」,且每個神經元有獨立暫存器、全層平行評估——只在神經元數量少(論文最大 2954 個)才划算,跟 conv1/conv2 動輒 32768 個神經元、必須用 BRAM 而非獨立暫存器的規模不匹配 | 已讀完整全文(`docs/SNN/Concept/論文/3546790.3546802.pdf`) |
| Characterization of a Spiking Convolutional Processor for FPGA(Curra-Sosa et al., *Sensors* 2026) | FPGA(Zynq-7100) | 這篇才是真正對得上我們架構的:membrane potential 存 BRAM(以 row 為單位),每個神經元額外存 leak/refractory 時間戳記,現場跟全域計數器比對算 decay,只在事件觸發、神經元被碰到時才計算,無需全網路掃描。**這只是外部文獻查證,還沒經過我們自己逐步推導、對照 spikingjelly 訓練端運算方式驗證過,不算定案**——之前一度寫進 `conv_event_scatter_banking_derivation.md` 當作已決定的機制,已被使用者要求拔掉重來 | 已讀完整全文(`docs/SNN/Concept/論文/sensors-26-01801.pdf`) |
| S2N2: A FPGA Accelerator for Streaming Spiking Neural Networks | FPGA(FINN-based) | 不存事件佇列、不用惰性 decay,改用整個 tick 的二值張量批次串流處理,跟事件驅動即時處理是不同賽道 | 已讀完整全文 |
| FireFly v2(見前段 survey) | FPGA | 完全不存整層 $V$,time loop 移進 neuron loop 內側,spike 即算即吐 | 已讀完整全文(前段調查) |

## FIFO 反壓 / 事件遺失相關

| 論文/系統 | 機制 | 存取狀態 |
|---|---|---|
| SpiNNaker | 壅塞時路由器真的會丟封包,只有 1 個暫存器可補救,連續丟兩次的話第二筆永久遺失、無法復原 | 已讀完整全文(arxiv) |
| Characterization of a Spiking Convolutional Processor for FPGA | **已更正**:第 3 節(方法論)描述「input FIFO 飽和會導致事件被忽略」只是理論上三種事件遺失成因之一;第 4 節實際硬體測試結果明講「no event loss due to FIFO overflow is observed... enforces flow control at the interface level」——AER 介面的 req/ack 交握天然形成反壓,實際行為是反壓、不是丟事件,支持我們的反壓決定。論文裡的「Loss (%)」講的是 LIF 閾值/refractory 天生濾掉的輸入事件比例(神經元動態的正常行為),不是 FIFO 溢位丟資料,兩者不要混為一談 | 已讀完整全文 |
| An FPGA-Based Event-Driven SNN Accelerator for DVS Applications With Structured Sparsity and Early-Stop | 目前查到唯一真正 event-driven(非 clock-driven)的 SNN 論文,FIFO/反壓細節未知 | 被 IEEE 擋掉(418),未讀到內容 |

## 架構比較:Characterization of a Spiking Convolutional Processor for FPGA vs. 本專案設計

這篇是目前找到跟我們架構最接近的已發表、已實測工作,值得詳細比較(對應章節在 `conv_event_scatter_banking_derivation.md`):

| 面向 | 該論文 | 本專案設計 |
|---|---|---|
| kernel 彈性 | $1\times1$~$7\times7$,**執行時**透過 AXI 改參數,不用重新合成 | $K,S,P,OC,IC$ 皆為編譯期常數,換層要重新合成 |
| 多候選輸出的平行存取 | 多個 conv engine 共用一個 arbiter 排隊存取記憶體(序列化) | 數學證明 $N\times N$ 個候選必落在不同 bank,不需要仲裁,天生無衝突平行存取(第 5–9 節) |
| 單事件延遲 | $1\times1$ kernel 130 cycles,$7\times7$ kernel 893 cycles(每 row 的 LUTRAM 更新約 256 cycles@100MHz) | 推導出 $OC+2$ cycles 處理完一個事件的所有輸出 channel(conv1 是 10 cycles,第 13.2 節) |
| 資源用量 | Zynq-7100 上 212k LUT(76%)、708 個 BRAM(94%) | KV260(XCZU5EV)預算僅 94 個 BRAM36 可用給整個三層網路,遠小於這篇單層用量 |
| 硬體驗證 | 已實測,拿 DVS-MNIST 真實資料跑,跟 MATLAB `conv2` 量化比對(BCR>0.92) | 目前僅紙上推導,尚無電路實作或測試 |

結論:這篇的執行時彈性是用資源(94% BRAM、遠大於 KV260 的晶片)換來的,直接搬到 KV260 會超出整個晶片的 BRAM 預算。本專案的編譯期固定參數 + 證明過的 $N\times N$ banking 是針對 KV260 資源有限、三層形狀已知、不需要跑時改 kernel 這個情況的取捨,但這只是紙上分析,還沒有實測數字可以對比,這點該論文比我們扎實。

## 待自行嘗試存取的連結(WebFetch 這邊全部被擋)

- Event-driven Recurrent SNN(ICONS 2022)
  - ACM:https://dl.acm.org/doi/10.1145/3546790.3546802
  - ACM full text(403):https://dl.acm.org/doi/fullHtml/10.1145/3546790.3546802
  - ResearchGate:https://www.researchgate.net/publication/363536402_An_Event-driven_Recurrent_Spiking_Neural_Network_Architecture_for_Efficient_Inference_on_FPGA
  - TU Eindhoven 條目(有作者自存 PDF 連結,但撞 Cloudflare 人機驗證):https://research.tue.nl/en/publications/an-event-driven-recurrent-spiking-neural-network-architecture-for/
  - 直接 PDF(同上,Cloudflare 擋):https://research.tue.nl/files/216364983/3546790.3546802.pdf
- 結構化稀疏+Early-Stop SNN
  - IEEE(418 錯誤):https://ieeexplore.ieee.org/iel8/8919/11061257/10981802.pdf
  - ResearchGate:https://www.researchgate.net/publication/391376487_An_FPGA-Based_Event-Driven_SNN_Accelerator_for_DVS_Applications_With_Structured_Sparsity_and_Early-Stop
- Characterization of a Spiking Convolutional Processor for FPGA(FIFO 反壓相關)
  - MDPI:https://www.mdpi.com/1424-8220/26/6/1801
  - DOI:https://doi.org/10.3390/s26061801
- 還沒嘗試存取,標題看起來相關,未列入上面比較表:
  - A Small, Low Cost Event-Driven Architecture for Spiking Neural Networks on FPGAs:https://www.researchgate.net/publication/343257661_A_Small_Low_Cost_Event-Driven_Architecture_for_Spiking_Neural_Networks_on_FPGAs
