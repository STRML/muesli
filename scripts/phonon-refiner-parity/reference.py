"""transformers reference for the Phonon refiner (LFM3-1.7B), run on dequantized MLX weights.

usage: reference.py <dtype float32|bfloat16> <out_dir>
Writes per case: prompt ids, the logits of every greedy step (float32 .bin, [steps, vocab]) and the token ids.
Step 0 is the prediction at the last prompt position.
"""
import json, os, sys
import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
sys.path.insert(0, os.path.dirname(__file__))
from prompts import CASES

dtype = {"float32": torch.float32, "bfloat16": torch.bfloat16}[sys.argv[1]]
out_dir = sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
path = os.path.expanduser('~/.cache/muesli-phonon-ref/hf-dequant-f32')
tok = AutoTokenizer.from_pretrained(path)
model = AutoModelForCausalLM.from_pretrained(path, trust_remote_code=True, dtype=dtype)
model.eval()
result = {}
for name, system, user in CASES:
    msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
    text = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, enable_thinking=False)
    ids = tok(text, add_special_tokens=False, return_tensors="pt").input_ids
    with torch.no_grad():
        gen = model.generate(ids, max_new_tokens=64, do_sample=False, repetition_penalty=1.0, temperature=None,
                             top_k=None, top_p=None, output_scores=True, return_dict_in_generate=True)
    new = gen.sequences[0, ids.shape[1]:].tolist()
    scores = torch.stack(gen.scores)[:, 0].float().numpy()
    scores.astype("<f4").tofile(f"{out_dir}/{name}.steps.bin")
    result[name] = {"text": text, "prompt_ids": ids[0].tolist(), "greedy": new, "steps": int(scores.shape[0]),
                    "vocab": int(scores.shape[1]), "decoded": tok.decode(new)}
    print(name, len(ids[0]), "steps", scores.shape[0], repr(tok.decode(new)))
json.dump(result, open(f"{out_dir}/reference.json", "w"), indent=1)
