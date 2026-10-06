"""產生 tb_weight_lookup.sv 用的參考答案,人工參數組另外產生權重檔。

每組 (o_c, c)、每個事件座標 (y, x),用訓練端的候選規則算出每個 bank 的 valid 跟 (k_y, k_x),
答案是 q[o_c, c, k_y, k_x]。候選規則用 gen_candidate_grid_ref.py 的 axis_candidate_lists
(訓練端 salt_core.connectivity.conv._axis_candidates),bank 是 (o_y mod M, o_x mod M)。
- 訓練端的 conv 層:q 從量化資料夾的 model.npz 讀。繞回版、飽和版的 q 要相同(兩版只差暫存器寬度),
  不同就報錯。權重檔用 SaltConv.srcs/sources_1/mem/<量化資料夾>/<層名>_weight.mem(訓練端
  tools/export_fpga.py 匯出的),這裡不產生。
- 人工參數組:隨機產生 q,前兩個碼固定成 b 位元二補數的上下界,用訓練端
  salt_core.fpga_export.conv_weight_lines 寫成權重檔,跟答案放在同一個目錄。

答案檔一行一組 (o_c, c, y, x),o_c、c、in_y、in_x 由外到內窮舉,欄位以空白分隔:
    out_channel in_channel in_y in_x  [bank (0,0)] [bank (0,1)] ... [bank (M-1,M-1)]
每個 bank 四個欄位:valid tap_y tap_x weight,bank 依 (r_y, r_x) row-major 排列。
沒有候選的 bank 寫 valid=0,其餘欄位填 0,testbench 比對時不看。

用法(WSL,conda 環境 jax,在 scripts 目錄執行,要 import 同目錄的 gen_candidate_grid_ref.py):
    python gen_weight_lookup_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltConv/SaltConv.srcs/sim_1/new/ref
"""
import argparse
import sys
from pathlib import Path

import numpy as np

from gen_candidate_grid_ref import axis_candidate_lists

QUANT_RUN_DIR = Path("experiments/scale_10k_20260919_050446/quant")
QUANT_VERSIONS = [
    "best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1",
    "best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11",
]

# 參數組:(KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, IN_CHANNELS, OUT_CHANNELS, Y_WIDTH, X_WIDTH,
#          WEIGHT_WIDTH),跟 run_tb_weight_lookup.tcl 的清單一致

# 訓練端的 conv 層:(層名, 參數組),幾何跟 gen_candidate_grid_ref.py 的 conv1、conv2 相同
TRAINED_LAYERS = [
    ("conv1", (3, 2, 1, 17, 17, 2, 8, 6, 6, 7)),
    ("conv2", (3, 2, 1, 9, 9, 8, 16, 5, 5, 7)),
]

SYNTHETIC_SETS = [
    (3, 1, 1, 7, 5, 3, 5, 3, 3, 7),    # M=3;IN_CHANNELS、OUT_CHANNELS 都不是 2 的次方
    (5, 2, 2, 5, 4, 5, 3, 4, 3, 6),    # K=5、M=3;寬字 150 bits 不是 4 的倍數
    (4, 3, 0, 3, 3, 3, 2, 4, 4, 5),    # K=4、M=2;寬字 80 bits
    (7, 3, 3, 4, 3, 2, 3, 4, 4, 9),    # K=7、M=3;寬字 441 bits
    (1, 2, 0, 2, 2, 1, 1, 2, 2, 4),    # K=1、M=1、IN_CHANNELS=OUT_CHANNELS=1:位寬下限保護
]

SYNTHETIC_SEED = 0
FIELDS_PER_BANK = 4


def ref_file_stem(kernel_size: int, stride: int, padding: int, out_rows: int, out_cols: int,
                  in_channels: int, out_channels: int, y_width: int, x_width: int,
                  weight_width: int) -> str:
    """答案檔、人工權重檔共用的檔名主體,testbench 跟 run_tb_weight_lookup.tcl 用同一套規則組出檔名。"""
    return (f"weight_lookup_K{kernel_size}_S{stride}_P{padding}_R{out_rows}_C{out_cols}"
            f"_IC{in_channels}_OC{out_channels}_Y{y_width}_X{x_width}_B{weight_width}")


def event_banks(kernel_size: int, stride: int, padding: int, out_rows: int, out_cols: int,
                y_width: int, x_width: int) -> list[list[list[tuple[int, int] | None]]]:
    """每個事件座標 (y, x) 每個 bank 的 (k_y, k_x),沒有候選的 bank 是 None。

    回傳 banks[in_y * 2^x_width + in_x][r_y][r_x]。
    """
    from salt_core.connectivity.conv import _axis_candidates

    bank_count = (kernel_size + stride - 1) // stride
    candidate_count = (kernel_size - 1) // stride + 1   # 訓練端的寫法,跟 ceil(K/S) 相同
    if candidate_count != bank_count:
        raise RuntimeError(f"候選數 {candidate_count} 跟 bank 數 {bank_count} 不一致")
    row_candidates = axis_candidate_lists(_axis_candidates, y_width, kernel_size, stride, padding,
                                          candidate_count, out_rows)
    col_candidates = axis_candidate_lists(_axis_candidates, x_width, kernel_size, stride, padding,
                                          candidate_count, out_cols)

    all_banks = []
    for in_y, y_candidates in enumerate(row_candidates):
        for in_x, x_candidates in enumerate(col_candidates):
            banks = [[None] * bank_count for _ in range(bank_count)]
            # 兩軸都合法才是候選,跟 build_conv_structure 的 valid_y & valid_x 相同
            for out_y, tap_y in y_candidates:
                for out_x, tap_x in x_candidates:
                    row_bank = out_y % bank_count
                    col_bank = out_x % bank_count
                    if banks[row_bank][col_bank] is not None:
                        raise RuntimeError(f"in_y={in_y} in_x={in_x} 有兩個候選落在 "
                                           f"bank ({row_bank},{col_bank})")
                    banks[row_bank][col_bank] = (tap_y, tap_x)
            all_banks.append(banks)
    return all_banks


