"""產生 tb_neuron_update.sv 用的參考答案,人工參數組另外產生衰減表檔。

答案用訓練端逐事件整數更新的函式算(Conv.md 第 3 節 ①~④ 的同一條算式):
    salt_core.quant.codes.apply_decay_table_int:Δt 查衰減表,Δt=0 不衰減、Δt 超過表深度 A=0
    salt_core.quant.scan.process_event:D = r(A·V̂)、U = D + (q << f_V)、fit_w、比門檻、fire 歸零
Δt 只取 event_time >= last_time(時間戳記繞回還沒定,不測)。

參數組分兩種:
- 訓練端的 conv 層:繞回版、飽和版各兩層,(b, i_V, f_V, f_a, 衰減表) 從量化資料夾的 model.npz 讀,
  衰減表檔用 SaltConv.srcs/sources_1/mem/<量化資料夾>/<層名>_decay.mem(訓練端 tools/export_fpga.py 匯出的),
  這裡不產生,但會確認它的內容跟 model.npz 相同。門檻除了隨機值,也用這層實際的逐 channel 門檻。
- 人工參數組:隨機衰減表,第一格固定成 2^f_a - 1,深度至少 3 時第二格固定成 0;
  最後一格(Δt = Δt_max)不是 0,跟超過表深度的 A=0 才分得出來;
  用訓練端 salt_core.fpga_export.decay_lines 寫成衰減表檔,跟答案放在同一個目錄。
每一組參數都跑 ROUND × SATURATE 四種組合,衰減表檔四種共用。

向量分三種:
- 窮舉(EXHAUSTIVE):V̂、q、門檻窮舉 w、b 位元全範圍,(t_last, t) 窮舉所有 t >= t_last 的組合。
- 半窮舉(SEMI_EXHAUSTIVE):V̂、q、Δt 窮舉,t_last 隨機;門檻每組取一個,輪流用 V̂'、V̂'+1、隨機值。
- 隨機(RANDOM):先放邊界值的所有組合,再放 RANDOM_COUNT 筆隨機值。
    邊界值:V̂ 跟 q 的上下限、0、±1;Δt 取 0、1、2、Δt_max-1、Δt_max、Δt_max+1、2^TIME_WIDTH-1;
    門檻取 V̂'、V̂'+1(剛好 fire、剛好不 fire)跟範圍上下限。
V̂' 是溢位處理之後、比門檻之前的值,用 process_event 不給門檻算。

答案檔一行一個向量,欄位以空白分隔,全部十進位,有號數直接寫負號:
    vector <weight_code> <membrane> <last_time> <event_time> <threshold> <spike> <new_membrane>
最後一行:
    end <vector_count>

用法(WSL,conda 環境 jax,在 scripts 目錄執行):
    python gen_neuron_update_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltConv/SaltConv.srcs/sim_1/new/ref
"""
import argparse
import itertools
import sys
from pathlib import Path

import numpy as np

QUANT_RUN_DIR = Path("experiments/scale_10k_20260919_050446/quant")
# (量化資料夾, 層名):衰減表檔在 SaltConv.srcs/sources_1/mem/<量化資料夾>/<層名>_decay.mem
TRAINED_LAYERS = [
    ("best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1", "conv1"),
    ("best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1", "conv2"),
    ("best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11", "conv1"),
    ("best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11", "conv2"),
]
TRAINED_TIME_WIDTH = 16
TRAINED_WEIGHT_WIDTH = 7

EXHAUSTIVE = "exhaustive"
SEMI_EXHAUSTIVE = "semi_exhaustive"
RANDOM = "random"

# 人工參數組:(WEIGHT_WIDTH, MEMBRANE_INT_WIDTH, MEMBRANE_FRAC_WIDTH, DECAY_FRAC_WIDTH, DECAY_TABLE_DEPTH,
#             TIME_WIDTH, 向量種類),跟 run_tb_neuron_update.tcl 的清單一致
SYNTHETIC_SETS = [
    (3, 4, 0, 3, 2, 2, EXHAUSTIVE),         # 全部窮舉;Δt 0~3 涵蓋不衰減、查表、超過表深度
    (2, 2, 0, 1, 1, 2, EXHAUSTIVE),         # 位寬下限:b=2、w=2、f_a=1、表深度 1
    (4, 3, 2, 4, 5, 3, SEMI_EXHAUSTIVE),    # f_V=2;q << f_V 比 w 寬(b+f_V=6 > w=5)
    (9, 18, 3, 12, 40, 20, RANDOM),         # 寬的一組:w=21、f_a=12,乘積 33 bits
]

SEED = 0
RANDOM_COUNT = 20000
EXHAUSTIVE_LIMIT = 100000   # 窮舉向量數上限,超過就是參數組選錯了


