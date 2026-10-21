# SaltConv 資料流程圖

對照 `SaltConv/SaltConv.srcs/sources_1/new/SaltConv.sv`。
框裡的「第 N 段」是那個檔案檔頭目錄的段落：

| 段 | 內容 |
|---|---|
| 0 | 共用控制：`stall`、`read_next_oc`、`take_new_event` 的宣告(設定在第 6 段) |
| 1 | 事件進來：清除記憶體、FIFO、事件暫存器 |
| 2 | 下一個 o_c 是誰、讀位址、讀取開關、`last_read_out_channel` |
| 3 | 下一個 o_c 碰到哪些神經元(CandidateGrid) |
| 4 | 管線位置 1..L:每個位置一份那個 o_c 的候選、時間、o_c、valid |
| 5 | 讀出、算、寫回：權重、門檻、NeuronMemory + NeuronUpdate |
| 6 | 送出、還有沒有剩、停不停、讀不讀 |

R 是讀取延遲，C 是計算級數,L = R + C − 1 是管線位置的個數。o_c 的讀位址送出後第 p 拍在位置 p:位置 R 資料出來、算計算前一半，位置 L 算後一半、寫回、送出(C=1 時兩個是同一個位置)。

圖畫的是「一拍」裡發生的事，由上往下分成三排：
- 最上面：這一拍開始時已經在暫存器裡的東西(上一個時脈邊緣存的)。
- 中間：同一拍裡同時做的事。三塊各自處理不同的 o_c:「讀下一個 o_c」是還沒進管線的那個，「位置 R」是資料剛出來的那個，「位置 L」是最後一個位置上的那個。
- 最下面：這一拍結束的時脈邊緣存起來的東西，下一拍就變成最上面那一排。

R=2、C=2 的具體電路(每個暫存器放在哪一欄、控制線拉到哪)見架構總覽圖 [SaltConv架構總覽.drawio.svg](SaltConv架構總覽.drawio.svg)。

