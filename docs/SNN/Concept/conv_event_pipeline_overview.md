# 事件驅動 Conv IP:單一事件的完整處理流程總覽

精簡版,只寫結論。
每一步的證明、公式推導都連回 [`conv_event_scatter_banking_derivation.md`](conv_event_scatter_banking_derivation.md)(以下簡稱「詳細文件」)對應章節,不重複寫推導過程。

## 0. 範圍

涵蓋單一 conv 層(conv1/conv2/compress 各自一份 instance)處理一筆輸入事件,直到可能產生輸出事件為止。
不涵蓋 channel 之間如何平行(目前是序列化,見步驟 6)、FIFO 前級的細節。

## 1. 輸入事件抵達

事件格式:$(x_i,y_i,ic,t)$。

- $x_i,y_i$:輸入座標
- $ic$:輸入 channel(對 conv1 就是 GenX320 的 polarity)
- $t$:時間戳記。第一層(conv1)收到的是 EvtDecoder 給的原始 µs;conv2/compress 收到的是上一層直接送來的 $m_{cur}$(ms,不是 µs)

除數參數 $D$ 決定要不要轉換:conv1 的 $D=1000$(µs→ms),conv2/compress 的 $D=1$(已經是 ms,直接透傳)。算出 $m=\lfloor t/D\rfloor$。詳細文件第 14.4 節。

## 2. 算出合法輸出位置與對應的 kernel tap

同一拍用組合邏輯算完,不需要額外的 clock。

- 單軸合法輸出範圍:$\lceil(i+P-K+1)/S\rceil \le o \le \lfloor(i+P)/S\rfloor$(詳細文件式 1,第 4 節)
- 這個範圍內的整數解恆連續、個數不超過 $N=\lceil K/S\rceil$(第 5、6 節)
- 兩軸各自套用,組合出最多 $N\times N$ 個候選輸出位置(第 7 節)
- 每個候選 $o$ 對應的 kernel tap:$k=i-oS+P$(第 10.1 節)
- 每個候選位置各自算出 bank $=(o_y\bmod N,\,o_x\bmod N)$、bank 內位址(第 8、9 節)

## 3. 讀取權重與膜電位

$N\times N$ 個候選位置在不同 bank,平行各自讀取,以下描述單一候選的動作。

- 權重:row $=oc\times IC+ic$ 選出一整塊 $K\times K$ 打包權重,再用步驟 2 算出的 $k_y,k_x$ 從中 mux 出這個 tap(第 11 節)
- 膜電位:同一個 addr 讀出 $V+m_{cur}$ 打包的 word(第 9.4 節),$V$ 是這個神經元的累加值,$m_{cur}$ 是它上次更新到哪個 ms
- BRAM 是 1-cycle 同步讀取延遲(第 12.1 節)

## 4. LIF 結算規則

比較這筆事件的 $m$ 跟讀出來的 $m_{cur}$(詳細文件第 14.2 節):

**同一 ms**($m=m_{cur}$):只累加,不結算。

$$V \leftarrow V + \frac{w}{\tau}$$

**跨 ms**($m>m_{cur}$,$N=m-m_{cur}-1$ 為中間空的 ms 數):結算上一個 ms、套用空 ms 的 decay、疊上這筆新事件。

$$
s=\mathbb1[V\ge v_{th}]
\qquad
V \leftarrow (s\,?\,0:V)\times\left(1-\frac1\tau\right)^{N+1} + \frac{w}{\tau}
\qquad
m_{cur}\leftarrow m
$$

$\left(1-\frac1\tau\right)^{N+1}$ 用查表,$N$ 太大直接視為衰減到 0(第 14.5 節)。

$w$ 是步驟 3 讀出的權重 tap 值。$s=1$ 代表這個神經元 fire,進步驟 7。

## 5. 寫回膜電位

更新後的 $V+m_{cur}$ 寫回同一個 addr。寫入位址是讀取當下就算好、延遲 1 拍送到寫入 port,不是重新計算(第 12.2 節)。

## 6. Channel 序列化

步驟 3~5 對每個 $oc=0,\ldots,OC-1$ 依序做一次,穩態下 1 個 clock 處理 1 個 $oc$,整筆事件跑完要 $OC+2$ 拍(第 13 節)。

conv1/compress 各 10 拍($OC=8$),conv2 34 拍($OC=32$)。事件間 pipeline overlap 目前評估後不做(第 13.3 節)。

## 7. 輸出事件

步驟 4 若 $s=1$(fire),組出新事件送給下一層:

$$
(o_y,\,o_x,\,oc,\,t_{\text{輸出}}=m_{cur})
$$

時間戳記直接是 $m_{cur}$(ms),不換算回 µs——只有 conv1 的輸入端做過 µs→ms 轉換,層間全部是 ms 傳 ms(第 14.4 節)。

## 參考

| 主題 | 位置 |
|---|---|
| 完整推導、證明 | [`conv_event_scatter_banking_derivation.md`](conv_event_scatter_banking_derivation.md) |
| 尚未定案的參數($V\_WIDTH$、ROM 深度、`FIFO_DEPTH`) | 詳細文件第 15 節 |
