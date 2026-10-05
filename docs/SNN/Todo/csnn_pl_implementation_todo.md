# SNN:CSNN 在 PL 端運算——TODO

## 要做什麼,為了什麼

`D:\Project\Spiking-Affine-Lazy-Training` 訓練出來的 CSNN,之後要讓 PL 端直接跑膜電位更新邏輯,不繞 PS,理由是低延遲、省資源。這個分支要解決的問題:PL 端具體怎麼實作膜電位更新,才能跟訓練出來的模型行為一致,同時功耗打贏對應的 ANN 版本。

2026-09-23 起已進入 Vivado 實作階段,不再是純規劃分支,跟 [`GENX320/Todo/ps_host_if_replacement_todo.md`](../../GENX320/Todo/ps_host_if_replacement_todo.md) 平行進行。

## 已經決定的設計(已放棄跟 spikingjelly 精確等效)

- 事件驅動、每筆事件到達就立刻用經過的整數 ms 數 $\Delta t$ 做解析衰減 + 判斷是否 fire,不等下一筆事件——跟 spikingjelly 逐步更新不是同一個函數,硬體實作的整數規格見 [`Concept/model_operation_quant.md`](../Concept/model_operation_quant.md) 第 3 節
- 層間事件格式 conv 跟 FC 分開,不統一:
    - conv 層的輸入、輸出都是分欄位座標 $(x,y,c,t)$。
    - FC 層的輸入是攤平編號 $(\text{src},t)$,直接拿 $\text{src}$ 當權重矩陣 column 索引。
    - conv 接 FC 時才把 $(o_c,o_y,o_x)$ 換成編號 $i=o_c\cdot H_{out}W_{out}+o_y\cdot W_{out}+o_x$。
    - `conv1` 前面的轉接見下方「層間連接的格式轉換責任分工」,`EventProcessor.sv`(GENX320 範圍)本身不改動。
- conv 分支事件驅動 RTL 設計(候選神經元決定、BRAM banking、LIF 膜電位更新、輸出排序、pipeline 時序)已定案,見 [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md);FC 分支還沒開始,見 [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)(目前空檔)

## Conv IP(SaltConv)實作進度

- Vivado 專案:`D:\Project\CSNN-FPGA\SaltConv`,module 名稱 `SaltConv`
- **Part 0(介面規格:parameter list、port list)已定案**,規格本體就是 [`SaltConv.sv`](../../../SaltConv/SaltConv.srcs/sources_1/new/SaltConv.sv) 本身,不在文件裡重複貼一份維護兩處。module 本體目前空白,待後續 part 依序填入,parameter 預設值都是佔位數字,不代表定案數值。
    - 2026-10-05:量化完成後,現行介面大多已經對不上整數規格,要重新定案,見待決事項第 14 條。
- 關鍵決策(Part 0 定案時一併定的):
    - 輸入輸出事件介面用**分欄位**(`s_x/s_y/s_c/s_t` 各自獨立 port),不是打包成單一 `TDATA`——跟 `EvtDecoder` 對 PS 端的做法不同,因為 `EvtDecoder` 那樣是受 PS AXI DMA 規格所迫,`SaltConv` 沒有這個限制
    - (2026-10-05 已過時,`TAU` 不進硬體,見待決事項第 14 條)LIF 參數 `TAU` 整層共用一組;`V_TH` 逐 output channel 一份(`parameter integer V_TH [0:OC-1]`)——2026-09-24 修正:訓練端 per-channel 權重量化下,fire 門檻換算成整數域後 $\tilde v_{th}=v_{th}/s_c$ 逐 channel 不同,即使物理 $v_{th}$ 是層共用常數,詳見 `Spiking-Affine-Lazy-Training` 的 `docs/math/權重量化推導.md` 第 111 行。陣列大小 $OC$ 不多,直接當編譯期常數合成成 mux,不用額外配置記憶體;per-tensor 情況陣列全部填同一個值一樣正確,不綁死訓練端最後的量化方案
    - 權重不出現在 port list,模組內部用 ROM,初始化方式留到寫權重讀取那個 part 再定
- **輸入 FIFO 決策**:
    - 只有輸入端有 FIFO;輸出端沒有獨立 FIFO,靠 Conv.md 第 4 節的 bitmask 機制排序送出,下游 `ready=0` 時直接反壓卡住整條內部 pipeline(Conv.md 5.4 節)
    - FIFO 本體要獨立成一個參數化寬度的可重用子模組(暫定名 `EventFifo`),自己寫 RTL,不用 Xilinx IP——深度小(現行 `FIFO_DEPTH=16`)用不到 BRAM 管理能力,且介面已決定分欄位,套 Xilinx AXI4-Stream IP 反而要多包一層 pack/unpack
    - 現在先做非 BRAM(distributed RAM)版本,但**輸出必須遵守 valid/ready 交握,不能讓外部假設任何固定延遲**——這樣之後深度開大要換 BRAM(讀取有 1 clock 延遲),只需要改 `EventFifo` 內部把 `valid` 延後對齊,外部完全不用動
