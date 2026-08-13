# evt_dump

最小的 PS 端驗證程式:`open` V4L2 capture 裝置 → `mmap` → 依 `EventProcessor.sv:143` 的實際 bit 排列拆出 `(x, y, type, t)` → `printf`。不做任何 EVT2.1 解碼,PL 端已經做完了,這裡純粹是「driver → DMA → mmap 這條路通不通」的驗證工具,對應 TODO 步驟 10(上板驗證)。

## 依賴、還沒有的東西

- 需要 `FPGA/driver/` 那份 kernel driver 先能正常 `probe()`、生出一個 V4L2 capture 裝置節點,這支程式才有東西可以 `open`。driver 還沒改完暫存器配置,現在還跑不起來。
- 裝置節點路徑當參數傳(`evt_dump /dev/videoN`),不寫死 `/dev/video0`——實際編號要看 `probe()` 順序,`video_register_device()` 用的是自動分配(`-1`),不保證每次都是 0。

## 先用假資料驗證

`REG_CONFIG.enable_pattern` 開啟時(`EventProcessor.sv:171-172`),`x` 是每收走一筆就 +1 的計數器,`y`/`type`/`t` 全部固定 0。driver 能生出裝置節點之後,不用接真感測器,先開 `enable_pattern`,看這支程式印出 `x=0,1,2,3...` 遞增、其餘欄位是 0,就代表整條路通了。

## 編譯

```
CROSS_COMPILE=aarch64-linux-gnu- make
```

`CROSS_COMPILE` 預設就是 `aarch64-linux-gnu-`,WSL 裡目前有沒有裝這套交叉編譯工具鏈還沒確認。
