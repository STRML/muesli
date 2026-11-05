# Phonon refiner: parity and evaluation scripts

Inputs to the opt-in checks in `native/MuesliNative/Tests/MuesliTests/PhononRefinerEvaluationTests.swift`. Nothing
here runs in CI. Results and how to read them are in [docs/phonon-refiner.md](../../docs/phonon-refiner.md).

All Python runs in the repository's shared venv with `-I`. Model files live outside the repository:

```
~/.cache/muesli-phonon-ref/
  2b0ab74b/                 Infatoshi/phonon-refiner-1.7b at 2b0ab74bee7ab7cf364695bbe44f64ce4c47439e (MLX files)
  lfm3-base-code/           modeling_lfm3.py, configuration_lfm3.py, lfm3_conv.py from LiquidAI/LFM3-1.7B @ 0dc4268b
  hf-dequant-f32/           written by dequant.py: float32 checkpoint in the Hugging Face layout
```

| Step | Command | Writes |
|---|---|---|
| Dequantize the MLX 4/6/8-bit weights | `python -I dequant.py` | `hf-dequant-f32/` |
| Reference run, stops at EOS | `python -I reference.py float32 <out>` | `reference.json`, `<case>.steps.bin` |
| Reference run, 64 steps with EOS ignored | `python -I reference64.py <out>` | same layout |
| Score the eval set (WER) | `python -I score.py <eval-set.jsonl> <outputs>` | JSON on stdout |
| Blind judge prompt | `python -I judge_prompt.py <eval-set.jsonl> <outputs> AB` | prompt on stdout |
| Speech for the latency run | `python3 make_audio.py <eval-set.jsonl> <wav-dir>` (outside the sandbox) | one WAV per row |

`transformers` 5.20 has no `lfm3` module, so the reference loads the model's own `modeling_lfm3.py` through
`trust_remote_code`. `config.json` of the refiner names no code, so `dequant.py` copies the `auto_map` from the base
model. Those three files come from LiquidAI/LFM3-1.7B (Apache-2.0 headers; the weights are under the LFM Open License).
No code from the Phonon app (GPL-3.0) is read or used.

Run the Swift side from the repository root, unsandboxed, with the Metal library of the test bundle:

```bash
MUESLI_LFM3_PARITY_ROOT=<out> MUESLI_PHONON_MODEL_DIR=~/.cache/muesli-phonon-ref/2b0ab74b \
MUESLI_MLX_EVAL_METALLIB=<scratch>/out/Products/Debug/MuesliTests.xctest/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
  swift test --package-path native/MuesliNative --scratch-path "$(scripts/muesli_spm_scratch_path.sh test)" \
  --filter PhononRefinerEvaluationTests
```

Pointing `MUESLI_PHONON_MODEL_DIR` at `hf-dequant-f32` runs the same comparison on float32 weights, which isolates the
port from the 4-bit arithmetic.
