"""產生整個網路 SaltConvFCNet(conv1 → conv2 → ConvToFCAdapter → SaltFC → FCMembraneRegister)的參考答案,
給 tb_salt_conv_fc_net_*.sv(清單見 run_tb_salt_conv_fc_net.tcl);同時寫 FC 的權重檔、衰減表檔。

目標:每一層每一次更新的 (t, V̂)、每一個 spike 都跟訓練端對上。
答案用訓練端的函式算,每一層都有兩份互相比對,一致才寫答案檔:
- 官方:訓練端整層 forward + QuantBackend,trace=True(每顆神經元每一次更新之後的暫存器值、有沒有 fire、事件時間)。
- 逐筆迴圈:照硬體的做法一筆事件一筆事件算(scripts/conv/gen_salt_conv_ref.py、scripts/fc/gen_salt_fc_ref.py 的
  LayerModel.run_events)。硬體寫回神經元記憶體的順序從這裡來。
比對:
- 每層的輸出事件流:逐筆迴圈跟官方相同(單層腳本的 check_against_official)。
- conv 每一次更新:逐筆迴圈的每一次更新,依神經元分開後,要等於官方 trace 每顆神經元的逐次值(V̂、t、fire)。
  trace 每顆神經元在真事件之後多一步 catch-up(衰減到這一層最後一筆輸入事件的時間,權重 0),硬體不做,比對時跳過;
  catch-up 那一步跟之後補齊的步數 trace.event_ms 是 nan,只比 event_ms 有值的步。
- conv 樣本結束時的 V̂:逐筆迴圈補上 catch-up 之後等於官方 v_final;答案檔寫 catch-up 之前的值。
- FC 每一次更新:逐筆迴圈每筆事件之後的 V̂ 等於官方 trace.v_steps(單層腳本的 check_against_official)。
  FC 每筆事件都更新全部神經元,catch-up 的 Δt 一律是 0。
- FC 的輸入:conv2 輸出事件的 o_c·H·W + o_y·W + o_x 等於訓練端 FC 輸入流的 event_source_idx。
- 跟訓練端評估時存的 eval/test_outputs.npz 比:每層 spike 數(沒被截斷時)、FC 最後的 V̂ 等於 v_final_int。

樣本:test 評估取樣的前 SAMPLE_COUNT 筆(跟單層、兩層串接的答案同一批)。量化資料夾照 quant_versions.txt,
繞回版、飽和版各一個答案檔 salt_conv_fc_net_SAT<0|1>.txt。答案檔約 33 MB 一個,不進 git(.gitignore),
跑模擬前先跑這支腳本。答案跟 FC 的 n_col 無關(n_col 只影響權重怎麼打包);FC 的權重檔、衰減表檔照
FC_COLUMN_COUNTS 每個 n_col 各寫一份,檔名同 gen_salt_fc_ref.py 的 ParamSet.stem,這些檔進 git。

答案檔一行一筆,第一個欄位是種類,欄位以空白分隔,全部十進位,有號數直接寫負號:
    sample <in_count> <conv1_out_count> <conv2_out_count> <conv1_write_count> <conv2_write_count> <conv1_state_count> <conv2_state_count>
    in <x> <y> <c> <t>                                         × in_count,網路的輸入(conv1 的輸入)
    conv1_out <o_c> <o_y> <o_x> <t>                            × conv1_out_count,conv1 送出的順序
    conv2_out <o_c> <o_y> <o_x> <t> <src>                      × conv2_out_count,conv2 送出的順序;src 是轉接模組換出來的編號
    conv1_write <row_bank> <col_bank> <bank_addr> <membrane> <t>   × conv1_write_count,conv1 每一次更新,照硬體寫回的順序
    conv2_write <row_bank> <col_bank> <bank_addr> <membrane> <t>   × conv2_write_count
    fc_update <t> <V̂_0> ... <V̂_{n_out-1}>                        × conv2_out_count,FC 每筆輸入事件處理完之後全部神經元的 V̂
    conv1_state <row_bank> <col_bank> <bank_addr> <membrane> <last_time>   × conv1_state_count,樣本結束時每顆一行
    conv2_state <row_bank> <col_bank> <bank_addr> <membrane> <last_time>   × conv2_state_count
    end <sample_count>
bank、bank 內位址照 Conv.md 第 2 節(gen_salt_conv_ref.bank_location)。write 的順序:事件 → o_c → 候選 (o_y, o_x)
由小到大;同一個 (事件, o_c) 的候選在不同 bank,硬體同一拍寫回,testbench 依 bank 分開照順序比。

用法(WSL,conda 環境 jax,在 scripts/net 目錄執行):
    python gen_salt_conv_fc_net_ref.py \
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
sys.path.insert(0, str(SCRIPTS_DIR))   # scripts/:quant_versions.py
import gen_salt_conv_ref as conv_ref  # noqa: E402
import gen_salt_fc_ref as fc_ref  # noqa: E402
from quant_versions import SATURATE_VERSION, WRAP_VERSION  # noqa: E402  量化資料夾,換權重改 quant_versions.txt

CONV_LAYERS = ("conv1", "conv2")
# run_tb_salt_conv_fc_net.tcl 參數組用到的 FC n_col:4 是實際設定,1 讓 FC 最慢、逼出反壓
FC_COLUMN_COUNTS = (4, 1)


def load_training(training_repo: Path) -> dict:
    """conv、FC 兩支單層腳本要的訓練端函式合在一起。"""
    training = conv_ref.load_training(training_repo)
    training.update(fc_ref.load_training(training_repo))
    return training


def check_writes_against_trace(version: str, layer_name: str, sample_index: int, params, writes: np.ndarray,
                               trace) -> None:
    """逐筆迴圈的每一次更新,依神經元分開後,跟官方 trace 每顆神經元的逐次值比。
    writes: (更新次數, 6) 的 (o_c, o_y, o_x, V̂_new, t, fire),照硬體順序。trace 的神經元編號是 o_c·H·W + o_y·W + o_x
    (訓練端 tile_channels,channel 在最外層);每顆前 n_real 步是真事件,之後是 catch-up 跟補齊,event_ms 是 nan。"""
    where = f"{version} {layer_name} 第 {sample_index} 筆"
    v_steps = np.asarray(trace.v_steps)
    event_ms = np.asarray(trace.event_ms)
    spike_mask = np.asarray(trace.spike_mask)
    neuron_count, step_count = v_steps.shape
    real = np.isfinite(event_ms)
    real_count = real.sum(axis=1)
    if not np.array_equal(real, np.arange(step_count)[None, :] < real_count[:, None]):
        raise RuntimeError(f"{where}:trace 的真事件步不是每顆神經元最前面那幾步")

    neuron = writes[:, 0] * params.out_rows * params.out_cols + writes[:, 1] * params.out_cols + writes[:, 2]
    loop_count = np.bincount(neuron, minlength=neuron_count)
    if not np.array_equal(loop_count, real_count):
        bad = np.flatnonzero(loop_count != real_count)
        raise RuntimeError(f"{where}:更新次數跟 trace 不同,例如神經元 {bad[:5].tolist()}:"
                           f"逐筆迴圈 {loop_count[bad[:5]].tolist()} 次,trace {real_count[bad[:5]].tolist()} 次")
    # 依神經元排、同一顆維持更新順序,就是 trace[real] 的列優先順序
    by_neuron = writes[np.argsort(neuron, kind="stable")]
    for column, name, official in ((3, "V̂", v_steps[real]), (4, "t", event_ms[real]), (5, "fire", spike_mask[real])):
        if not np.array_equal(by_neuron[:, column], official.astype(np.int64)):
            bad = np.flatnonzero(by_neuron[:, column] != official.astype(np.int64))
            raise RuntimeError(f"{where}:有 {bad.size} 次更新的 {name} 跟 trace 不同,"
                               f"例如 (o_c, o_y, o_x) {by_neuron[bad[0], :3].tolist()}")


def write_lines_of(params, writes: np.ndarray, kind: str) -> list[str]:
    """每一次更新一行:<kind> <row_bank> <col_bank> <bank_addr> <V̂> <t>,照硬體順序。"""
    row_bank, col_bank, bank_addr = conv_ref.bank_location(params, writes[:, 0], writes[:, 1], writes[:, 2])
    return [f"{kind} {rb} {cb} {addr} {v} {t}"
            for rb, cb, addr, v, t in zip(row_bank, col_bank, bank_addr, writes[:, 3], writes[:, 4])]


def build_references(training: dict, training_repo: Path, mem_dir: Path, out_dir: Path) -> None:
    for version in (WRAP_VERSION, SATURATE_VERSION):
        trained = conv_ref.load_trained_version(training, training_repo, version)
        model_file, raw, test_outputs = trained["model_file"], trained["raw"], trained["test_outputs"]
        layer_names = [layer.name for layer in model_file.network.layers]
        if layer_names != [*CONV_LAYERS, fc_ref.TRAINED_LAYER]:
            raise RuntimeError(f"{version} 的層是 {layer_names},整個網路的答案要改")

        conv_models = {}
        for layer_name in CONV_LAYERS:
            params = [p for v, name, p in conv_ref.TRAINED_SETS if v == version and name == layer_name][0]
            conv_models[layer_name] = conv_ref.trained_layer_model(training, model_file, version, layer_name, params,
                                                                   mem_dir)
        # FC 的答案跟 n_col 無關,用第一個 n_col 的參數組算;權重檔、衰減表檔每個 n_col 各寫一份
        fc_trained_params = [p for v, p in fc_ref.TRAINED_SETS if v == version][0]
        fc_param_sets = [dataclasses.replace(fc_trained_params, neurons_per_row=n_col) for n_col in FC_COLUMN_COUNTS]
        fc_layer, fc_model = fc_ref.trained_layer_model(training, model_file, version, fc_param_sets[0])
        for fc_params in fc_param_sets:
            fc_ref.write_data_files(training, out_dir, fc_params, fc_model.q, fc_model.decay_table, None)
            fc_ref.check_exported_files(training, version, fc_params, out_dir)
        fc_layer_index = len(CONV_LAYERS)

        lines = []
        for sample_index in range(conv_ref.SAMPLE_COUNT):
            stream = model_file.network.input_stream(training["take_input_events"](raw, sample_index))
            in_events = None
            conv_results = {}
            for layer_name in CONV_LAYERS:
                layer_index, layer, model = conv_models[layer_name]
                params = model.params
                events = conv_ref.stream_events(stream, params.in_rows, params.in_cols)
                conv_ref.check_time_width(params, events)
                if in_events is None:
                    in_events = events
                output = model.official_forward(stream, layer.max_queue_len, layer.max_out_spikes, trace=True)
                loop_result = model.run_events(events)
                conv_ref.check_against_official(model, events, loop_result, output)
                check_writes_against_trace(version, layer_name, sample_index, params, loop_result["writes"],
                                           output.trace)
                conv_ref.check_spike_count(version, layer_name, sample_index, layer_index,
                                           len(loop_result["outputs"]), test_outputs)
                conv_results[layer_name] = (params, loop_result)
                stream = output.stream

            fc_events = fc_ref.stream_events(stream)
            fc_ref.check_time_width(fc_model.params, fc_events)
            conv2_params, conv2_result = conv_results["conv2"]
            flattened = np.array([oc * conv2_params.out_rows * conv2_params.out_cols + oy * conv2_params.out_cols + ox
                                  for oc, oy, ox, _ in conv2_result["outputs"]], dtype=np.int64)
            if not np.array_equal(flattened, fc_events[:, 0]):
                raise RuntimeError(f"{version} 第 {sample_index} 筆:conv2 輸出攤平跟 FC 輸入的 src 不同")
            fc_output = fc_model.official_forward(fc_layer, stream)
            fc_result = fc_model.run_events(fc_events)
            fc_ref.check_against_official(fc_model, fc_events, fc_result, fc_output)
            conv_ref.check_spike_count(version, fc_ref.TRAINED_LAYER, sample_index, fc_layer_index,
                                       len(fc_result["outputs"]), test_outputs)
            if len(fc_events) and not np.array_equal(fc_result["updates"][-1],
                                                     test_outputs["v_final_int"][sample_index]):
                raise RuntimeError(f"{version} 第 {sample_index} 筆:FC 最後的 V̂ 跟 test_outputs.npz 的 v_final_int 不同")

            conv1_params, conv1_result = conv_results["conv1"]
            lines.append(f"sample {len(in_events)} {len(conv1_result['outputs'])} {len(conv2_result['outputs'])} "
                         f"{len(conv1_result['writes'])} {len(conv2_result['writes'])} "
                         f"{conv1_result['membrane'].size} {conv2_result['membrane'].size}")
            lines += [f"in {x} {y} {c} {t}" for x, y, c, t in in_events]
            lines += conv_ref.output_lines(conv1_result, "conv1_out")
            lines += [f"conv2_out {oc} {oy} {ox} {t} {src}"
                      for (oc, oy, ox, t), src in zip(conv2_result["outputs"], fc_events[:, 0])]
            lines += write_lines_of(conv1_params, conv1_result["writes"], "conv1_write")
            lines += write_lines_of(conv2_params, conv2_result["writes"], "conv2_write")
            lines += [f"fc_update {t} " + " ".join(str(membrane) for membrane in update)
                      for (_, t), update in zip(fc_events, fc_result["updates"])]
            lines += conv_ref.state_lines(conv1_params, conv1_result, "conv1_state")
            lines += conv_ref.state_lines(conv2_params, conv2_result, "conv2_state")
            print(f"{version} 第 {sample_index} 筆:輸入 {len(in_events)},conv1 輸出 {len(conv1_result['outputs'])}、"
                  f"更新 {len(conv1_result['writes'])},conv2 輸出 {len(conv2_result['outputs'])}、"
                  f"更新 {len(conv2_result['writes'])}")

        path = out_dir / f"salt_conv_fc_net_SAT{fc_trained_params.saturate_enabled}.txt"
        conv_ref.write_lines(path, lines + [f"end {conv_ref.SAMPLE_COUNT}"])
        print(f"{path.name}: 樣本 {conv_ref.SAMPLE_COUNT} 筆,{len(lines) + 1} 行")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path, help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--mem-dir", required=True, type=Path, help="SaltNET.srcs/sources_1/mem,訓練端匯出的資料檔")
    parser.add_argument("--out-dir", required=True, type=Path, help="答案檔、FC 資料檔輸出目錄")
    args = parser.parse_args()

    training = load_training(args.training_repo)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    build_references(training, args.training_repo, args.mem_dir, args.out_dir)


if __name__ == "__main__":
    main()
