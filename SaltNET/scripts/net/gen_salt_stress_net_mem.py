"""產生極限測試 SaltStressNet(SaltFC Part 12)的權重檔、門檻檔,跟合成用的參數檔 generics.txt。

極限測試只合成、布局繞線,量 BRAM 用到約 84 顆時 4.8 ns 還剩多少餘裕;沒有訓練端的模型,也不模擬。
網路形狀只定義在這支腳本(CONV_LAYERS、FC_LAYERS、VERSIONS),generics.txt 把它寫成 SaltStressNet 的參數,
synth_salt_stress_net.tcl 讀進來;要調 BRAM 用量就改這裡、重跑這支,再合成。
    conv1 → conv2 → conv3 → 轉接模組 → FC1(fire)→ FC2(fire)→ FC3(輸出層,不 fire)
權重碼是 b 位元二補數全範圍的亂數(共用 scripts/conv/gen_weight_lookup_ref.py 的 synthetic_q);
門檻是 1 ~ 2^(w-1)-1 的亂數(正的,同訓練端的門檻)。用亂數是為了合成不會因為內容把 BRAM 的輸出腳修剪掉。
兩版(繞回、飽和)權重相同;門檻照各版的 w 各抽一次。寫檔用訓練端 salt_core.fpga_export 的打包函式。
衰減表不在這裡產生:synth_salt_stress_net.tcl 直接用 quant_versions.txt 指的量化資料夾裡訓練端匯出的檔
(conv1、conv2 用自己的,conv3 借 conv2 的,FC1~FC3 借 out 層的)。

輸出:<out-dir>/<wrap|saturate>/
    conv1_weight.mem ~ conv3_weight.mem、conv1_threshold.mem ~ conv3_threshold.mem、
    fc1_weight.mem ~ fc3_weight.mem、fc1_threshold.mem、fc2_threshold.mem、
    generics.txt(一行一個 NAME=value,# 開頭是註解,記 seed 跟網路形狀)

用法(WSL,conda 環境 jax,在 scripts/net 目錄執行):
    python gen_salt_stress_net_mem.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.runs/stress_net_mem
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "conv"))
from gen_weight_lookup_ref import synthetic_q, write_lines  # noqa: E402

SEED = 0

IN_CHANNELS, IN_ROWS, IN_COLS = 2, 34, 34

# (層名, OC, K, S, P);conv1、conv2 同訓練端,conv3 把 9×9 縮到 4×4,讓 FC1 的 n_in 變成 16*4*4 = 256
CONV_LAYERS = [
    ("conv1", 8, 3, 2, 1),
    ("conv2", 16, 3, 2, 1),
    ("conv3", 16, 3, 2, 0),
]

# (層名, n_out, n_col, 會不會 fire);n_in 是上一層的神經元數。n_col 都是 4:跟量過的輸出層同一種控制寬度
# 權重 BRAM 是一階一階跳的(2026-11-14 合成):Vivado 把唯讀記憶體的深度補到 2 的次方,FC1 = 512 時權重 32768 字
# × 28 位元各 28 顆、總數 73;FC1 = 576 時 36864 字補成 65536 字,各 56 顆、總數 129,而且兩顆串接、讀出暫存器併不進去
FC_LAYERS = [
    ("fc1", 512, 4, True),
    ("fc2", 256, 4, True),
    ("fc3", 10, 4, False),
]

# 各版的溢位處理跟每層 i_V:conv1、conv2、fc3(輸出層)同訓練端,新加的層同 conv2
VERSIONS = {
    "wrap": {"SATURATE": 0, "MEMBRANE_INT_WIDTH": {
        "conv1": 12, "conv2": 14, "conv3": 14, "fc1": 14, "fc2": 14, "fc3": 14}},
    "saturate": {"SATURATE": 1, "MEMBRANE_INT_WIDTH": {
        "conv1": 9, "conv2": 11, "conv3": 11, "fc1": 11, "fc2": 11, "fc3": 11}},
}

# 整個網路共用,同 SaltConvFCNet 的實際設定(synth_salt_conv_fc_net.tcl)
WEIGHT_WIDTH = 7
SHARED_GENERICS = {
    "TIME_WIDTH": 16, "WEIGHT_WIDTH": WEIGHT_WIDTH, "MEMBRANE_FRAC_WIDTH": 0, "DECAY_FRAC_WIDTH": 6, "ROUND": 1,
    "READ_LATENCY": 2, "COMPUTE_LATENCY": 2, "OVERLAP": 1,
}
DECAY_TABLE_DEPTH = 75   # 跟借來的訓練端衰減表相同
FIFO_DEPTH = 16


def conv_output_size(size: int, kernel_size: int, stride: int, padding: int) -> int:
    """(H_in + 2P - K) / S + 1,跟訓練端、SaltStressNet 的 localparam 相同。"""
    return (size + 2 * padding - kernel_size) // stride + 1


def random_thresholds(rng: np.random.Generator, count: int, membrane_width: int) -> np.ndarray:
    """count 個 1 ~ 2^(w-1)-1 的門檻。"""
    return rng.integers(1, 1 << (membrane_width - 1), size=count)


def network_shapes() -> tuple[list[tuple], list[tuple]]:
    """每層的輸入形狀:conv 回傳 (層名, C, OC, K, S, P),FC 回傳 (層名, n_in, n_out, n_col, fires)。"""
    conv_shapes = []
    channels, rows, cols = IN_CHANNELS, IN_ROWS, IN_COLS
    for name, out_channels, kernel_size, stride, padding in CONV_LAYERS:
        conv_shapes.append((name, channels, out_channels, kernel_size, stride, padding))
        rows = conv_output_size(rows, kernel_size, stride, padding)
        cols = conv_output_size(cols, kernel_size, stride, padding)
        if rows < 1 or cols < 1:
            raise RuntimeError(f"{name} 的輸出大小 {rows}x{cols} 小於 1")
        channels = out_channels
    fc_shapes = []
    in_neurons = channels * rows * cols
    for name, out_neurons, neurons_per_row, fires in FC_LAYERS:
        fc_shapes.append((name, in_neurons, out_neurons, neurons_per_row, fires))
        in_neurons = out_neurons
    return conv_shapes, fc_shapes


def generics_lines(version: str, conv_shapes: list[tuple], fc_shapes: list[tuple]) -> list[str]:
    """SaltStressNet 的整數參數,一行一個 NAME=value;資料檔路徑由合成腳本加。"""
    widths = VERSIONS[version]["MEMBRANE_INT_WIDTH"]
    lines = [f"# gen_salt_stress_net_mem.py, version {version}, seed {SEED}",
             f"IN_CHANNELS={IN_CHANNELS}", f"IN_ROWS={IN_ROWS}", f"IN_COLS={IN_COLS}"]
    for name, _, out_channels, kernel_size, stride, padding in conv_shapes:
        prefix = name.upper()
        lines += [f"{prefix}_OUT_CHANNELS={out_channels}", f"{prefix}_KERNEL_SIZE={kernel_size}",
                  f"{prefix}_STRIDE={stride}", f"{prefix}_PADDING={padding}",
                  f"{prefix}_MEMBRANE_INT_WIDTH={widths[name]}", f"{prefix}_DECAY_TABLE_DEPTH={DECAY_TABLE_DEPTH}",
                  f"{prefix}_FIFO_DEPTH={FIFO_DEPTH}"]
    for name, in_neurons, out_neurons, neurons_per_row, _ in fc_shapes:
        prefix = name.upper()
        lines += [f"# {name}: n_in {in_neurons} (derived in SaltStressNet)",
                  f"{prefix}_OUT_NEURONS={out_neurons}", f"{prefix}_NEURONS_PER_ROW={neurons_per_row}",
                  f"{prefix}_MEMBRANE_INT_WIDTH={widths[name]}", f"{prefix}_DECAY_TABLE_DEPTH={DECAY_TABLE_DEPTH}",
                  f"{prefix}_FIFO_DEPTH={FIFO_DEPTH}"]
    lines += [f"{name}={value}" for name, value in SHARED_GENERICS.items()]
    lines.append(f"SATURATE={VERSIONS[version]['SATURATE']}")
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path, help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--out-dir", required=True, type=Path, help="輸出目錄,底下每版一個子目錄")
    args = parser.parse_args()
    sys.path.insert(0, str(args.training_repo.resolve()))
    from salt_core.fpga_export import conv_weight_lines, fc_threshold_lines, fc_weight_lines, threshold_lines

    conv_shapes, fc_shapes = network_shapes()

    # 權重兩版共用,照層的順序從同一個 seed 抽
    weight_rng = np.random.default_rng(SEED)
    weight_files = {}
    for name, in_channels, out_channels, kernel_size, _, _ in conv_shapes:
        q = synthetic_q(weight_rng, (out_channels, in_channels, kernel_size, kernel_size), WEIGHT_WIDTH)
        weight_files[name] = conv_weight_lines(q, WEIGHT_WIDTH)
    for name, in_neurons, out_neurons, neurons_per_row, _ in fc_shapes:
        q = synthetic_q(weight_rng, (out_neurons, in_neurons), WEIGHT_WIDTH)
        weight_files[name] = fc_weight_lines(q, WEIGHT_WIDTH, neurons_per_row)

    for version_index, version in enumerate(VERSIONS):
        version_dir = args.out_dir / version
        version_dir.mkdir(parents=True, exist_ok=True)
        widths = VERSIONS[version]["MEMBRANE_INT_WIDTH"]
        threshold_rng = np.random.default_rng([SEED, version_index])
        for name, lines in weight_files.items():
            write_lines(version_dir / f"{name}_weight.mem", lines)
        for name, _, out_channels, _, _, _ in conv_shapes:
            thresholds = random_thresholds(threshold_rng, out_channels, widths[name])
            write_lines(version_dir / f"{name}_threshold.mem", threshold_lines(thresholds, widths[name]))
        for name, _, out_neurons, neurons_per_row, fires in fc_shapes:
            if fires:
                thresholds = random_thresholds(threshold_rng, out_neurons, widths[name])
                write_lines(version_dir / f"{name}_threshold.mem",
                            fc_threshold_lines(thresholds, out_neurons, widths[name], neurons_per_row))
        write_lines(version_dir / "generics.txt", generics_lines(version, conv_shapes, fc_shapes))
        print(f"{version}: {version_dir}")
    for name, in_neurons, out_neurons, neurons_per_row, _ in fc_shapes:
        n_row = -(-out_neurons // neurons_per_row)
        print(f"{name}: {in_neurons} -> {out_neurons}, n_col {neurons_per_row}, "
              f"weight {n_row * in_neurons} words x {neurons_per_row * WEIGHT_WIDTH} bits")


if __name__ == "__main__":
    main()
