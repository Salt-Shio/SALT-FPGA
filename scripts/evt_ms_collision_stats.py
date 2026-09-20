#!/usr/bin/env python
"""
evt_ms_collision_stats.py — 統計同一個 (x,y,polarity) channel、同一個 1ms 窗口
內出現 >=2 筆事件的比例。

動機:討論連續時間 LIF(逐事件立刻算)跟 spikingjelly 1ms 網格離散模型的差距時
確認過,兩者的計算結果只在「同一個神經元、同一個 1ms 窗口內被摸到 >=2 次」這種
情況才會分岔,其他情況(每個 ms 至多一筆事件、或整段空 ms)兩個模型算出來完全
一樣。這支腳本用 evt_dump -o 錄下來的真實事件,量這種「碰撞」窗口在實際場景裡
有多常發生。

事件 bit 排列跟 evt_visualize.py 相同(來源 EventProcessor.sv:143)。

用法:
  python evt_ms_collision_stats.py <input1.bin> [input2.bin ...] [--width 320] [--height 320] [--ms-div 1000]
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


def analyze(path, width, height, ms_div):
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
    print(f"=== {path} ===")
    print(f"事件數 {n_events:,},時長 {(t[-1] - t[0]) / 1e6:.3f} s(--ms-div={ms_div})")

    if n_events == 0:
        print()
        return

    channel = (y.astype(np.int64) * width + x.astype(np.int64)) * 2 + type_.astype(np.int64)
    m = t // ms_div
    m_span = int(m.max()) + 1

    # (channel, m) 合併成單一整數 key,用排序去重數每個 (channel,m) 組合出現幾次
    # ——這就是「同一個神經元、同一個 1ms 窗口」被摸到幾次
    key = channel * m_span + m
    _, counts = np.unique(key, return_counts=True)

    total_pairs = len(counts)
    collide_mask = counts >= 2
    collide_pairs = int(np.count_nonzero(collide_mask))
    solo_pairs = total_pairs - collide_pairs

    events_in_collision = int(counts[collide_mask].sum())
    events_solo = int(counts[~collide_mask].sum())
    assert events_in_collision + events_solo == n_events

    print(
        f"(channel, ms) 組合總數 = {total_pairs:,}"
        f"(單一神經元、單一 ms 窗口被摸到 >=1 次算一組)"
    )
    print(
        f"其中被摸到 >=2 次(碰撞)的組合數 = {collide_pairs:,}"
        f"({collide_pairs / total_pairs * 100:.3f}% of touched pairs)"
    )
    print(
        f"落在碰撞窗口裡的事件數 = {events_in_collision:,}"
        f"({events_in_collision / n_events * 100:.3f}% of all events)"
        f"  ——這部分事件,連續時間模型跟離散 1ms 模型算出來的軌跡可能從這裡開始分岔"
    )

    if collide_pairs:
        collide_counts = counts[collide_mask]
        pct = np.percentile(collide_counts, [50, 90, 99])
        print(
            f"碰撞窗口內的事件數分布:p50={pct[0]:.0f}  p90={pct[1]:.0f}  p99={pct[2]:.0f}"
            f"  max={int(collide_counts.max())}"
        )
    print()


def main():
    parser = argparse.ArgumentParser(description="同一 channel 同一 1ms 窗口內多筆事件(碰撞)統計")
    parser.add_argument("inputs", nargs="+", help="一或多個 evt_dump -o 存的 .bin 路徑")
    parser.add_argument("--width", type=int, default=320, help="感測器寬度(預設 320)")
    parser.add_argument("--height", type=int, default=320, help="感測器高度(預設 320)")
    parser.add_argument("--ms-div", type=int, default=1000, help="us->ms 除數(預設 1000,對應 conv1 的 D)")
    args = parser.parse_args()

    for path in args.inputs:
        analyze(path, args.width, args.height, args.ms_div)


if __name__ == "__main__":
    main()
