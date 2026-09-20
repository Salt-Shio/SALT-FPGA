#!/usr/bin/env python
"""
evt_pixel_idle_stats.py — 統計每個 (x, y, polarity) channel 兩次事件之間的間隔。

動機:CSNN PL 端 conv IP 設計討論到「每個神經元最多可以沉默(沒被事件碰到)多久」
這個問題(見 docs/SNN/Concept/conv_event_scatter_banking_derivation.md 第 14 節、
docs/GENX320/Reference 查證過感測器雜訊沒有官方的 per-pixel 保證)。這支腳本用
evt_dump -o 實際錄下來的原始事件,直接統計每個 (x,y,polarity) channel(conv1
輸入端就是逐一對應到 (x_i,y_i,ic) 的組合)兩次事件之間的最長間隔——這是實測觀察,
不是理論上界,錄製時間之外可能存在更長的沉默,不能當成正式保證使用。

事件 bit 排列跟 evt_visualize.py 相同(來源 EventProcessor.sv:143):
  [63:57] 未使用  [56:46] x(11)  [45:35] y(11)  [34] type(1)  [33:0] t(34,微秒)

用法:
  python evt_pixel_idle_stats.py <input1.bin> [input2.bin ...] [--width 320] [--height 320]
"""

import argparse
import sys

import numpy as np


def load_events(path):
    raw = np.fromfile(path, dtype=np.uint64)
    if raw.size == 0:
        raise ValueError(f"{path} 是空檔案,沒有事件可以讀")
    t = (raw & 0x3FFFFFFFF).astype(np.int64)
    type_ = ((raw >> 34) & 0x1).astype(np.int8)
    y = ((raw >> 35) & 0x7FF).astype(np.int32)
    x = ((raw >> 46) & 0x7FF).astype(np.int32)
    return x, y, type_, t


def decode_channel(channel_id, width):
    type_ = int(channel_id % 2)
    xy = channel_id // 2
    y = int(xy // width)
    x = int(xy % width)
    return x, y, type_


def analyze(path, width, height):
    x, y, type_, t = load_events(path)

    valid = (x < width) & (y < height)
    dropped = int(np.count_nonzero(~valid))
    if dropped:
        print(
            f"警告:{path} 有 {dropped} 筆事件 x/y 超出 {width}x{height} 範圍,已忽略",
            file=sys.stderr,
        )
        x, y, type_, t = x[valid], y[valid], type_[valid], t[valid]

    n_events = len(t)
    duration_us = int(t[-1] - t[0]) if n_events else 0
    total_channels = width * height * 2

    # channel id: (y*width+x)*2+polarity,每個 channel 對應 conv1 輸入端
    # 的一組 (x_i,y_i,ic)
    channel = (y.astype(np.int64) * width + x.astype(np.int64)) * 2 + type_.astype(np.int64)

    # t 本身是感測器輸出時間序,單調不減;stable sort 依 channel 分組後,
    # 同一 channel 內部仍保持原本的時間先後順序
    order = np.argsort(channel, kind="stable")
    ch_sorted = channel[order]
    t_sorted = t[order]

    touched_channels = int(np.unique(ch_sorted).size) if n_events else 0
    never_touched = total_channels - touched_channels

    print(f"=== {path} ===")
    print(f"事件數 {n_events:,},時長 {duration_us / 1e6:.3f} s")
    print(
        f"總 channel 數(x*y*polarity)= {total_channels:,},"
        f"錄製期間至少被摸到 1 次的 channel 數 = {touched_channels:,}"
        f"({touched_channels / total_channels * 100:.1f}%)"
    )
    print(
        f"整段錄製期間從未被摸到的 channel 數 = {never_touched:,}"
        f"({never_touched / total_channels * 100:.1f}%)"
        " —— 這些 channel 的『最長沉默時間』至少是整段錄製時長,"
        "實際可能更長,這份資料估不出真正上限"
    )

    if n_events < 2:
        print("事件數不足,無法統計間隔\n")
        return

    diffs = np.diff(t_sorted)
    same_channel = np.diff(ch_sorted) == 0
    valid_gaps = diffs[same_channel]

    if valid_gaps.size == 0:
        print("沒有任何 channel 被摸到超過 1 次,無法統計間隔\n")
        return

    pct = np.percentile(valid_gaps, [50, 90, 99, 99.9])
    max_gap = int(valid_gaps.max())
    max_idx = int(np.argmax(np.where(same_channel, diffs, -1)))
    mx, my, mtype = decode_channel(int(ch_sorted[max_idx]), width)

    print(
        f"有 >=2 筆事件的 channel,兩次事件間隔(us)分布:"
        f" p50={pct[0]:.0f}  p90={pct[1]:.0f}  p99={pct[2]:.0f}  p99.9={pct[3]:.0f}"
        f"  max={max_gap:,}us(={max_gap / 1000:.1f}ms)"
        f"  發生於 channel (x={mx}, y={my}, polarity={mtype})"
    )
    print()


def main():
    parser = argparse.ArgumentParser(description="每個 (x,y,polarity) channel 的事件間隔統計")
    parser.add_argument("inputs", nargs="+", help="一或多個 evt_dump -o 存的 .bin 路徑")
    parser.add_argument("--width", type=int, default=320, help="感測器寬度(預設 320)")
    parser.add_argument("--height", type=int, default=320, help="感測器高度(預設 320)")
    args = parser.parse_args()

    for path in args.inputs:
        analyze(path, args.width, args.height)


if __name__ == "__main__":
    main()
