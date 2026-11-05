# Dequantize the MLX Phonon refiner weights into a float32 HF-layout checkpoint for the transformers reference.
import json, shutil, os
import mlx.core as mx
SRC = os.path.expanduser('~/.cache/muesli-phonon-ref/2b0ab74b')
CODE = os.path.expanduser('~/.cache/muesli-phonon-ref/lfm3-base-code')
OUT = os.path.expanduser('~/.cache/muesli-phonon-ref/hf-dequant-f32')
os.makedirs(OUT, exist_ok=True)
cfg = json.load(open(f'{SRC}/config.json'))
quant = cfg['quantization']
default = {'bits': quant['bits'], 'group_size': quant['group_size']}
w = mx.load(f'{SRC}/model.safetensors')
out = {}
for k, v in w.items():
    if k.endswith('.scales') or k.endswith('.biases'):
        base = k.rsplit('.', 1)[0]
        if (base + '.weight') in w and (base + '.scales') in w:
            continue
    if k.endswith('.weight') and (k[:-7] + '.scales') in w:
        base = k[:-7]
        q = quant.get(base, default)
        d = mx.dequantize(v, w[base + '.scales'], w[base + '.biases'], group_size=q['group_size'], bits=q['bits'])
        out[k] = d.astype(mx.float32)
    else:
        out[k] = v.astype(mx.float32)
# HF conv layout: [out, 1, kernel]; MLX layout [out, kernel, 1]
for k in list(out):
    if k.endswith('conv.conv.weight'):
        out[k] = out[k].transpose(0, 2, 1)
mx.save_safetensors(f'{OUT}/model.safetensors', out, metadata={'format': 'pt'})
hf_cfg = {k: v for k, v in cfg.items() if k not in ('quantization', 'quantization_config')}
hf_cfg['dtype'] = 'float32'
hf_cfg['auto_map'] = json.load(open(f'{CODE}/config.json'))['auto_map']
json.dump(hf_cfg, open(f'{OUT}/config.json', 'w'), indent=1)
for f in ('modeling_lfm3.py', 'configuration_lfm3.py', 'lfm3_conv.py'):
    shutil.copy(f'{CODE}/{f}', f'{OUT}/{f}')
for f in ('tokenizer.json', 'tokenizer_config.json', 'chat_template.jinja', 'generation_config.json'):
    shutil.copy(f'{SRC}/{f}', f'{OUT}/{f}')
print('wrote', len(out), 'tensors')
