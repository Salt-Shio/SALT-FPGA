"""產生 tb_conv_to_fc_adapter_*.sv 用的參考答案。

ConvToFCAdapter 把 conv 送出的座標 (o_x, o_y, o_c, t) 換成 FC 收的攤平編號 (src, t)。
答案用訓練端 salt_core.connectivity.conv.unravel_conv_source 產生:它把 src 拆回 (x, y, c),
conv 層讀輸入事件就是用它,也就是訓練端攤平順序的定義。每組參數把 0 ~ n_in-1 每個 src 各放兩次、順序打亂,
拆成座標當輸入,預期輸出就是 src;另外用 numpy 的 ravel_multi_index 把座標攤平回去,跟 src 相同才寫檔。
t 不遞減、可以重複,第一筆 0、最後一筆 2^TIME_WIDTH-1(轉接模組只原樣傳過去)。

參數組 (IN_CHANNELS, IN_ROWS, IN_COLS),TIME_WIDTH 都是 16:
- 訓練端 conv2 的輸出形狀(16, 9, 9)。量化資料夾照 quant_versions.txt,繞回、飽和兩版的 conv2 輸出形狀、
  out 層的 n_in 都要跟它相同。
- 人工參數:不是 2 的次方、列數跟行數不同;都是 2 的次方;只有一個 channel;只有一列;只有一行;全部是 1。

答案檔一行一筆,第一個欄位是種類,欄位以空白分隔,全部十進位:
    event <o_x> <o_y> <o_c> <t> <src>   × event_count,照送進去的順序
    end <event_count>

用法(WSL,conda 環境 jax,在 scripts/fc 目錄執行):
    python gen_conv_to_fc_adapter_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.srcs/sim_1/new/fc/ref
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "conv"))
from gen_weight_lookup_ref import write_lines  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))   # scripts/:quant_versions.py
from quant_versions import QUANT_RUN_DIR, SATURATE_VERSION, WRAP_VERSION  # noqa: E402  量化資料夾,換權重改 quant_versions.txt

TIME_WIDTH = 16
TRAINED_SHAPE = (16, 9, 9)
# 參數組:(IN_CHANNELS, IN_ROWS, IN_COLS),跟 run_tb_conv_to_fc_adapter.tcl 的清單一致
PARAM_SETS = [
    TRAINED_SHAPE,   # 訓練端 conv2 的輸出形狀,n_in = 1296
    (3, 5, 7),       # 都不是 2 的次方,列數跟行數不同(列、行乘錯會被抓到)
    (4, 4, 8),       # 都是 2 的次方:src 就是三個座標的位元接起來
    (1, 9, 9),       # 只有一個 channel,channel 位寬 1
    (5, 1, 6),       # 只有一列
    (6, 5, 1),       # 只有一行
    (1, 1, 1),       # 全部是 1,src 一定是 0
]
SEED = 0
REPEAT_PER_SOURCE = 2   # 每個 src 送幾次


def ref_file_stem(in_channels: int, in_rows: int, in_cols: int) -> str:
    """答案檔的檔名主體,testbench 跟 run_tb_conv_to_fc_adapter.tcl 用同一套規則組出檔名。"""
    return f"conv_to_fc_adapter_C{in_channels}_H{in_rows}_W{in_cols}_T{TIME_WIDTH}"


def check_trained_shape(training_repo: Path, load_quantized) -> None:
    """繞回、飽和兩版的 conv2(倒數第二層)輸出形狀、out 層的 n_in 要跟 TRAINED_SHAPE 相同。"""
    for version in (WRAP_VERSION, SATURATE_VERSION):
        model_file = load_quantized(training_repo / QUANT_RUN_DIR / version / "model.npz")
        conv_layer, fc_layer = model_file.network.layers[-2:]
        shape = (conv_layer.oc, conv_layer.h_out, conv_layer.w_out)
        if shape != TRAINED_SHAPE:
            raise RuntimeError(f"{version} 的 {conv_layer.name} 輸出形狀是 {shape},不是 {TRAINED_SHAPE}")
        if fc_layer.n_in != int(np.prod(TRAINED_SHAPE)):
            raise RuntimeError(f"{version} 的 {fc_layer.name} n_in 是 {fc_layer.n_in},跟 {conv_layer.name} 輸出不同")
        print(f"{version}:{conv_layer.name} 輸出 {shape}、{fc_layer.name} n_in {fc_layer.n_in}")


def reference_lines(rng: np.random.Generator, shape: tuple[int, int, int], unravel_conv_source) -> list[str]:
    in_channels, in_rows, in_cols = shape
    in_neurons = in_channels * in_rows * in_cols
    sources = rng.permutation(np.repeat(np.arange(in_neurons), REPEAT_PER_SOURCE))
    x, y, c = (np.asarray(part).astype(np.int64) for part in unravel_conv_source(sources, in_rows, in_cols))
    if not np.array_equal(np.ravel_multi_index((c, y, x), shape), sources):
        raise RuntimeError(f"{shape}:unravel_conv_source 拆出的座標攤平回去跟 src 不同")
    if x.max() >= in_cols or y.max() >= in_rows or c.max() >= in_channels:
        raise RuntimeError(f"{shape}:拆出的座標超出範圍")

    event_count = len(sources)
    times = np.sort(rng.integers(0, 1 << TIME_WIDTH, size=event_count))
    times[0] = 0
    times[-1] = (1 << TIME_WIDTH) - 1
    lines = [f"event {x[i]} {y[i]} {c[i]} {times[i]} {sources[i]}" for i in range(event_count)]
    return lines + [f"end {event_count}"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path,
                        help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--out-dir", required=True, type=Path, help="參考答案輸出目錄")
    args = parser.parse_args()

    # 運算量不大,固定用 CPU,不去佔 GPU 記憶體(GPU 可能正在跑訓練)
    import jax
    jax.config.update("jax_platforms", "cpu")
    import jax.numpy as jnp
    sys.path.insert(0, str(args.training_repo.resolve()))
    from salt_core.connectivity.conv import unravel_conv_source
    from salt_core.io import load_quantized

    check_trained_shape(args.training_repo, load_quantized)

    stems = [ref_file_stem(*shape) for shape in PARAM_SETS]
    if len(set(stems)) != len(stems):
        raise RuntimeError(f"參數組的檔名重複:{stems}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    for shape in PARAM_SETS:
        lines = reference_lines(rng, shape,
                                lambda source, rows, cols: unravel_conv_source(jnp.asarray(source), rows, cols))
        ref_path = args.out_dir / f"{ref_file_stem(*shape)}.txt"
        write_lines(ref_path, lines)
        print(f"{ref_path.name}:{len(lines) - 1} 筆")


if __name__ == "__main__":
    main()