def reference_rows(q: np.ndarray, all_banks: list, y_width: int, x_width: int) -> list[str]:
    """q (OC, C, K, K) 跟 event_banks 的結果 -> 答案檔每一行。"""
    out_channels, in_channels = q.shape[:2]
    rows = []
    for out_channel in range(out_channels):
        for in_channel in range(in_channels):
            for in_y in range(2 ** y_width):
                for in_x in range(2 ** x_width):
                    fields = [out_channel, in_channel, in_y, in_x]
                    for bank_row in all_banks[in_y * 2 ** x_width + in_x]:
                        for taps in bank_row:
                            if taps is None:
                                fields.extend([0] * FIELDS_PER_BANK)
                            else:
                                tap_y, tap_x = taps
                                fields.extend([1, tap_y, tap_x, int(q[out_channel, in_channel, tap_y, tap_x])])
                    rows.append(" ".join(str(value) for value in fields))
    return rows


def trained_q(load_quantized, training_repo: Path, layer_name: str, shape: tuple[int, ...]) -> np.ndarray:
    """兩個量化資料夾裡這層的 q,確認形狀對、兩版相同後回傳。"""
    versions_q = []
    for version in QUANT_VERSIONS:
        model = load_quantized(training_repo / QUANT_RUN_DIR / version / "model.npz")
        layer_index = [layer.name for layer in model.network.layers].index(layer_name)
        q = np.asarray(model.params[layer_index].q)
        if q.shape != shape:
            raise RuntimeError(f"{version} 的 {layer_name} q 形狀 {q.shape},參數組要 {shape}")
        versions_q.append(q)
    for version, q in zip(QUANT_VERSIONS[1:], versions_q[1:]):
        if not np.array_equal(q, versions_q[0]):
            raise RuntimeError(f"{layer_name} 的 q 在 {QUANT_VERSIONS[0]} 跟 {version} 不同")
    return versions_q[0]


def synthetic_q(rng: np.random.Generator, shape: tuple[int, ...], weight_width: int) -> np.ndarray:
    """隨機權重碼,涵蓋 b 位元二補數全範圍,前兩個碼固定成下界、上界。"""
    low, high = -(1 << (weight_width - 1)), (1 << (weight_width - 1)) - 1
    q = rng.integers(low, high + 1, size=shape)
    flat = q.reshape(-1)
    flat[0] = low
    if flat.size > 1:
        flat[1] = high
    return q


def write_lines(path: Path, lines: list[str]) -> None:
    path.write_text("".join(f"{line}\n" for line in lines), encoding="ascii")


def write_reference(out_dir: Path, params: tuple[int, ...], q: np.ndarray) -> Path:
    """一組參數的答案檔寫進 out_dir,回傳路徑。"""
    kernel_size, stride, padding, out_rows, out_cols, _, _, y_width, x_width, _ = params
    all_banks = event_banks(kernel_size, stride, padding, out_rows, out_cols, y_width, x_width)
    ref_path = out_dir / f"{ref_file_stem(*params)}.txt"
    write_lines(ref_path, reference_rows(q, all_banks, y_width, x_width))
    return ref_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path,
                        help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--out-dir", required=True, type=Path, help="參考答案輸出目錄")
    args = parser.parse_args()

    # 運算量很小,固定用 CPU,不去佔 GPU 記憶體(GPU 可能正在跑訓練)
    import jax
    jax.config.update("jax_platforms", "cpu")

    training_repo = args.training_repo.resolve()
    sys.path.insert(0, str(training_repo))
    from salt_core.fpga_export import conv_weight_lines
    from salt_core.io import load_quantized

    all_sets = [params for _, params in TRAINED_LAYERS] + SYNTHETIC_SETS
    stems = [ref_file_stem(*params) for params in all_sets]
    if len(set(stems)) != len(stems):
        raise RuntimeError(f"參數組的檔名重複:{stems}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for layer_name, params in TRAINED_LAYERS:
        kernel_size, _, _, _, _, in_channels, out_channels, _, _, _ = params
        q = trained_q(load_quantized, training_repo, layer_name,
                      (out_channels, in_channels, kernel_size, kernel_size))
        ref_path = write_reference(args.out_dir, params, q)
        print(f"{ref_path.name}: {layer_name}")

    rng = np.random.default_rng(SYNTHETIC_SEED)
    for params in SYNTHETIC_SETS:
        kernel_size, _, _, _, _, in_channels, out_channels, _, _, weight_width = params
        q = synthetic_q(rng, (out_channels, in_channels, kernel_size, kernel_size), weight_width)
        ref_path = write_reference(args.out_dir, params, q)
        write_lines(args.out_dir / f"{ref_file_stem(*params)}_weight.mem", conv_weight_lines(q, weight_width))
        print(f"{ref_path.name}: 人工參數")


if __name__ == "__main__":
    main()
