"""Synthesizes one 16 kHz mono WAV per eval row (macOS `say`), for the key-up latency measurement only."""
import json, os, subprocess, sys

eval_set = sys.argv[1]
out = sys.argv[2]
os.makedirs(out, exist_ok=True)
for line in open(eval_set):
    row = json.loads(line)
    path = f"{out}/{row['id']}.wav"
    subprocess.run(["say", "-v", "Samantha", "--file-format=WAVE", "--data-format=LEI16@16000", "-o", path, row["raw"]], check=True)
print("wrote", len(os.listdir(out)), "files")
