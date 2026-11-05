"""WER of each model's final text against the authored reference, per mode and overall.

usage: score.py <eval-set.jsonl> <outputs-dir> [output|final]  (final = after the dictionary pass, the default)
Normalization: lowercase, punctuation removed (apostrophes kept), whitespace collapsed. Case and punctuation style
are not scored, so a model is not penalised for a mode's casing rule; wording, filler, corrections and terms are.
"""
import json, re, sys
import jiwer

MODE_OF = {}
CASUAL = {"com.hnc.Discord", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram"}

def mode(row):
    url = row.get("url") or ""
    if row["bundle_id"] in CASUAL or "x.com" in url:
        return "casual"
    if row["bundle_id"] in {"com.apple.mail", "com.microsoft.Outlook", "com.tinyspeck.slackmacgap", "com.microsoft.teams2"} or "mail.google.com" in url:
        return "formal"
    if row["bundle_id"] in {"com.openai.codex", "com.anthropic.claudefordesktop", "com.apple.Terminal", "com.googlecode.iterm2",
                            "com.microsoft.VSCode", "com.apple.dt.Xcode"} or "chatgpt.com" in url:
        return "prompt"
    return "minimal"

def norm(text):
    text = text.lower().replace("%", " percent")
    text = re.sub(r"(?<=\d):(?=\d)", "", text)          # 6:30 -> 630
    text = re.sub(r"[^\w\s']", " ", text)
    return " ".join(text.split())

FIELD = sys.argv[3] if len(sys.argv) > 3 else "final"
rows = [json.loads(l) for l in open(sys.argv[1])]
outputs = {}
for name in ("phonon_refiner", "pro_qwen_v14"):
    outputs[name] = {json.loads(l)["id"]: json.loads(l) for l in open(f"{sys.argv[2]}/{name}.jsonl")}

def corpus(texts_by_id, ids):
    refs = [norm(next(r for r in rows if r["id"] == i)["reference"]) for i in ids]
    hyps = [norm(texts_by_id[i]) for i in ids]
    return jiwer.wer(refs, hyps)

report = {}
groups = {"all": [r["id"] for r in rows]}
for r in rows:
    groups.setdefault(mode(r), []).append(r["id"])
raw = {r["id"]: r["raw"] for r in rows}
for group, ids in groups.items():
    entry = {"rows": len(ids), "raw_input_wer": round(corpus(raw, ids), 4)}
    for name, out in outputs.items():
        entry[name] = round(corpus({i: out[i][FIELD] for i in ids}, ids), 4)
    report[group] = entry
for name, out in outputs.items():
    report.setdefault("fallbacks", {})[name] = sum(1 for r in rows if out[r["id"]]["fallback"])
    report.setdefault("exact_after_norm", {})[name] = sum(
        1 for r in rows if norm(out[r["id"]][FIELD]) == norm(r["reference"]))
print(json.dumps(report, indent=2))
