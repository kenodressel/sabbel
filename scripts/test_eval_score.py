#!/usr/bin/env python3
"""Fixture check for eval_score.py: synthetic data only. Run with python3 -I."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

here = Path(__file__).resolve().parent
refs = [
    {"clip": "a.wav", "seconds": 5, "ref": "the meeting brown deadline", "en_terms": ["meeting", "deadline"]},
    {"clip": "b.wav", "seconds": 5, "ref": "we had a long walk", "en_terms": []},
    {"clip": "c.wav", "seconds": 5, "ref": "the standup sprint code review",
     "en_terms": ["standup", "sprint", "code review"]},
]


def run(rows_by_run, check=True):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "refs.json").write_text(json.dumps(refs))
        paths = []
        for name, rows in rows_by_run.items():
            p = tmp / f"{name}.jsonl"
            p.write_text("\n".join(json.dumps(r) for r in rows))
            paths.append(str(p))
        out = subprocess.run([sys.executable, "-I", str(here / "eval_score.py"), str(tmp / "refs.json"), *paths],
                             check=check, capture_output=True, text=True)
    if not check:
        return out
    out = out.stdout
    return {line.split()[0]: line.split()[1:] for line in out.splitlines()[1:]}


def row(clip, text, ms):
    return {"clip": clip, "text": text, "finish_ms": ms, "audio_s": 5}


# 1 substitution in 4 words; one of two terms kept; the second clip is perfect.
r = run({
    "one": [row("a.wav", "the meeting brown box", 100)],
    # "the the" and "walk walk" are repeats the reference does not have.
    # ratio 0.857 (kept), 0.833 (just under 0.85, lost), multi-word term 0.952 (kept)
    "near": [row("c.wav", "the standap sprant code rview", 10)],
    "dup": [row("a.wav", "the the meeting brown deadline", 300), row("b.wav", "we had a long walk walk", 500)],
})
n, wer, terms, dup, p50, p95, mx = r["one"]
assert (n, float(wer), float(terms), dup, p50, p95, mx) == ("1", 25.0, 50.0, "0", "100", "100", "100"), r["one"]
n, wer, terms, dup, p50, p95, mx = r["dup"]
assert dup == "2" and float(terms) == 100.0 and (p50, p95, mx) == ("500", "500", "500"), r["dup"]
n, wer, terms, dup, *_ = r["near"]
assert abs(float(terms) - 66.7) < 0.05 and float(wer) == 60.0, r["near"]
bad = run({"bad": [row("zzz.wav", "x", 1)]}, check=False)
assert bad.returncode != 0 and "no entry" in bad.stderr, bad
print("eval_score fixture OK")
