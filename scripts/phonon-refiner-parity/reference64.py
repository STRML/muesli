"""64-token greedy decode that ignores EOS, so every case is compared over 64 steps.

usage: reference64.py <out_dir>
Same prompts and weights as reference.py (float32 on the dequantized MLX checkpoint). Writes per case the logits of all
64 steps (float32 .bin, [64, vocab]) and the 64 greedy token ids.
"""
import json, os, sys
import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
sys.path.insert(0, os.path.dirname(__file__))
from prompts import CASES

out_dir = sys.argv[1]
os.makedirs(out_dir, exist_ok=True)
path = os.path.expanduser('~/.cache/muesli-phonon-ref/hf-dequant-f32')
tok = AutoTokenizer.from_pretrained(path)
model = AutoModelForCausalLM.from_pretrained(path, trust_remote_code=True, dtype=torch.float32)
model.eval()
result = {}
for name, system, user in CASES:
    msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
    text = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, enable_thinking=False)
    ids = tok(text, add_special_tokens=False, return_tensors="pt").input_ids
    steps, tokens = [], []
    with torch.no_grad():
        out = model(ids, use_cache=True)
        cache = out.past_key_values
        logits = out.logits[0, -1]
        for _ in range(64):
            steps.append(logits.float().numpy())
            nxt = int(logits.argmax())
            tokens.append(nxt)
            out = model(torch.tensor([[nxt]]), past_key_values=cache, use_cache=True)
            cache = out.past_key_values
            logits = out.logits[0, -1]
    np.stack(steps).astype("<f4").tofile(f"{out_dir}/{name}.steps.bin")
    result[name] = {"text": text, "prompt_ids": ids[0].tolist(), "greedy": tokens, "steps": 64,
                    "vocab": int(steps[0].shape[0]), "decoded": tok.decode(tokens)}
    print(name, len(ids[0]), repr(tok.decode(tokens)))
json.dump(result, open(f"{out_dir}/reference.json", "w"), indent=1)
