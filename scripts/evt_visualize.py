#!/usr/bin/env python
"""
evt_visualize.py — 播放 evt_dump -o 存的原始事件檔案(.bin)。

PL 端輸出固定 8 bytes/筆的事件,沒有一般攝影機那種「一張張畫格」的概念,
是連續的 (x, y, type, t) 事件流(t 微秒)。要看成動畫,得自己決定「每隔
多少微秒切一刀」把這段時間內的事件疊成一張圖——這個切法就是
--accum-us(累積時間窗口)。切太短畫面稀疏、閃爍;切太長同一張圖疊太多
事件糊成一團。預設 10000(10ms)跟官方 metavision_viewer 原始碼寫死的值
一致(openeb sdk/modules/stream/cpp/samples/metavision_viewer/
metavision_viewer.cpp:set_display_accumulation_time_us(10000))。

播放採真實時間:每張圖在畫面上停留的時間等於它代表的 accum-us 長度,
播放總長度自然等於原始擷取時長(錄 10 秒,播放也是 10 秒)。

事件 bit 排列來源:EventProcessor.sv:143(跟 GENX320/tools/evt_dump/evt_dump.c
的 print_event() 是同一份定義):
  m_data_q <= {td_x + x_offset, td_y, td_type[0], time_high_q, td_time};
  [63:57] 未使用  [56:46] x(11)  [45:35] y(11)  [34] type(1)  [33:0] t(34,微秒)

互動操作(播放邏輯照抄 D:\\Project\\SNN\\main\\debug.py 的
SNNVisualDebugger:Slider + 方向鍵單步 + 空白鍵播放/暫停,不是
FuncAnimation):
  - 拖曳下方 Slider 看任一個時間點
  - 左右鍵單步
  - 空白鍵播放/暫停

用法:
  python evt_visualize.py <input.bin> [--width 320] [--height 320] [--accum-us 10000]
"""

import argparse
import sys
import time

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap
from matplotlib.widgets import Slider

# 背景(0)、OFF 事件(-1)、ON 事件(1)——跟 debug.py 其他 viewer 的
# pos=red/neg=blue 極性配色慣例一致
FRAME_CMAP = ListedColormap(["blue", "white", "red"])


def load_events(path):
    raw = np.fromfile(path, dtype=np.uint64)
    if raw.size == 0:
        raise ValueError(f"{path} 是空檔案,沒有事件可以讀")

    t = (raw & 0x3FFFFFFFF).astype(np.int64)
    type_ = ((raw >> 34) & 0x1).astype(np.int8)
    y = ((raw >> 35) & 0x7FF).astype(np.int32)
    x = ((raw >> 46) & 0x7FF).astype(np.int32)
    return x, y, type_, t