- **層間連接的格式轉換責任分工**(目前只做前兩種,第三種列出來對照):
    - `EvtDecoder → conv1`:`EvtDecoder` 輸出是打包 `TDATA`,`SaltConv` 輸入是分欄位,中間需要一個小型轉接模組做 `TDATA` unpack,由 top 實例化,不算在 `SaltConv` 或 `EvtDecoder` 任一邊內部
    - `conv → conv`:兩邊都是分欄位、欄位意義直接對應($o_c\to c$、$o_y\to y$、$o_x\to x$、$t\to t$),不需要轉接模組,直接欄位對欄位接線(位寬一致是上下層 parameter 配置要對齊的責任)
    - `conv → FC`:之後再處理,FC 要攤平索引 $i$,轉換需要實際運算,等 `FC.md` 定案
- **2026-09-24 暫停 Part 2,先去完成訓練端量化**:討論 Part 2 介面時發現量化會影響 Part 0 的 `V_TH`(見上方 2026-09-24 修正),為避免同類問題重複發生、做白工,先去 `Spiking-Affine-Lazy-Training` 把量化方案(per-channel/per-tensor 定案、$V\_WIDTH$ 整數位小數位)做完,再回來繼續 Part 2。
    - Part 2 介面討論已有的初步共識,回來時可以直接接著用:候選計算拆成單軸子模組(暫名 `CandidateAxis`,參數 $K,S,P,O_{max}$,對 $y$、$x$ 各自實例化一次重用同一份 RTL),輸出 $M$ 組 $\{valid,\ o,\ o\bmod M,\ \lfloor o/M\rfloor\}$;上層做 $M\times M$ 外積合併。
    - 還沒定案的問題:候選輸出介面要用 SystemVerilog struct array 還是展開成獨立訊號,這是回來後第一個要決定的。
- **2026-10-05 訓練端量化已完成,Part 2 可以繼續**:整數規格見 [`Concept/model_operation_quant.md`](../Concept/model_operation_quant.md),Conv.md 符號已對齊這份。現行兩版的實際數值見下方待決事項第 4、5 條。
- **實作 part 拆分**(Part 0 已完成,之後依序進行,每個 part 都要過目確認才進下一個):
    1. `EventFifo` 子模組(輸入端)
    2. 候選神經元與 banking 位址(Conv.md 第 2 節前半,純組合邏輯)
    3. 權重 BRAM 讀取與 tap 選擇(Conv.md 第 2 節後半)
    4. 神經元 BRAM($\hat V,t_{last}$)介面(先做 Conv.md 5.2 無腦版,單埠)
    5. LIF 膜電位更新運算(Conv.md 第 3 節)
    6. bitmask 優先權排序與輸出(Conv.md 第 4 節)
    7. pipeline FSM 整合(先無腦版,Conv.md 5.1/5.2,不管效能)
    8. 之後視情況再細分:套用 5.3 管線化優化、5.4 反壓、5.5 讀取延遲一般化

## 待決定/待查證事項

1. **FPGA 上實際省多少功耗**:運算量少 20 倍不代表功耗少 20 倍,FPGA 有漏電流、clock tree 這些固定成本,需要 Vivado 功耗分析或實測才有數字。
2. **CSNN 模組要不要跟 `ps_host_if` 替換模組融合**:等雙方資源用量(BRAM、LUT、功耗)都出來才能決定。
3. **訓練端怎麼做到真正逐事件訓練**:已經移到獨立專案 `D:\Project\Spiking-Affine-Lazy-Training` 處理(單狀態仿射 LIF + associative scan 平行掃描訓練,conv/FC 都支援,N-MNIST 已訓練驗證,約 92% 準確率)。
4. **$V\_WIDTH$(膜電位暫存器寬度 $w=i_V+f_V$)要選哪一版**:訓練端已給出兩版,$f_V=0$,所以 $w=i_V$。
    - 繞回版:conv1 12 bits、conv2 14 bits,test 0.9222。驗證跟 test 都沒碰到暫存器範圍,繞回不會真的發生。
    - 飽和版:conv1 9 bits、conv2 11 bits,test 0.9229。幾乎每筆樣本都會碰到範圍,硬體要照飽和逐位元夾住。
    - 兩版的權重碼、衰減表、門檻完全相同($b=7$、$f_a=6$、$f_V=0$、捨入用 `round`),只差 $i_V$ 跟溢位處理。
    - `SaltConv.sv` 的 `V_WIDTH=12` 仍是佔位值,選定版本前不改。
