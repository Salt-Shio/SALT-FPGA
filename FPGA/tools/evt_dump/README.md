# evt_dump

PS 端驗證/量測程式:`open` V4L2 capture 裝置 → `mmap` → 依 `EventProcessor.sv:143` 的實際 bit 排列拆出 `(x, y, type, t)`。不做任何 EVT2.1 解碼,PL 端已經做完了。

兩種輸出模式:

- 預設(不加 `-o`):逐筆 `printf` 到 stdout,適合少量資料肉眼看,對應 TODO 步驟 10(上板驗證)的原始用途。
- `-o <path>`:整塊 DMA buffer 直接 `write()` 成原始二進位(8 bytes/筆,不逐筆解析成文字),事件率高時也來得及寫,配合 `docs/FPGA/Todo/ps_host_if_replacement_todo.md` 項目 5(資料視覺化)使用。檔案內容跟裝置 mmap 出來的 buffer 逐 byte 相同,本機端用 `numpy.fromfile(dtype=np.uint64)` 讀回即可,每個 word 依同一份 bit 排列拆出 x/y/type/t。

不管哪種模式,都會每秒印一行事件率統計(events/s、MB/s)到 stderr,結束時印總結(總筆數、總耗時、平均事件率)——這是量測實際場景事件率的主要用途,不用另外寫量測工具。

## 選項

```
evt_dump [-n count] [-t seconds] [-o path] /dev/videoN
  -n count    最多處理幾筆事件(省略則不限制)
  -t seconds  最多錄幾秒(依處理端時間,省略則不限制)
  -o path     存成原始二進位檔;省略則逐筆印到 stdout
```

沒有 `-n`/`-t` 時用 Ctrl+C 結束。存檔位置建議用 `/tmp` 下的路徑(RAM,tmpfs),不要直接寫 SD 卡的掛載點——SD 卡實測持續寫入只有 10.6 MB/s,細節見 `docs/FPGA/Concept/ps_host_if_replacement_notes.md`「`evt_dump` 資料視覺化擷取」那節。

## 依賴

- 需要 `FPGA/driver/` 那份 kernel driver 先 `probe()` 成功、生出一個 V4L2 capture 裝置節點,這支程式才有東西可以 `open`。已在板子上驗證可行,見 `docs/FPGA/Todo/ps_host_if_replacement_todo.md` 項目 10/11。
- 裝置節點路徑當參數傳(`evt_dump /dev/videoN`),不寫死 `/dev/video0`——實際編號要看 `probe()` 順序,`video_register_device()` 用的是自動分配(`-1`),不保證每次都是 0。

## 先用假資料驗證

`REG_CONFIG.enable_pattern` 開啟時(`EventProcessor.sv:171-172`),`x` 是每收走一筆就 +1 的計數器,`y`/`type`/`t` 全部固定 0。driver 能生出裝置節點之後,不用接真感測器,先開 `enable_pattern`,看這支程式印出 `x=0,1,2,3...` 遞增、其餘欄位是 0,就代表整條路通了。

## 編譯

```
CROSS_COMPILE=aarch64-linux-gnu- make
```

`CROSS_COMPILE` 預設就是 `aarch64-linux-gnu-`,WSL 裡已確認裝有這套工具鏈,`-Wall -Wextra` 下編譯乾淨無警告。
