# Conv 層事件驅動 RTL 設計

## 1. 輸入

- **格式**：一筆事件是 $(x,y,c,t)$，`spatial 格式`
    - $x,y$：輸入空間座標，位寬分別是 $X\_WIDTH$、$Y\_WIDTH$
    - $c$：輸入通道，位寬 $C\_WIDTH$
    - $t$：事件時間戳記，位寬 $T\_WIDTH$，單位是整數 µs 或 ms(依所在層而定)
    - 以上位寬都是編譯期參數

- **協定**：
    - 沿用 `AXI4-Stream` 的 valid/ready 握手，一個 beat 對應一筆事件
    - 事件先進一個`輸入 FIFO`，深度是可配置參數

- **順序假設**：
    - 上游保證事件依時間非遞減送達
    - 同一時間戳記內的多筆事件，先後順序由上游決定，這裡照收不重排

## 2. 從 $(x,y,c)$ 取出 $w$、$V$、$m_{last}$

- **這一步的範圍**：
    - 定義每個候選要去哪個位址取 $w$、$(V,m_{last})$，以及為什麼這樣安排位址
    - `第幾拍讀、第幾拍寫、需要幾個埠`這種時序問題留到 pipeline 化階段

### 神經元

- **候選神經元是誰**：一筆事件的 $(x,y,c)$ 會影響哪些輸出神經元 $(oc,o_y,o_x)$
    - 這裡的設計想法是：一個輸入 $(x,y,c)$ 會影響多個輸出神經元 $(oc,o_y,o_x)$
    - $1$ 個 `clock` 內只處理 $1$ 個 `輸出 channel`，意思是同一筆事件最少要花 $OC$ `clock` 才能處理，每個 `clock` 只處理最多 $M \times M$ 個神經元
        - 要一步處理完 $M \times M$ 個神經元的方式，就是開 $M \times M$ 個 Bram Banking
    - 以下只探討處理單個 `輸出 channel` 的情況
- 用感受野反推單軸候選範圍(用 $i$ 代表 $y$ 或 $x$，兩軸各自代入同一條公式)：
    $$
    o_{min} = \left\lceil \dfrac{i+P-K+1}{S} \right\rceil
    \qquad
    o_{max} = \left\lfloor \dfrac{i+P}{S} \right\rfloor
    $$
    - 最多 $M=\lceil K/S\rceil$ 個合法值，跟 $i$ 的實際數值無關
    - 合法 $o$ 落在 $[\max(o_{min},0),\ \min(o_{max},\,O_{max}-1)]$
        - 也就是會影響 $(1 \to M \times M) \times OC$ 顆神經元
    - $O_{max}$ 是這一軸的輸出維度：$i=y$ 時是 $H_{out}$，$i=x$ 時是 $W_{out}$
    
    - 兩軸合併：$o_y$ 最多 $M$ 個、$o_x$ 最多 $M$ 個、$oc$ 有 $OC$ 個，一筆事件最多觸及 $M\times M\times OC$ 顆候選神經元


- **記憶體型態**：BRAM，存每顆神經元的 $(V,m_{last})$

- **banking**：bank 編號 $(o_y \bmod M,\ o_x \bmod M)$，共 $M\times M$ 個 bank
    - 合法候選的 $o_y$、$o_x$ 各自是 $M$ 個連續整數(上面已證)
    - 對 $M$ 取模保證落在 $M\times M$ 個不同 bank，同一事件枚舉出的候選之間`不會有兩個落在同一個 bank`

- **bank 內部位址**：$(oc,\ \lfloor o_y/M\rfloor,\ \lfloor o_x/M\rfloor)$ 攤平後的索引

- **每個 bank 容量**：$OC\times\lceil H_{out}/M\rceil\times\lceil W_{out}/M\rceil$ 筆 $(V,m_{last})$
    - 邊界不整除的細節待補

### 權重

- **記憶體型態**：BRAM，唯讀
    - 權重訓練完就固定，不需要寫入埠

- **陣列與定址**：概念上是一個二維陣列 $W[oc,c]$
    - 位址是 $(oc,c)$ 攤平的索引，深度 $OC\times C$
    - `每個位址存的不是單一權重，而是一整個 kernel`：$K\times K$ 個權重打包成一個寬字
    - 寬字位寬 $=K\times K\times B$($B$ 是單一權重的位元寬度)

- **kernel tap**：沿用`神經元`小節已經算出的 $o_y,o_x$
    $$
    k_y = y - o_yS + P
    \qquad
    k_x = x - o_xS + P
    $$

- **從寬字選出這個候選要的權重**：
    - 讀出 $W[oc,c]$ 這個寬字後，用 $(k_y,k_x)$ 當 select 訊號，取出 tap 位置 $k_y\times K+k_x$ 的那個權重
    - 這是`讀出後`的組合邏輯多工($K\times K$ 選 1)，不是另一次定址
    $$
    w = W[oc,c][\,k_y\times K+k_x\,]
    $$

## 3. 用 $w,V,m_{last},t$ 算膜電位更新

