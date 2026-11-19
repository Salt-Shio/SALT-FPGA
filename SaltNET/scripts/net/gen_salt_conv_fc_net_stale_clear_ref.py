"""產生 tb_salt_conv_fc_net_stale_clear.sv 的參考答案:整個網路 SaltConvFCNet 開掃描(STALE_CLEAR = 1),
好幾筆 test 樣本接成一條不 reset 的長串流,時間位寬縮成 STREAM_TIME_WIDTH,讓時間戳記真的繞回
(docs/SNN/Todo「時間處理 → T3」)。

目標:時間繞回時,每一層每一次更新的 (t, V̂)、每一個 spike 照樣跟訓練端對上。
- 訓練端用完整的時間(不繞回)算,所以它的答案就是正確答案;硬體的時間只有 STREAM_TIME_WIDTH 位元,
  答案檔裡的時間都寫 mod 2^W(W = STREAM_TIME_WIDTH)。
- 沒有掃描時,隔 2^W ~ 2^W + Δt_max 才再被更新、而且電位不是 0 的神經元會算錯(Δt 繞回後算成 0~Δt_max)。
  這條串流刻意製造這種神經元,這支腳本數出兩層 conv 各有幾次這種更新,都要大於 0;
  testbench 關掉掃描(STALE_CLEAR = 0)時要 FAIL(反向測試)。

串流(一條,中間不 reset;每段接在上一段最後一筆之後 1 ms 開始):
1. test 樣本 DENSE_SAMPLES 一筆接一筆:真實的密集輸入,掃描跟事件一直交錯,時間繞回一次。
2. test 樣本 REPEATED_SAMPLE。
3. 角落一個像素 FILLER_PIXEL,每 FILLER_INTERVAL ms 一筆:讓輸入不斷(掃描要有「現在」往前走),又不碰到數字區的神經元。
4. REPEATED_SAMPLE 再一次,比第 2 段晚 REPEAT_OFFSET = 2^W + Δt_max ms:第 2 段碰過、活動時間不超過 Δt_max 的神經元,
   隔 2^W ~ 2^W + Δt_max 才又被碰到。
中間塞別的 test 樣本行不通:數字都在畫面中間,每筆樣本都會碰到同一批神經元、刷新 t_last,
沒有一顆隔得到 2^W(2026-11-19 量過,兩層都是 0 次)。

前提(StaleScan 檔頭)在這裡檢查:輸入相鄰兩筆最多隔 J ms,J < 2^W - 2^(W-1) - P(P 取兩層 conv 較大的);
FC 整層共用 t_last,過期位元在 T4 才做,所以 FC 相鄰兩筆輸入要隔不到 2^W(這條串流裡 FC 不會算錯)。

答案用訓練端的函式算,跟 gen_salt_conv_fc_net_ref.py 一樣每一層兩份互相比對(官方 forward trace、逐筆迴圈),
差別只有:輸入是上面的串流、時間不檢查 TIME_WIDTH、不跟 eval/test_outputs.npz 比(那是一筆一筆樣本的結果)。

答案檔格式同 gen_salt_conv_fc_net_ref.py(整條串流是一筆 sample),時間寫 mod 2^W;
conv1_state、conv2_state 每行最後多一欄 clear_rule,說串流結束時這格可不可以被掃描清成全 0:
    0:要跟答案相同(年紀 = 「現在」- t_last 小於門檻 2^(W-1),或電位是 0:掃描不清)
    1:跟答案相同或全 0 都可以(年紀 >= 門檻,電位不是 0:看最後一次掃到時年紀到了沒)
    2:一定要全 0(年紀 >= 門檻 + P,電位不是 0:最後 P ms 裡一定被掃過,那時年紀已經 >= 門檻)
「現在」是 conv1 最後收進的輸入事件時間,也就是串流最後一筆。年紀用完整時間算。
掃描自己寫的 0 走清除路徑,不在 conv*_write 裡;清錯、漏清會在之後那顆神經元的更新比對錯出來。

答案檔 salt_conv_fc_net_stale_clear_SAT<0|1>.txt(繞回版、飽和版,約 60 MB 一個)不進 git,跑模擬前先跑這支腳本;
FC 的權重檔、衰減表檔用 gen_salt_conv_fc_net_ref.py 寫的 n_col = 4 那份(同一個目錄)。

用法(WSL,conda 環境 jax,在 scripts/net 目錄執行):
    python gen_salt_conv_fc_net_stale_clear_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --mem-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.srcs/sources_1/mem \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.srcs/sim_1/new/net/ref
"""
import argparse
import dataclasses
import sys
from pathlib import Path