def build_frames(x, y, type_, t, width, height, accum_us):
    valid = (x < width) & (y < height)
    if not np.all(valid):
        dropped = int(np.count_nonzero(~valid))
        print(
            f"警告:{dropped} 筆事件的 x/y 超出 {width}x{height} 範圍,已忽略"
            "(可能是 --width/--height 跟實際感測器解析度不一致)",
            file=sys.stderr,
        )
        x, y, type_, t = x[valid], y[valid], type_[valid], t[valid]

    t0 = t[0]
    frame_idx = ((t - t0) // accum_us).astype(np.int64)
    n_frames = int(frame_idx[-1]) + 1
    polarity = np.where(type_ == 1, 1, -1).astype(np.int8)

    frames = np.zeros((n_frames, height, width), dtype=np.int8)
    # t(因此 frame_idx)是感測器輸出的時間序,單調不減,搜尋每個 frame
    # 的起訖區間比逐張圖掃過整個事件陣列快
    frame_starts = np.searchsorted(frame_idx, np.arange(n_frames + 1))
    for f in range(n_frames):
        s, e = frame_starts[f], frame_starts[f + 1]
        if e > s:
            # 同一像素在窗口內多筆事件,依時間序覆寫,最後一筆事件的極性勝出
            frames[f, y[s:e], x[s:e]] = polarity[s:e]

    return frames, t0


class EventPlayer:
    def __init__(self, frames, accum_us):
        self.frames = frames
        self.n_frames = frames.shape[0]
        self.accum_us = accum_us
        self.is_playing = [False]

    def build_gui(self):
        self.fig, self.ax = plt.subplots(figsize=(6, 6.5))
        plt.subplots_adjust(bottom=0.18)

        self.im = self.ax.imshow(self.frames[0], cmap=FRAME_CMAP, vmin=-1, vmax=1)
        self.ax.axis("off")

        ax_time = plt.axes([0.15, 0.06, 0.7, 0.03])
        self.slider = Slider(ax_time, "Frame", 0, self.n_frames - 1, valinit=0, valstep=1)
        self.slider.on_changed(self.update)

        self.fig.canvas.mpl_connect("key_press_event", self.on_key)

    def update(self, _val):
        f = int(self.slider.val)
        self.im.set_data(self.frames[f])
        total_s = self.n_frames * self.accum_us / 1e6
        cur_s = f * self.accum_us / 1e6
        self.fig.suptitle(
            f"Frame {f}/{self.n_frames - 1}   t={cur_s:.3f}s / {total_s:.3f}s\n"
            "space = play/pause    <-/-> = step",
            fontsize=11,
        )
        self.fig.canvas.draw_idle()

    def on_key(self, event):
        f = int(self.slider.val)
        if event.key == "right":
            self.slider.set_val(min(f + 1, self.n_frames - 1))
        elif event.key == "left":
            self.slider.set_val(max(f - 1, 0))
        elif event.key == " ":
            self.is_playing[0] = not self.is_playing[0]
            if self.is_playing[0]:
                self.play_loop()

    def play_loop(self):
        # 真實時間播放:每次迴圈直接算「現在真實經過了多少時間」該對應到
        # 哪一張 frame,直接跳過去,不是固定每次前進 1 張。matplotlib 單次
        # 重繪常常就超過 accum-us(例如 10ms)的預算,固定前進 1 張的話追
        # 不上,總長度會被拖慢成慢動作;跳著顯示才能保證總長度對齊真實
        # 擷取時長,犧牲的是「每張都畫到」,不是總時長。
        frame_dt = self.accum_us / 1e6
        play_start_wall = time.perf_counter()
        play_start_frame = int(self.slider.val)

        while self.is_playing[0] and plt.fignum_exists(self.fig.number):
            elapsed_wall = time.perf_counter() - play_start_wall
            target_frame = play_start_frame + int(elapsed_wall / frame_dt)

            if target_frame >= self.n_frames - 1:
                self.slider.set_val(self.n_frames - 1)
                self.is_playing[0] = False
                break

            if target_frame != int(self.slider.val):
                self.slider.set_val(target_frame)

            plt.pause(0.005)

    def start(self):
        print("提示:")
        print("  - 拖曳下方 Slider 看任一個時間點")
        print("  - 左右鍵單步")
        print("  - 空白鍵播放/暫停(真實時間播放,總長度等於錄製時長)")
        self.update(0)
        plt.show()


def main():
    parser = argparse.ArgumentParser(description="evt_dump -o 存的原始事件檔案累積視窗視覺化")
    parser.add_argument("input", help="evt_dump -o 存的 .bin 路徑")
    parser.add_argument("--width", type=int, default=320, help="感測器寬度(預設 320,GenX320 實際解析度)")
    parser.add_argument("--height", type=int, default=320, help="感測器高度(預設 320)")
    parser.add_argument(
        "--accum-us",
        type=int,
        default=10000,
        help="累積時間窗口,微秒(預設 10000=10ms,跟官方 metavision_viewer 寫死的值一致)",
    )
    args = parser.parse_args()

    if args.accum_us <= 0:
        parser.error("--accum-us 必須大於 0")

    x, y, type_, t = load_events(args.input)
    print(f"讀到 {len(t)} 筆事件,時間範圍 {(t[-1] - t[0]) / 1e6:.3f} 秒")

    frames, _t0 = build_frames(x, y, type_, t, args.width, args.height, args.accum_us)
    print(f"切成 {frames.shape[0]} 張 frame,每張 {args.accum_us / 1000:.1f} ms")

    player = EventPlayer(frames, args.accum_us)
    player.build_gui()
    player.start()


if __name__ == "__main__":
    main()
