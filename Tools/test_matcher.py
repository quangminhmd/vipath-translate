#!/usr/bin/env python3
"""Bản Python của GlossaryMatcher.swift — dùng để kiểm thử logic khớp thuật ngữ trên câu mẫu.
    python3 test_matcher.py ../ViPathTranslate/Resources/glossary.json
"""
import json
import re
import sys

BOUND_L, BOUND_R = r"(?<![A-Za-z0-9])", r"(?![A-Za-z0-9])"


def is_abbr(t):
    letters = [c for c in t if c.isalpha()]
    return bool(letters) and sum(c.isupper() for c in letters) >= max(2, len(letters) * 0.6) and " " not in t


def pattern(t):
    words = re.split(r"[\s\-]+", t)
    body = r"[\s\-]+".join(re.escape(w) for w in words)
    if not is_abbr(t) and len(t) >= 4:
        if body.endswith("y") and not body.endswith(("ay", "ey", "oy", "uy")):
            body = body[:-1] + "(?:y|ies)"
        elif not body.endswith("s"):
            body += "(?:s|es)?"
    return body


def build(entries):
    index, ci, cs = {}, [], []
    for e in entries:
        for t in e["terms"]:
            key = t if is_abbr(t) else t.lower()
            index.setdefault(key, []).append(e)
            (cs if is_abbr(t) else ci).append(t)
    ci = sorted(set(ci), key=len, reverse=True)
    cs = sorted(set(cs), key=len, reverse=True)
    rx_ci = re.compile(BOUND_L + "(" + "|".join(pattern(t) for t in ci) + ")" + BOUND_R, re.I)
    rx_cs = re.compile(BOUND_L + "(" + "|".join(pattern(t) for t in cs) + ")" + BOUND_R)
    return index, rx_ci, rx_cs


def normalize(s):
    return re.sub(r"[\s\-]+", " ", s)


def lookup(index, matched):
    m = normalize(matched)
    cands = [m, m.lower()]
    low = m.lower()
    if low.endswith("ies"):
        cands.append(low[:-3] + "y")
    if low.endswith("es"):
        cands.append(low[:-2])
    if low.endswith("s"):
        cands.append(low[:-1])
    for c in cands:
        for k in (c, c.replace(" ", "-")):
            if k in index:
                return index[k]
    # khớp mềm: so khi bỏ dấu cách/gạch nối
    flat = re.sub(r"[\s\-]", "", low)
    for k, v in index.items():
        if re.sub(r"[\s\-]", "", k.lower()) in (flat, flat.rstrip("s")):
            return v
    return []


def match(text, index, rx_ci, rx_cs):
    spans = []
    for rx in (rx_cs, rx_ci):
        for m in rx.finditer(text):
            if any(not (m.end() <= a or m.start() >= b) for a, b, _ in spans):
                continue
            spans.append((m.start(), m.end(), m.group(0)))
    spans.sort()
    hits, seen = [], set()
    for a, b, s in spans:
        for e in lookup(index, s):
            if e["id"] not in seen:
                seen.add(e["id"])
                hits.append((s, e))
    return hits


if __name__ == "__main__":
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    index, rx_ci, rx_cs = build(data["entries"])
    samples = [
        "Immunohistochemistry (IHC) showed diffuse nuclear staining; the tumor is an anaplastic meningioma with brisk mitoses (12 mitotic figures per 10 HPF).",
        "Sections show nests and sheets of atypical cells in a myxoid stroma, consistent with myxofibrosarcoma.",
        "Fine needle aspiration (FNA) of the thyroid nodule; findings favor follicular lymphoma rather than DLBCL.",
        "Biopsies from the bronchi revealed interstitial fibrosis with fibroblast foci.",
        "Dr King Tan, MD, PhD, Associate Professor at the National Cancer Center Hospital East.",
        "IDH-mutant astrocytoma with 1p/19q codeletion absent; low-grade glioma.",
    ]
    total = 0
    for s in samples:
        h = match(s, index, rx_ci, rx_cs)
        total += len(h)
        print("\n» " + s)
        for src, e in h:
            print(f"   {src!r:32} → {e['vi']}")
    print(f"\nTổng {total} thuật ngữ khớp")