import numpy as np

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR / "conv"))
sys.path.insert(0, str(SCRIPTS_DIR / "fc"))
sys.path.insert(0, str(SCRIPTS_DIR / "net"))
sys.path.insert(0, str(SCRIPTS_DIR))   # scripts/:quant_versions.py
import gen_salt_conv_fc_net_ref as net_ref  # noqa: E402
import gen_salt_conv_ref as conv_ref  # noqa: E402
import gen_salt_fc_ref as fc_ref  # noqa: E402
from quant_versions import QUANT_RUN_DIR, SATURATE_VERSION, WRAP_VERSION  # noqa: E402

STREAM_TIME_WIDTH = 11              # W:2,048 ms 繞回,門檻 1,024;conv1 每個刻度掃一格還滿足 P <= 2^(W-1) 的最小值
SCAN_CELLS_PER_TICK = 1             # N,同 run_tb_salt_conv_fc_net.tcl 的參數組
DENSE_SAMPLES = tuple(range(1, 16))
REPEATED_SAMPLE = 0
STREAM_SAMPLE_COUNT = 16            # test 評估取樣的前幾筆(同一個 seed,前 conv_ref.SAMPLE_COUNT 筆跟其他答案相同)
FILLER_PIXEL = (0, 0, 0)            # (c, y, x)
FILLER_INTERVAL = 50                # ms


