"""產生 tb_fc_threshold_lookup.sv 用的參考答案跟門檻檔。

每列一行,答案是第 y 列 n_col 顆神經元的門檻 v_th[y*n_col + x],最後一列空的位置是 0。
答案直接從 v_th 算,不經過門檻檔的打包,所以也驗證了匯出格式跟 RTL 的切法一致。
訓練端實際的 FC 層(out)不 fire、沒有門檻,所以只有人工參數組:隨機產生 v_th,前兩個固定成 w 位元二補數的上下界。
門檻檔用訓練端 salt_core.fpga_export.fc_threshold_lines 寫,跟答案放在同一個目錄。
產生隨機值跟寫檔共用 scripts/conv/gen_weight_lookup_ref.py 的 synthetic_q、write_lines(synthetic_q 對任何位寬的有號碼都適用)。

答案檔一行一列,欄位以空白分隔:
    y threshold_0 threshold_1 ... threshold_{n_col-1}

用法(WSL,conda 環境 jax,在 scripts/fc 目錄執行):
    python gen_fc_threshold_lookup_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.srcs/sim_1/new/fc/ref
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "conv"))
from gen_weight_lookup_ref import synthetic_q, write_lines  # noqa: E402

# 參數組:(OUT_NEURONS, NEURONS_PER_ROW, MEMBRANE_WIDTH),跟 run_tb_fc_threshold_lookup.tcl 的清單一致;
# READ_LATENCY 不影響答案,在 run_tb_fc_threshold_lookup.tcl 另外組
SYNTHETIC_SETS = [
    (10, 4, 14),   # 訓練端 out 層的形狀(n_col 先用 4),繞回版的 w
    (10, 4, 11),   # 同上,飽和版的 w
    (10, 3, 9),    # n_col = 3 不是 2 的次方;最後一列只有 1 顆,補 2 格 0;寬字 27 bits 不是 4 的倍數
    (5, 1, 7),     # n_col = 1:一個位址一個門檻
    (3, 4, 6),     # n_col > n_out:只有一列,補 1 格 0
    (1, 1, 4),     # n_out = n_col = 1:深度 1,位寬下限保護
]

SYNTHETIC_SEED = 0


def ref_file_stem(out_neurons: int, neurons_per_row: int, membrane_width: int) -> str:
    """答案檔、門檻檔共用的檔名主體,testbench 跟 run_tb_fc_threshold_lookup.tcl 用同一套規則組出檔名。"""
    return f"fc_threshold_lookup_OUT{out_neurons}_COL{neurons_per_row}_W{membrane_width}"


def reference_rows(thresholds: np.ndarray, neurons_per_row: int) -> list[str]:
    """v_th (n_out,) -> 答案檔每一行,第 y 行是第 y 列。"""
    out_neurons = thresholds.shape[0]
    row_count = -(-out_neurons // neurons_per_row)
    rows = []
    for row in range(row_count):
        fields = [row]
        for column in range(neurons_per_row):
            neuron = row * neurons_per_row + column
            fields.append(int(thresholds[neuron]) if neuron < out_neurons else 0)
        rows.append(" ".join(str(value) for value in fields))
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path,
                        help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--out-dir", required=True, type=Path, help="參考答案輸出目錄")
    args = parser.parse_args()

    sys.path.insert(0, str(args.training_repo.resolve()))
    from salt_core.fpga_export import fc_threshold_lines

    stems = [ref_file_stem(*params) for params in SYNTHETIC_SETS]
    if len(set(stems)) != len(stems):
        raise RuntimeError(f"參數組的檔名重複:{stems}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SYNTHETIC_SEED)
    for params in SYNTHETIC_SETS:
        out_neurons, neurons_per_row, membrane_width = params
        thresholds = synthetic_q(rng, (out_neurons,), membrane_width)
        stem = ref_file_stem(*params)
        ref_path = args.out_dir / f"{stem}.txt"
        write_lines(ref_path, reference_rows(thresholds, neurons_per_row))
        write_lines(args.out_dir / f"{stem}_threshold.mem",
                    fc_threshold_lines(thresholds, out_neurons, membrane_width, neurons_per_row))
        print(f"{ref_path.name}: 人工參數")


if __name__ == "__main__":
    main()
