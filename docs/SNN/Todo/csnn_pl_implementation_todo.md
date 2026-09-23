# SNN:CSNN 在 PL 端運算——TODO

## 要做什麼,為了什麼

`D:\Project\Spiking-Affine-Lazy-Training` 訓練出來的 CSNN,之後要讓 PL 端直接跑膜電位更新邏輯,不繞 PS,理由是低延遲、省資源。這個分支要解決的問題:PL 端具體怎麼實作膜電位更新,才能跟訓練出來的模型行為一致,同時功耗打贏對應的 ANN 版本。

2026-09-23 起已進入 Vivado 實作階段,不再是純規劃分支,跟 [`GENX320/Todo/ps_host_if_replacement_todo.md`](../../GENX320/Todo/ps_host_if_replacement_todo.md) 平行進行。

## 已經決定的設計(已放棄跟 spikingjelly 精確等效)

- 事件驅動、每筆事件到達就立刻用經過的整數 ms 數 $N$ 做解析衰減 + 判斷是否 fire,不等下一筆事件——跟 spikingjelly 逐步更新不是同一個函數,數學規格見 [`Concept/model_operation.md`](../Concept/model_operation.md) 第 2 節
- 層間事件格式統一為攤平索引 $(i,t)$,不是座標三元組 $(x,y,c,t)$;conv 層自己用編譯期已知的 $H_{in},W_{in},C_{in}$ 反推 $(x,y,c)$,FC 層直接拿 $i$ 當權重矩陣 column 索引。`conv1` 前面需要新增一個小型轉換模組,把事件相機原生座標 $(x,y,c,t)$ 換成 $(i,t)$;`EventProcessor.sv`(GENX320 範圍)本身不改動
- conv 分支事件驅動 RTL 設計(候選神經元決定、BRAM banking、LIF 膜電位更新、輸出排序、pipeline 時序)已定案,見 [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md);FC 分支還沒開始,見 [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)(目前空檔)

## Conv IP(SaltConv)實作進度

- Vivado 專案:`D:\Project\CSNN-FPGA\SaltConv`,module 名稱 `SaltConv`
- **Part 0(介面規格:parameter list、port list)已定案**,規格本體就是 [`SaltConv.sv`](../../../SaltConv/SaltConv.srcs/sources_1/new/SaltConv.sv) 本身,不在文件裡重複貼一份維護兩處。module 本體目前空白,待後續 part 依序填入,parameter 預設值都是佔位數字,不代表定案數值。
- 關鍵決策(Part 0 定案時一併定的):
    - 輸入輸出事件介面用**分欄位**(`s_x/s_y/s_c/s_t` 各自獨立 port),不是打包成單一 `TDATA`——跟 `EvtDecoder` 對 PS 端的做法不同,因為 `EvtDecoder` 那樣是受 PS AXI DMA 規格所迫,`SaltConv` 沒有這個限制
    - LIF 參數 `TAU`、`V_TH` 整層共用一組,不做成每個 output channel 各自一組的陣列
    - 權重不出現在 port list,模組內部用 ROM,初始化方式留到寫權重讀取那個 part 再定
- **輸入 FIFO 決策**:
    - 只有輸入端有 FIFO;輸出端沒有獨立 FIFO,靠 Conv.md 第 4 節的 bitmask 機制排序送出,下游 `ready=0` 時直接反壓卡住整條內部 pipeline(Conv.md 5.4 節)
    - FIFO 本體要獨立成一個參數化寬度的可重用子模組(暫定名 `EventFifo`),自己寫 RTL,不用 Xilinx IP——深度小(現行 `FIFO_DEPTH=16`)用不到 BRAM 管理能力,且介面已決定分欄位,套 Xilinx AXI4-Stream IP 反而要多包一層 pack/unpack
    - 現在先做非 BRAM(distributed RAM)版本,但**輸出必須遵守 valid/ready 交握,不能讓外部假設任何固定延遲**——這樣之後深度開大要換 BRAM(讀取有 1 clock 延遲),只需要改 `EventFifo` 內部把 `valid` 延後對齊,外部完全不用動
