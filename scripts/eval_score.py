#!/usr/bin/env python3
"""Scores sabbel-eval runs against a refs.json (stdlib only).

usage: eval_score.py REFS.json RUN.jsonl [RUN.jsonl ...]

One row per run: WER, English terms kept, dup, p50/p95/max finish_ms.
  WER    words are [^\\W_][\\w'-]*, lowercased; Levenshtein over words; summed
         over all clips, divided by the reference words.
  terms  an `en_terms` entry is kept if difflib ratio >= 0.85 against any
         output word (a multi-word term: any run of as many output words).
  dup    immediately repeated words in the hypothesis that the reference does
         not repeat (boundary duplicates of the streaming path).
"""
import difflib
import json
import re
import sys
from collections import Counter
from pathlib import Path

WORD = re.compile(r"[^\W_][\w'-]*")


def words(text):
    return WORD.findall(text.lower())


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def repeats(ws):
    return Counter(a for a, b in zip(ws, ws[1:]) if a == b)


def term_kept(term, hyp):
    t = words(term)
    if not t:
        return True
    n = len(t)
    joined = " ".join(t)
    for i in range(max(1, len(hyp) - n + 1)):
        if difflib.SequenceMatcher(None, joined, " ".join(hyp[i:i + n])).ratio() >= 0.85:
            return True
    return False


def percentile(sorted_values, p):
    if not sorted_values:
        return 0.0
    return sorted_values[min(len(sorted_values) - 1, int(p * len(sorted_values)))]


def score(refs, rows):
    by_clip = {r["clip"]: r for r in refs}
    edits = ref_words = terms = kept = dup = 0
    times = []
    for row in rows:
        ref = by_clip[row["clip"]]
        r, h = words(ref["ref"]), words(row["text"])
        edits += edit_distance(r, h)
        ref_words += len(r)
        for term in ref.get("en_terms", []):
            terms += 1
            kept += term_kept(term, h)
        extra = repeats(h) - repeats(r)
        dup += sum(extra.values())
        times.append(row["finish_ms"])
    times.sort()
    return {
        "n": len(rows),
        "wer": 100 * edits / max(1, ref_words),
        "terms": 100 * kept / max(1, terms),
        "dup": dup,
        "p50": percentile(times, 0.5),
        "p95": percentile(times, 0.95),
        "max": times[-1] if times else 0.0,
    }


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    refs = json.loads(Path(argv[1]).read_text())
    print(f"{'run':<24}{'n':>5}{'WER%':>8}{'terms%':>8}{'dup':>5}{'p50ms':>8}{'p95ms':>8}{'maxms':>8}")
    for path in argv[2:]:
        rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
        s = score(refs, rows)
        print(f"{Path(path).stem:<24}{s['n']:>5}{s['wer']:>8.1f}{s['terms']:>8.1f}{s['dup']:>5}"
              f"{s['p50']:>8.0f}{s['p95']:>8.0f}{s['max']:>8.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