def stem(weight_width: int, membrane_int_width: int, membrane_frac_width: int, decay_frac_width: int,
         decay_table_depth: int, time_width: int) -> str:
    """答案檔、人工衰減表檔共用的檔名主體,testbench 跟 run_tb_neuron_update.tcl 用同一套規則組出檔名。"""
    return (f"neuron_update_B{weight_width}_IV{membrane_int_width}_FV{membrane_frac_width}"
            f"_FA{decay_frac_width}_D{decay_table_depth}_T{time_width}")


def ref_file_name(base: str, round_enabled: int, saturate_enabled: int) -> str:
    return f"{base}_R{round_enabled}_S{saturate_enabled}.txt"


def signed_range(width: int) -> tuple[int, int]:
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


class NeuronModel:
    """一組量化參數加上捨入、溢位模式,用訓練端的函式算一批向量。"""

    def __init__(self, training_fns: dict, decay_table: np.ndarray, membrane_int_width: int,
                 membrane_frac_width: int, decay_frac_width: int, round_mode: str, overflow_mode: str):
        self.fns = training_fns
        self.decay_table = np.asarray(decay_table, dtype=np.int32)
        self.kwargs = dict(f_a=decay_frac_width, f_V=membrane_frac_width, i_V=membrane_int_width,
                           round_mode=round_mode, overflow_mode=overflow_mode)

    def _decay(self, last_time: np.ndarray, event_time: np.ndarray):
        delta_time = (event_time - last_time).astype(np.float32)
        if np.any(delta_time < 0):
            raise RuntimeError("Δt 有負值,event_time 要 >= last_time")
        return self.fns["apply_decay_table_int"](delta_time, self.decay_table)

    def fitted(self, weight_code, membrane, last_time, event_time) -> np.ndarray:
        """溢位處理之後、比門檻之前的 V̂'。"""
        decay_code, is_same_time = self._decay(last_time, event_time)
        result = self.fns["process_event"](membrane, decay_code, is_same_time, weight_code, None, **self.kwargs)
        return np.asarray(result.v_final)

    def update(self, weight_code, membrane, last_time, event_time, threshold) -> tuple[np.ndarray, np.ndarray]:
        """(spike, new_membrane)。"""
        decay_code, is_same_time = self._decay(last_time, event_time)
        result = self.fns["process_event"](membrane, decay_code, is_same_time, weight_code, threshold,
                                           **self.kwargs)
        return np.asarray(result.is_spiked).astype(np.int64), np.asarray(result.v_final)


def random_last_times(rng: np.random.Generator, delta_time: np.ndarray, time_width: int) -> np.ndarray:
    """每個 Δt 配一個 t_last,讓 t = t_last + Δt 還在 TIME_WIDTH 位元裡。"""
    time_max = (1 << time_width) - 1
    return np.array([int(rng.integers(0, time_max - dt + 1)) for dt in delta_time], dtype=np.int64)


def exhaustive_vectors(weight_width: int, membrane_width: int, time_width: int) -> tuple[np.ndarray, ...]:
    weight_low, weight_high = signed_range(weight_width)
    membrane_low, membrane_high = signed_range(membrane_width)
    time_pairs = [(last, now) for last in range(1 << time_width) for now in range(last, 1 << time_width)]
    rows = [(weight, membrane, last, now, threshold)
            for weight in range(weight_low, weight_high + 1)
            for membrane in range(membrane_low, membrane_high + 1)
            for last, now in time_pairs
            for threshold in range(membrane_low, membrane_high + 1)]
    if len(rows) > EXHAUSTIVE_LIMIT:
        raise RuntimeError(f"窮舉 {len(rows)} 筆,超過上限 {EXHAUSTIVE_LIMIT}")
    return tuple(np.array(column, dtype=np.int64) for column in zip(*rows))


def threshold_candidates(fitted: np.ndarray, membrane_width: int) -> list[np.ndarray]:
    """剛好 fire(門檻 = V̂')、剛好不 fire(門檻 = V̂'+1,V̂' 是上限時沒有這種)。"""
    _, membrane_high = signed_range(membrane_width)
    return [fitted, np.minimum(fitted + 1, membrane_high)]


def semi_exhaustive_vectors(model: NeuronModel, rng: np.random.Generator, weight_width: int, membrane_width: int,
                            time_width: int) -> tuple[np.ndarray, ...]:
    weight_low, weight_high = signed_range(weight_width)
    membrane_low, membrane_high = signed_range(membrane_width)
    rows = list(itertools.product(range(weight_low, weight_high + 1), range(membrane_low, membrane_high + 1),
                                  range(1 << time_width)))
    weight, membrane, delta_time = (np.array(column, dtype=np.int64) for column in zip(*rows))
    last_time = random_last_times(rng, delta_time, time_width)
    event_time = last_time + delta_time
    fitted = model.fitted(weight, membrane, last_time, event_time)
    exact, above = threshold_candidates(fitted, membrane_width)
    random_threshold = rng.integers(membrane_low, membrane_high + 1, size=len(rows))
    threshold = np.choose(np.arange(len(rows)) % 3, [exact, above, random_threshold])
    return weight, membrane, last_time, event_time, threshold