前一步提到，在某個 `clock` 也是處理某一個 `輸出 channel` 拿到的資料:
* 原本的輸入事件 $(x,y,c,t)$
* 多組: 神經元 $(oc,o_y,o_x) \to (V,m_{last})$
* 多組: 權重 $w$，這個候選神經元對應的 $W[oc, c][k_y \times K + k_x]$
* 以下探討其中一組

---

- 收到這筆事件 $(x,y,c,t)$，被影響的神經元膜電位 $V$ 會變成多少
    $$
    N = t - m_{last}
    \qquad
    h = V\times\left(1-\frac1\tau\right)^{N} + w
    $$

    - **$h \ge v_{th}$：這顆神經元 fire**
        - 產生一個 $\color{red} spike$，$s=1$
        - 膜電位`歸零`(hard reset)：$V_{new}=0$——這次累積的電位燒完，下次事件從 0 重新累積

    - **$h < v_{th}$：不 fire**
        - 不產生 $\color{red} spike$，$s=0$
        - 膜電位`保留`這次算出來的 $h$：$V_{new}=h$——下次事件再從這個值繼續衰減、疊加

    - **不管有沒有 fire，$m_{last}$ 都更新成 $t$**：下次事件要拿這個時間點重新算衰減量 $N$，跟這次有沒有 fire 無關

- **合併成單一條件式(實作時的寫法)**：
    $$
    s = \mathbb{1}[\,h \ge v_{th}\,]
    \qquad
    V_{new} = s\ ?\ 0 : h
    \qquad
    m_{last,new} = t
    $$
    - $\tau$、$v_{th}$ 是這一層(或這一個輸出 channel)的編譯期參數
    - 這裡算完後存回去對應的神經元位置

## 4. spike 與輸出事件

- 一個 `clock` 內，對某個 `輸出 channel` 會更新多顆 $(0 \to M \times M)$
    - 意思是可能有 $(0 \to M \times M)$ 顆神經元同時 fire，也就是會輸出 $(0 \to M \times M)$ 個事件給下一個 layer

- **問題**：輸出介面一次只能送一筆事件，這 $(0\to M\times M)$ 個 fire 沒辦法同一拍全部送出去，要有地方暫存、有規則決定先送哪個

- **暫存這些 fire**：一個 $M\times M$ bit 的`待送 bitmask`暫存器，每個 bit 對應一個 bank
    - 這一拍 Part 3 算出的 $s$，哪個 bank 是 $1$ 就把 bitmask 對應那個 bit 設成 $1$
    - 每個 bank 自己的 $(o_y,o_x)$ 在`神經元`小節決定候選時就算好了，這裡直接拿來用，不用重算

- **每個 clk 的動作(bitmask 不是全 $0$ 的時候)**：
    1. 在還亮著(值是 $1$)的 bit 裡，比 $(o_y,o_x)$ 大小(先比 $o_y$，再比 $o_x$)找出最小的那個
    2. 把這個 bank 的 $(oc,o_y,o_x,t)$ 送出去(送出格式依下一層類型，見第 1 部分同一套規則)
    3. 把這個 bit 清成 $0$

- **推進 $oc+1$ 的條件**：這一拍動作做完後，bitmask 是不是變成全 $0$
    - 是：這個 $oc$ 的 fire 全部送完，推進到 $oc+1$，發起下一輪讀取
    - 不是：留在原地，下一個 clk 繼續跑同一套動作

### 補充:「在還亮著的 bit 裡找最小 $(o_y,o_x)$」怎麼用電路做

- **核心技巧：把沒亮的 bit 變成「一定輸」**
    - 幫每個 bank 組一個`比較鍵`：把它的 bitmask 那個 bit 取反後放在最高位，後面接 $(o_y,o_x)$
    $$
    key_j = \{\,\overline{\text{bitmask}_j},\ o_y[j],\ o_x[j]\,\}
    $$
    - 最高位權重最大，只要最高位是 $1$，這個 $key_j$ 一定比任何有效的 $key$ 大——等於自動把沒亮的 bit 排除掉，不用另外寫判斷式去濾掉它們
        - $bitmask_j=1$(有效)時，$key_j$ 最高位是 $0$
        - $bitmask_j=0$(無效)時，$key_j$ 最高位是 $1$
    
- **找最小值：二元比較樹**
    - $M\times M$ 個 $key_j$ 兩兩一組送進比較器，每組留下較小的那個，連同它是哪個 bank 的編號一起往下傳
    - 贏的人繼續兩兩比，一路比到剩最後一個——這是 $\log_2(M\times M)$ 層的樹狀結構
    - 最後剩下的那一個，就是 `目前所有還亮著的 bank 裡 (oy,ox) 最小的那個`，附帶它的 bank 編號

- **這整段是組合邏輯，同一拍就算完**：不需要額外的 clock，上面「每個 clk 的動作」那三個步驟(找最小、送出、清 bit)其實是同一拍發生的

- **RTL 怎麼寫**：不用手動把每一層比較器實例化出來，寫成一般的 for 迴圈或 `if-else` 優先權描述就好，實際的樹狀結構由 Vivado 綜合工具自動生成