5. **衰減查表 $A[\Delta t]$ 的 ROM 深度**:兩版共用同一張表,深度 $\Delta t_{\max}=75$ 格,每格 $f_a=6$ bits 無號,值 $60,56,53,\dots,1$。
    - 同一拍 $M\times M$ 個候選要同時查表(Conv.md 第 3 節 ①),讀埠怎麼提供還沒定。
6. **`FIFO_DEPTH` 數字未定**:反壓、不丟事件的策略已經決定,但實際深度要看目標 clock 頻率、conv2/compress 的實際輸入事件率,這兩個事實還缺。
7. **事件間 pipeline overlap(讓不同 $oc$ 的讀跟算/寫重疊)**:已評估,結論是**目前不做**——省下的量是固定 2~3 拍、不隨 $OC$ 變大,理論吞吐量餘裕已經很大,複雜度換不到有意義的提升。保留當優化方向,等實測吞吐量真的不夠再重新評估。
8. **`EvtDecoder → conv1` 轉接模組還沒設計**:需要先查證 `EvtDecoder` 目前 `M_AXIS_TDATA` 實際打包的欄位配置(EVT2.1 格式),才能寫對應的 unpack 邏輯。
9. **樣本邊界怎麼重置神經元記憶體**:換樣本時所有層的 $\hat V$、$t_{last}$ 都要回到 0。
    - 樣本邊界的訊號從哪裡來、BRAM 怎麼清零、清零期間事件怎麼處理,都還沒定。
10. **權重匯出格式**:訓練端 `model.npz` 存的是 $q$、`decay_table_int`、`v_th_int`($\hat v_{th}$ 逐神經元存,同一個輸出 channel 值相同)。
    - 要轉成 `SaltConv` 用的格式:權重 ROM 寬字(位址 $(o_c,c)$,寬 $K\times K\times b$)、$\hat v_{th}[o_c]$、$A[\Delta t]$。
    - 訓練端 TODO 的「量化模型的匯出格式」也在等這邊的規格。
11. **乘 $s_i$ 放在 FPGA 內還是外部**:輸出層讀出 $\text{score}_i=\hat V[i]\cdot s_i$ 是整個推論唯一的浮點運算,conv 層不需要 $s$。
12. **用 `reference.npz` 做逐位元比對**:每個量化資料夾都有 val 前 2000 筆的逐筆結果。
    - 欄位有 `preds`、`v_final_int`(輸出層暫存器最終值)、`spike_count`(每層 spike 總數)、`overflowed`(每層有沒有碰到暫存器範圍)。
    - `v_final_int` 逐位元相同就代表整條推論對上。
    - conv 層單獨驗證時只有 spike 總數可比,沒有逐筆的 spike 序列。
13. **conv1 前面的轉換模組,µs 換 ms 要用 floor**:$t=\lfloor t_{\mu s}/1000\rfloor$,跟訓練端相同。
    - 放在第 8 條的轉接模組裡,還是另外一個模組,還沒定。
14. **`SaltConv.sv` 介面要依整數規格重新定案**:Part 0 的 parameter/port 是量化前定的,現在大多對不上。
    - `TAU`:$\tau$ 不進硬體,硬體拿到的是衰減表 $A[\Delta t]$(深度 $\Delta t_{\max}$、每格 $f_a$ bits)。
    - `QB=8`:現行兩版都是 $b=7$。
    - `V_WIDTH=12`:佔位值,依第 4 條選定的版本改。
    - `V_TH`:要是 $w$ 位元有號整數,現在宣告成 `integer` 陣列,沒有表達位寬。
    - 缺少的參數:$f_a$、$f_V$、$\Delta t_{\max}$、捨入規則、溢位處理。
    - 權重、$\hat v_{th}$、$A[\Delta t]$ 怎麼初始化,跟第 10 條的匯出格式一起定。
    - 樣本邊界重置(第 9 條)目前沒有對應的 port。

## 查證細節

conv 分支的完整事件驅動 RTL 推導(候選神經元決定、BRAM banking 位址、LIF 膜電位更新、輸出排序與 tie-break、pipeline 時序)在 [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md);FC 分支還沒開始,之後寫在 [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)。訓練端 forward 數學規格分兩份:浮點推導在 [`Concept/model_operation_float.md`](../Concept/model_operation_float.md),硬體實作只看整數版 [`Concept/model_operation_quant.md`](../Concept/model_operation_quant.md)(參數、單筆事件更新、候選規則、多層串接、輸出層讀出)。