- **層間連接的格式轉換責任分工**(目前只做前兩種,第三種列出來對照):
    - `EvtDecoder → conv1`:`EvtDecoder` 輸出是打包 `TDATA`,`SaltConv` 輸入是分欄位,中間需要一個小型轉接模組做 `TDATA` unpack,由 top 實例化,不算在 `SaltConv` 或 `EvtDecoder` 任一邊內部
    - `conv → conv`:兩邊都是分欄位、欄位意義直接對應($oc\to c$、$oy\to y$、$ox\to x$、$t\to t$),不需要轉接模組,直接欄位對欄位接線(位寬一致是上下層 parameter 配置要對齊的責任)
    - `conv → FC`:之後再處理,FC 要攤平索引 $i$,轉換需要實際運算,等 `FC.md` 定案
- **實作 part 拆分**(Part 0 已完成,之後依序進行,每個 part 都要過目確認才進下一個):
    1. `EventFifo` 子模組(輸入端)
    2. 候選神經元與 banking 位址(Conv.md 第 2 節前半,純組合邏輯)
    3. 權重 BRAM 讀取與 tap 選擇(Conv.md 第 2 節後半)
    4. 神經元 BRAM($V,m_{last}$)介面(先做 Conv.md 5.2 無腦版,單埠)
    5. LIF 膜電位更新運算(Conv.md 第 3 節)
    6. bitmask 優先權排序與輸出(Conv.md 第 4 節)
    7. pipeline FSM 整合(先無腦版,Conv.md 5.1/5.2,不管效能)
    8. 之後視情況再細分:套用 5.3 管線化優化、5.4 反壓、5.5 讀取延遲一般化

## 待決定/待查證事項

1. **FPGA 上實際省多少功耗**:運算量少 20 倍不代表功耗少 20 倍,FPGA 有漏電流、clock tree 這些固定成本,需要 Vivado 功耗分析或實測才有數字。
2. **CSNN 模組要不要跟 `ps_host_if` 替換模組融合**:等雙方資源用量(BRAM、LUT、功耗)都出來才能決定。
3. **訓練端怎麼做到真正逐事件訓練**:已經移到獨立專案 `D:\Project\Spiking-Affine-Lazy-Training` 處理(單狀態仿射 LIF + associative scan 平行掃描訓練,conv/FC 都支援,N-MNIST 已訓練驗證,約 92% 準確率)。
4. **$V\_WIDTH$(神經元膜電位位寬)未定案**:暫定 12 bits 只是先讓 RTL 骨架能動,不是推導結果。真正數字待補,需要兩塊資訊:`D:\Project\Spiking-Affine-Lazy-Training` 的量化方案(整數位+小數位)、單一事件權重 $w$ 本身要留多少整數位 headroom。
5. **衰減查表 $(1-1/\tau)^N$ 的 ROM 深度數字待補**:截斷條件已有公式依據,但卡在 $F$($V\_WIDTH$ 拆出來的小數位)還沒定案,定案後才能算出實際 ROM 深度。
6. **`FIFO_DEPTH` 數字未定**:反壓、不丟事件的策略已經決定,但實際深度要看目標 clock 頻率、conv2/compress 的實際輸入事件率,這兩個事實還缺。
7. **事件間 pipeline overlap(讓不同 $oc$ 的讀跟算/寫重疊)**:已評估,結論是**目前不做**——省下的量是固定 2~3 拍、不隨 $OC$ 變大,理論吞吐量餘裕已經很大,複雜度換不到有意義的提升。保留當優化方向,等實測吞吐量真的不夠再重新評估。
8. **`EvtDecoder → conv1` 轉接模組還沒設計**:需要先查證 `EvtDecoder` 目前 `M_AXIS_TDATA` 實際打包的欄位配置(EVT2.1 格式),才能寫對應的 unpack 邏輯。

## 查證細節

conv 分支的完整事件驅動 RTL 推導(候選神經元決定、BRAM banking 位址、LIF 膜電位更新、輸出排序與 tie-break、pipeline 時序)在 [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md);FC 分支還沒開始,之後寫在 [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)。訓練端 forward 數學規格(仿射映射、逐筆事件更新、FC/conv 候選規則、多層串接、端到端範例)在 [`Concept/model_operation.md`](../Concept/model_operation.md)。