def random_vectors(model: NeuronModel, rng: np.random.Generator, weight_width: int, membrane_width: int,
                   decay_table_depth: int, time_width: int,
                   channel_thresholds: np.ndarray | None) -> tuple[np.ndarray, ...]:
    weight_low, weight_high = signed_range(weight_width)
    membrane_low, membrane_high = signed_range(membrane_width)
    time_max = (1 << time_width) - 1

    # 邊界值的所有組合
    edge_weights = sorted({weight_low, weight_low + 1, -1, 0, 1, weight_high - 1, weight_high})
    edge_membranes = sorted({membrane_low, membrane_low + 1, -2, -1, 0, 1, 2, membrane_high - 1, membrane_high})
    edge_deltas = sorted(dt for dt in {0, 1, 2, decay_table_depth - 1, decay_table_depth, decay_table_depth + 1,
                                       time_max} if 0 <= dt <= time_max)
    edge_rows = list(itertools.product(edge_weights, edge_membranes, edge_deltas))
    edge_weight, edge_membrane, edge_delta = (np.array(column, dtype=np.int64) for column in zip(*edge_rows))

    # 隨機值:Δt 一半落在表的範圍附近,一半在整個 TIME_WIDTH 範圍
    random_weight = rng.integers(weight_low, weight_high + 1, size=RANDOM_COUNT)
    random_membrane = rng.integers(membrane_low, membrane_high + 1, size=RANDOM_COUNT)
    near_table = rng.integers(0, min(decay_table_depth + 2, time_max + 1), size=RANDOM_COUNT)
    anywhere = rng.integers(0, time_max + 1, size=RANDOM_COUNT)
    random_delta = np.where(rng.random(RANDOM_COUNT) < 0.5, near_table, anywhere)

    weight = np.concatenate([edge_weight, random_weight])
    membrane = np.concatenate([edge_membrane, random_membrane])
    delta_time = np.concatenate([edge_delta, random_delta])
    last_time = random_last_times(rng, delta_time, time_width)
    event_time = last_time + delta_time
    fitted = model.fitted(weight, membrane, last_time, event_time)
    exact, above = threshold_candidates(fitted, membrane_width)

    edge_part = slice(0, len(edge_rows))
    random_part = slice(len(edge_rows), None)
    inputs = (weight, membrane, last_time, event_time)

    # 邊界組合每組都配四種門檻:V̂'、V̂'+1、上限、下限
    edge_count = len(edge_rows)
    edge_thresholds = [exact[edge_part], above[edge_part],
                       np.full(edge_count, membrane_high), np.full(edge_count, membrane_low)]
    edge_inputs = [np.tile(column[edge_part], len(edge_thresholds)) for column in inputs]

    # 隨機值的門檻:V̂'、V̂'+1、隨機值、這層實際的門檻(訓練端參數組才有)輪流
    random_threshold_choices = [exact[random_part], above[random_part],
                                rng.integers(membrane_low, membrane_high + 1, size=RANDOM_COUNT)]
    if channel_thresholds is not None:
        random_threshold_choices.append(rng.choice(channel_thresholds, size=RANDOM_COUNT))
    random_threshold = np.choose(np.arange(RANDOM_COUNT) % len(random_threshold_choices), random_threshold_choices)

    columns = [np.concatenate([edge_column, column[random_part]]) for edge_column, column in zip(edge_inputs, inputs)]
    columns.append(np.concatenate(edge_thresholds + [random_threshold]))
    return tuple(columns)


def reference_lines(model: NeuronModel, vectors: tuple[np.ndarray, ...]) -> list[str]:
    weight, membrane, last_time, event_time, threshold = vectors
    spike, new_membrane = model.update(weight, membrane, last_time, event_time, threshold)
    lines = [f"vector {w} {v} {last} {now} {th} {s} {v_new}"
             for w, v, last, now, th, s, v_new
             in zip(weight, membrane, last_time, event_time, threshold, spike, new_membrane)]
    return lines + [f"end {len(lines)}"]


def write_lines(path: Path, lines: list[str]) -> None:
    path.write_text("".join(f"{line}\n" for line in lines), encoding="ascii")


def read_decay_mem(path: Path) -> np.ndarray:
    return np.array([int(line, 16) for line in path.read_text(encoding="ascii").split()], dtype=np.int64)