```mermaid
flowchart TD
    subgraph NOW["這一拍開始時已經在的(上一個時脈邊緣存的)"]
        direction LR
        FIFO["EventFIFO(第 1 段)<br/>看得到最前面那筆事件"]
        EVREG["事件暫存器(第 1 段)<br/>event_x/y/channel/time"]
        LAST["last_read_out_channel(第 2 段)<br/>最近一次讀的 o_c"]
        PIPE["pipe_*[1..L](第 4 段)<br/>每個位置：valid、o_c、時間、候選"]
        HELD["pipe_held(第 4 段)<br/>上一拍停住了"]
        RD1["BRAM 讀出暫存器<br/>膜電位、上次時間、整組權重"]
        RD2["BRAM 輸出暫存器(R=2)"]
        CUT["切點暫存器(C=2,NeuronUpdate 裡)<br/>衰減後膜電位、權重碼"]
        BM["bitmask(第 6 段)<br/>位置 L 之前沒送出的 fire"]
    end

    subgraph READ["讀下一個 o_c"]
        ADDR["選這次要讀哪一筆(第 2 段)<br/>新事件：FIFO 那筆,o_c=0<br/>同一筆：事件暫存器那筆,o_c+1"]
        GRID["CandidateGrid(第 3 段)<br/>碰到哪幾顆神經元<br/>各在哪個 bank 的哪個位址"]
        RDREQ["讀位址送進 NeuronMemory、WeightMemory<br/>讀取開關 = read_next_oc"]
    end

    subgraph POSR["位置 R:資料出來"]
        TAP["WeightTapSelect(第 5 段)<br/>用 pipe_tap[R] 從整組權重挑"]
        STEP1["計算前一半(NeuronUpdate ①②)<br/>時間間隔、查衰減表、乘法捨回<br/>時間用 pipe_time[R]"]
    end

    subgraph POSL["位置 L:最後一個位置"]
        STEP2["計算後一半(NeuronUpdate ③④)<br/>加權重碼、溢位處理、比門檻<br/>門檻依 pipe_channel[L]"]
        CC["compute_cycle(第 4 段)<br/>pipe_valid[L] 而且上一拍沒停"]
        WB["寫回 NeuronMemory(第 5 段)<br/>只在 compute_cycle=1、候選合法"]
        PEND["pending(第 6 段)<br/>剛到：spike 而且合法<br/>停住:bitmask"]
        SS["SpikeSelect(第 6 段)<br/>挑 o_y、o_x 最小的一個"]
        OUT["送出 out_valid、out_x、out_y<br/>out_channel、out_time(第 6 段)"]
        READY["out_ready(下游)"]
        LEFT["pending_left(第 6 段)<br/>拿掉送出的"]
        FL["fires_left(第 6 段)<br/>至少 1 個，而且下游不收或不只 1 個"]
        STALL["stall(第 6 段)<br/>pipe_valid[L] 而且 fires_left"]
    end

    subgraph CTRL["讀不讀下一個 o_c(第 6 段)"]
        BLOCK["next_oc_blocked<br/>不重疊：前一個還在位置 1..L-1<br/>讀寫衝突：上一筆的 o_c=0 還在管線裡"]
        RNO["read_next_oc<br/>沒停、有東西可讀、沒被擋住"]
        TAKE["take_new_event<br/>讀的是新事件的 o_c=0"]
    end

    subgraph NEXT["時脈邊緣存起來，下一拍變成最上面那一排"]
        direction LR
        N_PIPE["stall=0 時 pipe_*、pipe_valid 往後推一格<br/>位置 1 放 read_next_oc 和這次讀的 o_c"]
        N_HELD["pipe_held ← stall"]
        N_RD["read_next_oc=1:讀出暫存器讀進新位址<br/>stall=0:輸出暫存器往後推"]
        N_CUT["切點暫存器 ← 計算前一半<br/>每拍都存"]
        N_BM["bitmask ← pending_left"]
        N_EV["take_new_event=1:<br/>事件暫存器存 FIFO 那筆，FIFO 拿走那筆<br/>read_next_oc=1:last_read_out_channel 更新"]
    end

    FIFO --> ADDR
    EVREG --> ADDR
    LAST --> ADDR
    ADDR --> GRID
    GRID --> RDREQ
    ADDR --> RDREQ
    RDREQ --> N_RD
    GRID -->|"候選"| N_PIPE

    RD1 --> RD2
    RD2 -->|"R=2:膜電位、上次時間"| STEP1
    RD1 -->|"R=1:膜電位、上次時間"| STEP1
    RD2 -->|"R=2:整組權重"| TAP
    RD1 -->|"R=1:整組權重"| TAP
    PIPE -->|"tap"| TAP
    PIPE -->|"時間"| STEP1
    TAP --> STEP1
    STEP1 --> N_CUT
    CUT -->|"C=2"| STEP2
    STEP1 -->|"C=1 直接接"| STEP2
    PIPE -->|"o_c(門檻)"| STEP2

    PIPE --> CC
    HELD --> CC
    STEP2 -->|"新膜電位"| WB
    PIPE -->|"寫回位址、時間"| WB
    CC --> WB
    STEP2 -->|"spike"| PEND
    BM --> PEND
    CC --> PEND
    PEND --> SS
    PIPE -->|"o_y、o_x"| SS
    SS --> OUT
    SS --> LEFT
    READY --> LEFT
    LEFT --> N_BM
    PEND -->|"個數"| FL
    READY --> FL
    FL --> STALL

    PIPE --> BLOCK
    STALL --> RNO
    BLOCK --> RNO
    RNO --> RDREQ
    RNO --> TAKE
    RNO --> N_PIPE
    TAKE --> N_EV
    STALL --> N_PIPE
    STALL --> N_HELD
    STALL --> N_RD
```

## 看圖的重點

- 讀位址只看最上面那排暫存器和 FIFO(第 2 段),不等 `stall`:下一個 o_c 是誰，這一拍一開始就知道。等 `stall` 的只有讀取開關。
- 同一拍裡三塊處理的是三個不同的 o_c(L=3 時)。讀用 CandidateGrid 剛算出的 `grid_*`,寫回用 `pipe_*[L]`,選權重和算時間間隔用 `pipe_*[R]`。
- 讀出暫存器跟管線位置用同一組條件移動：讀出第一級只在 `read_next_oc` 那拍讀，第二級起在 `stall`=0 時推。所以停住的拍子，位置 R 的 o_c 跟它的資料一起留著。
- 切點暫存器每拍都存，不接 `stall`。位置 L 只在剛到那拍(`compute_cycle`)用它，那拍它存的剛好是這個 o_c 的前半結果;停住的拍子不寫回，fire 改從 bitmask 拿。
- `fires_left` 只看要送的 fire 個數跟 `out_ready`,不等 SpikeSelect 挑完，`stall` 那條路比較短。
- 控制訊號每拍的值、四個逐拍例子，見 [SaltConvControl.md](SaltConvControl.md)。
