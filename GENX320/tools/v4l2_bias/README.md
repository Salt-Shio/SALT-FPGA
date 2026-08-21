# v4l2_bias

GenX320 感測器 bias 設定工具:直接對 sensor subdev(`/dev/v4l-subdevN`)操作 V4L2 control,不依賴 `metavision_viewer`。

跟 `ps_host_if` 替換完全無關,走完全不同的裝置節點——bias 寫入路徑是 `/dev/v4l-subdevN`(sensor entity)→ `VIDIOC_S_EXT_CTRLS` → genx320 sensor driver → I2C 寫入感測器晶片,不經過 `/dev/video0` 那條事件擷取路徑,不受本專案 evtdec bitstream/driver 的影響。

## 運作原理

bias(`bias_fo`/`bias_hpf`/`bias_diff_on`/`bias_diff_off`/`bias_diff`/`bias_refr`)不是標準 `V4L2_CID_*` 常數,是 genx320 sensor driver 自訂的 control,沒有固定 CID 可以寫死引用。

作法對照官方 `openeb`(`hal_psee_plugins/src/boards/v4l2/v4l2_controls.cpp`)的機制:用 `VIDIOC_QUERY_EXT_CTRL` 迴圈列舉裝置上全部 control,名稱開頭是 `bias_` 的收進來;讀寫用 `VIDIOC_G_EXT_CTRLS`/`VIDIOC_S_EXT_CTRLS`,靠名稱字串比對找到對應的 control id。不需要事先知道板子上實際有哪些 bias、也不用寫死任何 CID 數字。

## 選項

```
v4l2_bias /dev/v4l-subdevN list
v4l2_bias /dev/v4l-subdevN load <path.bias>
```

- `list`:列出裝置上所有 `bias_*` control 的名稱、目前值、合法範圍、預設值。
- `load <path.bias>`:讀取 `.bias` 檔案,逐筆設定。**先驗證全部項目都存在且在合法範圍內,一筆有誤就整批中止,不會寫入任何一筆**;全部通過後才逐筆寫入,並印出每個 bias 的名稱與寫入值。

## `.bias` 檔案格式

每行「`<數值> % <名稱>`」,數值可十進位或 `0x` 開頭十六進位,例如:

```
29 % bias_fo
0  % bias_hpf
40 % bias_diff_on
40 % bias_diff_off
51 % bias_diff
82 % bias_refr
```

空行、開頭是 `%` 的行(header/註解)會被略過。跟官方 `metavision_viewer -b` 用的 `.bias` 檔案(例如 `genx320es_CD_standard.bias`)格式相容,可以直接拿來用。

## 依賴

- 感測器要先通電,bias 才寫得進去、寫入後才持續生效(即使寫 bias 的程式已經結束、換別支程式接手擷取事件):

  ```bash
  sudo sh -c "echo on > /sys/class/video4linux/v4l-subdevN/device/power/control"
  ```

  這步驟由使用者自己做,不是這支工具的責任。

- 裝置節點路徑當參數傳,不寫死——用 `media-ctl -p` 找出 genx320 對應的 `/dev/v4l-subdevN`(編號依 `probe()` 順序,不保證每次都一樣)。

## 編譯

```
CROSS_COMPILE=aarch64-linux-gnu- make
```

`CROSS_COMPILE` 預設就是 `aarch64-linux-gnu-`。