def scan_period(params: conv_ref.ParamSet) -> int:
    """這一層同一格最久隔幾 ms 才再被掃到,公式同 conv/StaleScan.sv:
    T = max(1, floor(2^(W-2) * N / BANK_DEPTH)),P = T * ceil(BANK_DEPTH / N)。"""
    bank_count = params.bank_count
    bank_depth = params.out_channels * -(-params.out_rows // bank_count) * -(-params.out_cols // bank_count)
    tick_interval = max(1, (2 ** STREAM_TIME_WIDTH // 4) * SCAN_CELLS_PER_TICK // bank_depth)
    return tick_interval * -(-bank_depth // SCAN_CELLS_PER_TICK)


def load_stream_samples(training: dict, training_repo: Path, version: str, trained_raw):
    """test 評估取樣的前 STREAM_SAMPLE_COUNT 筆(同 conv_ref.load_trained_version 的取法,多取幾筆);
    確認前 conv_ref.SAMPLE_COUNT 筆跟它取的相同。回傳每筆的 (時間, 輸入編號)。"""
    quant_dir = training_repo / QUANT_RUN_DIR / version
    model_file = training["load_quantized"](quant_dir / "model.npz")
    evaluation = training["yaml"].safe_load((quant_dir / "eval" / "test.yaml").read_text(encoding="utf-8"))
    split = training["NMNISTDataset"](training["DATASET_ROOT"],
                                      max_events=model_file.metadata["data"]["max_events"]).build_split(
        seed=evaluation["seed"], n_samples=STREAM_SAMPLE_COUNT, which="test")
    raw = training["split_input_events"](split, model_file.network.input_shape)
    times, sources, counts = (np.asarray(a) for a in (raw.event_times, raw.source_idx, raw.n_real_events))
    trained_times, trained_sources = np.asarray(trained_raw.event_times), np.asarray(trained_raw.source_idx)
    if not (np.array_equal(times[:conv_ref.SAMPLE_COUNT], trained_times)
            and np.array_equal(sources[:conv_ref.SAMPLE_COUNT], trained_sources)):
        raise RuntimeError(f"{version}:多取的樣本前 {conv_ref.SAMPLE_COUNT} 筆跟評估取樣不同")
    return [(times[i, :counts[i]].astype(np.int64), sources[i, :counts[i]].astype(np.int64))
            for i in range(STREAM_SAMPLE_COUNT)]


def build_stream(samples: list, input_shape: tuple, decay_table_depth: int) -> tuple[np.ndarray, np.ndarray]:
    """檔頭「串流」的四段,回傳 (時間, 輸入編號),時間不遞減、完整不繞回。"""
    parts_time, parts_source = [], []
    next_start = 0

    def append_sample(index: int, start: int) -> int:
        times, sources = samples[index]
        shifted = times - times[0] + start
        parts_time.append(shifted)
        parts_source.append(sources)
        return int(shifted[-1])

    for index in DENSE_SAMPLES:
        next_start = append_sample(index, next_start) + 1
    first_start = next_start
    repeated_end = append_sample(REPEATED_SAMPLE, first_start)
    repeat_start = first_start + 2 ** STREAM_TIME_WIDTH + decay_table_depth
    filler_time = np.arange(repeated_end + FILLER_INTERVAL, repeat_start, FILLER_INTERVAL, dtype=np.int64)
    channels, rows, cols = input_shape
    filler_source = np.ravel_multi_index(FILLER_PIXEL, (channels, rows, cols))
    parts_time.append(filler_time)
    parts_source.append(np.full(len(filler_time), filler_source, dtype=np.int64))
    append_sample(REPEATED_SAMPLE, repeat_start)
    return np.concatenate(parts_time), np.concatenate(parts_source)


def wrong_without_scan_count(trace, decay_table_depth: int) -> int:
    """沒有掃描就會算錯的更新次數:真實 Δt >= 2^W、Δt mod 2^W <= Δt_max、更新前電位不是 0。
    trace 每顆神經元前幾步是真事件(event_ms 有值),第一步之前電位是 0。"""
    membrane = np.asarray(trace.v_steps)
    event_ms = np.asarray(trace.event_ms)
    delta_t = event_ms[:, 1:] - event_ms[:, :-1]
    real = np.isfinite(delta_t)
    delta_t = np.where(real, delta_t, 0).astype(np.int64)
    wraps = (delta_t >= 2 ** STREAM_TIME_WIDTH) & (delta_t % 2 ** STREAM_TIME_WIDTH <= decay_table_depth)
    return int(np.sum(real & wraps & (membrane[:, :-1] != 0)))


def clear_rules(params: conv_ref.ParamSet, loop_result: dict, now: int) -> np.ndarray:
    """串流結束時每顆神經元的 clear_rule(檔頭)。now:「現在」,完整時間。"""
    threshold = 2 ** (STREAM_TIME_WIDTH - 1)
    age = now - loop_result["last_time"]
    nonzero = loop_result["membrane"] != 0
    rules = np.zeros_like(age)
    rules[nonzero & (age >= threshold)] = 1
    rules[nonzero & (age >= threshold + scan_period(params))] = 2
    return rules


def wrapped(values):
    return np.asarray(values, dtype=np.int64) % 2 ** STREAM_TIME_WIDTH


def build_reference(training: dict, training_repo: Path, mem_dir: Path, out_dir: Path, version: str) -> None:
    trained = conv_ref.load_trained_version(training, training_repo, version)
    model_file = trained["model_file"]
    layer_names = [layer.name for layer in model_file.network.layers]
    if layer_names != [*net_ref.CONV_LAYERS, fc_ref.TRAINED_LAYER]:
        raise RuntimeError(f"{version} 的層是 {layer_names},整個網路的答案要改")

    conv_models = {}
    for layer_name in net_ref.CONV_LAYERS:
        params = [p for v, name, p in conv_ref.TRAINED_SETS if v == version and name == layer_name][0]
        params = dataclasses.replace(params, time_width=STREAM_TIME_WIDTH)
        conv_models[layer_name] = conv_ref.trained_layer_model(training, model_file, version, layer_name, params,
                                                               mem_dir)
    fc_params = [p for v, p in fc_ref.TRAINED_SETS if v == version][0]
    fc_params = dataclasses.replace(fc_params, neurons_per_row=4, time_width=STREAM_TIME_WIDTH)
    fc_layer, fc_model = fc_ref.trained_layer_model(training, model_file, version, fc_params)
    fc_ref.check_exported_files(training, version, fc_params, out_dir)   # n_col = 4 的資料檔跟匯出的相同

    # 串流、前提
    samples = load_stream_samples(training, training_repo, version, trained["raw"])
    decay_table_depth = conv_models["conv1"][2].params.decay_table_depth
    in_time, in_source = build_stream(samples, model_file.network.input_shape, decay_table_depth)
    max_gap = int(np.diff(in_time).max())
    max_period = max(scan_period(model.params) for _, _, model in conv_models.values())
    gap_limit = 2 ** STREAM_TIME_WIDTH - 2 ** (STREAM_TIME_WIDTH - 1) - max_period
    if max_gap >= gap_limit:
        raise RuntimeError(f"{version}:輸入相鄰兩筆最多隔 {max_gap} ms,前提要小於 {gap_limit}")
    stream = model_file.network.input_stream(training["InputEvents"].checked(in_time, in_source, len(in_time)))

    in_events = None
    conv_results = {}
    for layer_name in net_ref.CONV_LAYERS:
        _, layer, model = conv_models[layer_name]
        params = model.params
        events = conv_ref.stream_events(stream, params.in_rows, params.in_cols)
        if in_events is None:
            in_events = events
        output = model.official_forward(stream, layer.max_queue_len, layer.max_out_spikes, trace=True)
        loop_result = model.run_events(events)
        conv_ref.check_against_official(model, events, loop_result, output)
        net_ref.check_writes_against_trace(version, layer_name, 0, params, loop_result["writes"], output.trace)
        wrong_count = wrong_without_scan_count(output.trace, params.decay_table_depth)
        if wrong_count == 0:
            raise RuntimeError(f"{version} {layer_name}:沒有掃描也不會算錯的串流,反向測試抓不到東西")
        print(f"{version} {layer_name}:沒有掃描就會算錯的更新 {wrong_count} 次,P = {scan_period(params)} ms")
        conv_results[layer_name] = (params, loop_result)
        stream = output.stream

    fc_events = fc_ref.stream_events(stream)
    fc_max_gap = int(np.diff(fc_events[:, 1]).max())
    if fc_max_gap >= 2 ** STREAM_TIME_WIDTH:
        raise RuntimeError(f"{version}:FC 相鄰兩筆輸入隔 {fc_max_gap} ms,沒有過期位元(T4)會算錯")
    conv2_params, conv2_result = conv_results["conv2"]
    flattened = np.array([oc * conv2_params.out_rows * conv2_params.out_cols + oy * conv2_params.out_cols + ox
                          for oc, oy, ox, _ in conv2_result["outputs"]], dtype=np.int64)
    if not np.array_equal(flattened, fc_events[:, 0]):
        raise RuntimeError(f"{version}:conv2 輸出攤平跟 FC 輸入的 src 不同")
    fc_output = fc_model.official_forward(fc_layer, stream)
    fc_result = fc_model.run_events(fc_events)
    fc_ref.check_against_official(fc_model, fc_events, fc_result, fc_output)

    # 答案檔:時間 mod 2^W
    now = int(in_events[-1, 3])
    conv1_params, conv1_result = conv_results["conv1"]
    lines = [f"sample {len(in_events)} {len(conv1_result['outputs'])} {len(conv2_result['outputs'])} "
             f"{len(conv1_result['writes'])} {len(conv2_result['writes'])} "
             f"{conv1_result['membrane'].size} {conv2_result['membrane'].size}"]
    lines += [f"in {x} {y} {c} {t}" for x, y, c, t in zip(*in_events[:, :3].T, wrapped(in_events[:, 3]))]
    lines += [f"conv1_out {oc} {oy} {ox} {t % 2 ** STREAM_TIME_WIDTH}" for oc, oy, ox, t in conv1_result["outputs"]]
    lines += [f"conv2_out {oc} {oy} {ox} {t % 2 ** STREAM_TIME_WIDTH} {src}"
              for (oc, oy, ox, t), src in zip(conv2_result["outputs"], fc_events[:, 0])]
    for layer_name, (params, loop_result) in conv_results.items():
        writes = loop_result["writes"].copy()
        writes[:, 4] = wrapped(writes[:, 4])
        lines += net_ref.write_lines_of(params, writes, f"{layer_name}_write")
    lines += [f"fc_update {t} " + " ".join(str(membrane) for membrane in update)
              for t, update in zip(wrapped(fc_events[:, 1]), fc_result["updates"])]
    rule_counts = []
    for layer_name, (params, loop_result) in conv_results.items():
        rules = clear_rules(params, loop_result, now)
        rule_counts.append(f"{layer_name} clear_rule 0/1/2 = {[int(np.sum(rules == r)) for r in range(3)]}")
        state = dict(loop_result, last_time=wrapped(loop_result["last_time"]))
        lines += conv_ref.state_lines(params, state, f"{layer_name}_state", rules)

    path = out_dir / f"salt_conv_fc_net_stale_clear_SAT{fc_params.saturate_enabled}.txt"
    conv_ref.write_lines(path, lines + ["end 1"])
    print(f"{path.name}:輸入 {len(in_events)} 筆(到 {now} ms,相鄰最多隔 {max_gap} ms),"
          f"conv1 輸出 {len(conv1_result['outputs'])}、更新 {len(conv1_result['writes'])},"
          f"conv2 輸出 {len(conv2_result['outputs'])}、更新 {len(conv2_result['writes'])},"
          f"FC 相鄰輸入最多隔 {fc_max_gap} ms;{';'.join(rule_counts)};{len(lines) + 1} 行")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path, help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--mem-dir", required=True, type=Path, help="SaltNET.srcs/sources_1/mem,訓練端匯出的資料檔")
    parser.add_argument("--out-dir", required=True, type=Path,
                        help="答案檔輸出目錄,FC 的 n_col = 4 資料檔也在這裡(gen_salt_conv_fc_net_ref.py 寫的)")
    args = parser.parse_args()

    training = net_ref.load_training(args.training_repo)
    for version in (WRAP_VERSION, SATURATE_VERSION):
        build_reference(training, args.training_repo, args.mem_dir, args.out_dir, version)


if __name__ == "__main__":
    main()
