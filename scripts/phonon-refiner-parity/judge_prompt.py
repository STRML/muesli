"""Builds a blind pairwise judge prompt. usage: judge_prompt.py <eval-set> <outputs-dir> <order: AB|BA> > prompt.txt

A = phonon_refiner, B = pro_qwen_v14 for AB; swapped for BA. The judge sees the app, the speaker's dictionary,
the raw dictation, the intended text, and two candidates; it never sees model names.
"""
import json, sys

rows = [json.loads(l) for l in open(sys.argv[1])]
outs = {n: {json.loads(l)["id"]: json.loads(l) for l in open(f"{sys.argv[2]}/{n}.jsonl")} for n in ("phonon_refiner", "pro_qwen_v14")}
first, second = ("phonon_refiner", "pro_qwen_v14") if sys.argv[3] == "AB" else ("pro_qwen_v14", "phonon_refiner")

print("""You are a strict, blind judge of dictation cleanup. For each item, a speaker dictated text into an app; a
speech recognizer produced the RAW transcript; two systems (A and B) rewrote it. INTENDED is what the speaker meant to
type. Pick the candidate that is closer to INTENDED in wording and meaning: it fixes recognition errors and technical
terms (the speaker's DICTIONARY lists terms they use), removes filler and false starts, keeps only the final version of
a self-correction, writes digits the way an engineer types them, never invents words and never drops meaning.
Capitalization and punctuation style matter little; wording and meaning matter most. Answer "tie" only if both are
equally good or equally bad.

Reply with ONLY a JSON object mapping each item id to "A", "B" or "tie". No prose.
""")
for row in rows:
    a = outs[first][row["id"]]["final"]
    b = outs[second][row["id"]]["final"]
    print(f"--- {row['id']}")
    print(f"APP: {row['app_name']}" + (f" ({row['url']})" if row.get("url") else ""))
    print("DICTIONARY: " + (", ".join(row["vocabulary"]) or "(none)"))
    print("RAW: " + json.dumps(row["raw"], ensure_ascii=False))
    print("INTENDED: " + json.dumps(row["reference"], ensure_ascii=False))
    print("A: " + json.dumps(a, ensure_ascii=False))
    print("B: " + json.dumps(b, ensure_ascii=False))
