"""產生 tb_fc_weight_lookup.sv 用的參考答案跟權重檔。

每個位址 y*n_in + src 一行,答案是第 y 列 n_col 顆神經元的 q[y*n_col + x, src],最後一列空的位置是 0。
答案直接從 q 算,不經過權重檔的打包,所以也驗證了匯出格式跟 RTL 的切法一致。
- 訓練端的 FC 層:q 從繞回版量化資料夾(quant_versions.txt 的 wrap)的 model.npz 讀。
  n_col 跟匯出時相同(EXPORTED_FC_COLS)的參數組,寫的權重檔要跟 SaltNET.srcs/sources_1/mem/ 裡匯出的
  out_weight.mem 相同,不同就報錯;其他 n_col 的權重檔只寫在這裡。
- 人工參數組:隨機產生 q,前兩個碼固定成 b 位元二補數的上下界。
權重檔都用訓練端 salt_core.fpga_export.fc_weight_lines 寫,跟答案放在同一個目錄。
產生隨機 q 跟 conv 共用 scripts/conv/gen_weight_lookup_ref.py 的 synthetic_q。

答案檔一行一個位址,y、src 由外到內窮舉,欄位以空白分隔:
    y src weight_0 weight_1 ... weight_{n_col-1}

用法(WSL,conda 環境 jax,在 scripts/fc 目錄執行):
    python gen_fc_weight_lookup_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.srcs/sim_1/new/fc/ref
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "conv"))
from gen_weight_lookup_ref import synthetic_q, write_lines  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))   # scripts/:quant_versions.py
from quant_versions import QUANT_RUN_DIR, WRAP_VERSION  # noqa: E402

# 訓練端 FC 層的 q 從繞回版的量化資料夾讀(quant_versions.txt;權重跟暫存器寬度無關,飽和版的 out 層可能是
# 不同的量化方式,不拿來比)。匯出的 SaltNET.srcs/sources_1/mem/<量化資料夾>/out_weight.mem 是
# n_col = EXPORTED_FC_COLS 打包的
FC_QUANT_VERSION = WRAP_VERSION
EXPORTED_FC_COLS = 4
MEM_DIR = Path(__file__).resolve().parents[2] / "SaltNET.srcs" / "sources_1" / "mem"

# 參數組:(IN_NEURONS, OUT_NEURONS, NEURONS_PER_ROW, WEIGHT_WIDTH),跟 run_tb_fc_weight_lookup.tcl 的清單一致;
# READ_LATENCY 不影響答案,在 run_tb_fc_weight_lookup.tcl 另外組

# 訓練端的 FC 層:(層名, 參數組);n_col 還沒選定,先用 4
TRAINED_LAYERS = [
    ("out", (1296, 10, 4, 7)),
]

SYNTHETIC_SETS = [
    (7, 5, 1, 7),     # n_col = 1:一個位址一個碼
    (7, 10, 3, 9),    # n_col = 3 不是 2 的次方;最後一列只有 1 顆,補 2 格 0;寬字 27 bits 不是 4 的倍數
    (5, 3, 4, 4),     # n_col > n_out:只有一列,補 1 格 0
    (1, 1, 1, 4),     # n_in = n_out = n_col = 1:深度 1,位寬下限保護
]

SYNTHETIC_SEED = 0


def ref_file_stem(in_neurons: int, out_neurons: int, neurons_per_row: int, weight_width: int) -> str:
    """答案檔、權重檔共用的檔名主體,testbench 跟 run_tb_fc_weight_lookup.tcl 用同一套規則組出檔名。"""
    return f"fc_weight_lookup_IN{in_neurons}_OUT{out_neurons}_COL{neurons_per_row}_B{weight_width}"


def reference_rows(q: np.ndarray, neurons_per_row: int) -> list[str]:
    """q (n_out, n_in) -> 答案檔每一行,第 y*n_in + src 行是位址 y*n_in + src。"""
    out_neurons, in_neurons = q.shape
    row_count = -(-out_neurons // neurons_per_row)
    rows = []
    for row in range(row_count):
        for source in range(in_neurons):
            fields = [row, source]
            for column in range(neurons_per_row):
                neuron = row * neurons_per_row + column
                fields.append(int(q[neuron, source]) if neuron < out_neurons else 0)
            rows.append(" ".join(str(value) for value in fields))
    return rows


def trained_fc_q(load_quantized, training_repo: Path, layer_name: str, shape: tuple[int, ...]) -> np.ndarray:
    """FC_QUANT_VERSION 裡這層的 q,確認形狀對後回傳。"""
    model = load_quantized(training_repo / QUANT_RUN_DIR / FC_QUANT_VERSION / "model.npz")
    layer_index = [layer.name for layer in model.network.layers].index(layer_name)
    q = np.asarray(model.params[layer_index].q)
    if q.shape != shape:
        raise RuntimeError(f"{FC_QUANT_VERSION} 的 {layer_name} q 形狀 {q.shape},參數組要 {shape}")
    return q


def check_exported_weight(layer_name: str, params: tuple[int, ...], q: np.ndarray, fc_weight_lines) -> None:
    """n_col 跟匯出時相同的參數組:寫的權重檔要跟 sources_1/mem 裡匯出的 <層名>_weight.mem 相同。"""
    _, _, neurons_per_row, weight_width = params
    if neurons_per_row != EXPORTED_FC_COLS:
        return
    exported_path = MEM_DIR / FC_QUANT_VERSION / f"{layer_name}_weight.mem"
    if exported_path.read_text(encoding="ascii").split() != fc_weight_lines(q, weight_width, neurons_per_row):
        raise RuntimeError(f"{exported_path} 的內容跟 model.npz 匯出的不同")
    print(f"{layer_name}: 權重檔跟 {exported_path.name}({FC_QUANT_VERSION})相同")


def write_reference(out_dir: Path, params: tuple[int, ...], q: np.ndarray, fc_weight_lines) -> Path:
    """一組參數的答案檔、權重檔寫進 out_dir,回傳答案檔路徑。"""
    _, _, neurons_per_row, weight_width = params
    stem = ref_file_stem(*params)
    ref_path = out_dir / f"{stem}.txt"
    write_lines(ref_path, reference_rows(q, neurons_per_row))
    write_lines(out_dir / f"{stem}_weight.mem", fc_weight_lines(q, weight_width, neurons_per_row))
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
    from salt_core.fpga_export import fc_weight_lines
    from salt_core.io import load_quantized

    all_sets = [params for _, params in TRAINED_LAYERS] + SYNTHETIC_SETS
    stems = [ref_file_stem(*params) for params in all_sets]
    if len(set(stems)) != len(stems):
        raise RuntimeError(f"參數組的檔名重複:{stems}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for layer_name, params in TRAINED_LAYERS:
        in_neurons, out_neurons, _, _ = params
        q = trained_fc_q(load_quantized, training_repo, layer_name, (out_neurons, in_neurons))
        check_exported_weight(layer_name, params, q, fc_weight_lines)
        ref_path = write_reference(args.out_dir, params, q, fc_weight_lines)
        print(f"{ref_path.name}: {layer_name}")

    rng = np.random.default_rng(SYNTHETIC_SEED)
    for params in SYNTHETIC_SETS:
        in_neurons, out_neurons, _, weight_width = params
        q = synthetic_q(rng, (out_neurons, in_neurons), weight_width)
        ref_path = write_reference(args.out_dir, params, q, fc_weight_lines)
        print(f"{ref_path.name}: 人工參數")


if __name__ == "__main__":
    main()