def synthetic_decay_table(rng: np.random.Generator, decay_frac_width: int, decay_table_depth: int) -> np.ndarray:
    """隨機衰減表。最後一格(Δt = Δt_max)不是 0,查表跟「超過表深度 A=0」才分得出來。"""
    code_max = (1 << decay_frac_width) - 1
    table = rng.integers(0, code_max + 1, size=decay_table_depth)
    table[-1] = rng.integers(1, code_max + 1)
    table[0] = code_max
    if decay_table_depth >= 3:
        table[1] = 0
    return table


def write_mode_references(out_dir: Path, base: str, training_fns: dict, decay_table: np.ndarray,
                          weight_width: int, membrane_int_width: int, membrane_frac_width: int,
                          decay_frac_width: int, decay_table_depth: int, time_width: int, vector_kind: str,
                          channel_thresholds: np.ndarray | None, rng: np.random.Generator) -> None:
    """一組參數的 ROUND × SATURATE 四個答案檔。"""
    membrane_width = membrane_int_width + membrane_frac_width
    for round_enabled, saturate_enabled in itertools.product((0, 1), (0, 1)):
        model = NeuronModel(training_fns, decay_table, membrane_int_width, membrane_frac_width, decay_frac_width,
                            round_mode="round" if round_enabled else "truncate",
                            overflow_mode="saturate" if saturate_enabled else "wrap")
        if vector_kind == EXHAUSTIVE:
            vectors = exhaustive_vectors(weight_width, membrane_width, time_width)
        elif vector_kind == SEMI_EXHAUSTIVE:
            vectors = semi_exhaustive_vectors(model, rng, weight_width, membrane_width, time_width)
        elif vector_kind == RANDOM:
            vectors = random_vectors(model, rng, weight_width, membrane_width, decay_table_depth, time_width,
                                     channel_thresholds)
        else:
            raise ValueError(f"不認得的向量種類 {vector_kind!r}")
        lines = reference_lines(model, vectors)
        ref_path = out_dir / ref_file_name(base, round_enabled, saturate_enabled)
        write_lines(ref_path, lines)
        print(f"{ref_path.name}: {lines[-1]}")


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
    from salt_core.fpga_export import channel_thresholds, decay_lines
    from salt_core.io import load_quantized
    from salt_core.quant.codes import apply_decay_table_int
    from salt_core.quant.scan import process_event
    training_fns = {"apply_decay_table_int": apply_decay_table_int, "process_event": process_event}

    mem_dir = Path(__file__).resolve().parent.parent / "SaltConv.srcs" / "sources_1" / "mem"
    args.out_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    bases = []

    for version, layer_name in TRAINED_LAYERS:
        model = load_quantized(training_repo / QUANT_RUN_DIR / version / "model.npz")
        layer_index = [layer.name for layer in model.network.layers].index(layer_name)
        layer = model.network.layers[layer_index]
        params = model.params[layer_index]
        decay_table = np.asarray(params.decay_table_int)
        exported = read_decay_mem(mem_dir / version / f"{layer_name}_decay.mem")
        if not np.array_equal(exported, decay_table):
            raise RuntimeError(f"{version}/{layer_name}_decay.mem 跟 model.npz 的衰減表不同")
        thresholds = np.asarray(channel_thresholds(np.asarray(params.v_th_int), layer.oc))
        base = stem(TRAINED_WEIGHT_WIDTH, params.i_V, params.f_V, params.f_a, len(decay_table), TRAINED_TIME_WIDTH)
        bases.append(base)
        print(f"{version} {layer_name}: i_V={params.i_V} f_V={params.f_V} f_a={params.f_a} "
              f"Δt_max={len(decay_table)} 門檻={thresholds.tolist()}")
        write_mode_references(args.out_dir, base, training_fns, decay_table, TRAINED_WEIGHT_WIDTH, params.i_V,
                              params.f_V, params.f_a, len(decay_table), TRAINED_TIME_WIDTH, RANDOM, thresholds, rng)

    for (weight_width, membrane_int_width, membrane_frac_width, decay_frac_width, decay_table_depth, time_width,
         vector_kind) in SYNTHETIC_SETS:
        base = stem(weight_width, membrane_int_width, membrane_frac_width, decay_frac_width, decay_table_depth,
                    time_width)
        bases.append(base)
        decay_table = synthetic_decay_table(rng, decay_frac_width, decay_table_depth)
        write_lines(args.out_dir / f"{base}_decay.mem", decay_lines(decay_table, decay_frac_width))
        write_mode_references(args.out_dir, base, training_fns, decay_table, weight_width, membrane_int_width,
                              membrane_frac_width, decay_frac_width, decay_table_depth, time_width, vector_kind,
                              None, rng)

    if len(set(bases)) != len(bases):
        raise RuntimeError(f"參數組的檔名重複:{bases}")


if __name__ == "__main__":
    main()
