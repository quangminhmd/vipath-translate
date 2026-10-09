#!/usr/bin/env python3
"""Bản Python của GPBSpeechNormalizer.swift (cùng biểu thức chính quy ICU/Python).
    python3 test_speech_normalizer.py "câu 1" "câu 2"
"""
import re
import sys

LN = {'A': 'a', 'B': 'bê', 'C': 'xê', 'D': 'đê', 'E': 'e', 'F': 'ép', 'G': 'giê', 'H': 'hát',
      'I': 'i', 'J': 'gi', 'K': 'ca', 'L': 'lờ', 'M': 'mờ', 'N': 'nờ', 'O': 'o', 'P': 'pê',
      'Q': 'quy', 'R': 'rờ', 'S': 'ét', 'T': 'tê', 'U': 'u', 'V': 'vê', 'W': 'vê kép',
      'X': 'ích', 'Y': 'i', 'Z': 'dét'}
L, R = r"(?<![A-Za-z0-9])", r"(?![A-Za-z0-9])"


def spell(s):
    return " ".join(LN.get(c.upper(), c) for c in s)


def spaced(s):
    if s == "is":
        return "i ét"
    groups, buf = [], ""
    for ch in s:
        if buf and buf[-1].isdigit() != ch.isdigit():
            groups.append(buf)
            buf = ""
        buf += ch
    groups.append(buf)
    return " ".join(g if g[0].isdigit() else ("ích" if g == "x" else g) for g in groups)


def tnm(g):
    head = ([spell(g[0])] if g[0] else []) + ["tê", spaced(g[1])]
    parts = [" ".join(head)]
    if g[2]:
        parts.append("nờ " + spaced(g[2][1:]))
    if g[3]:
        parts.append("mờ " + spaced(g[3][1:]))
    return ", ".join(parts)


RULES = [
    (L + r"(\d{1,2})([pq])/(\d{1,2})([pq])" + R, lambda g: f"{g[0]} {spell(g[1])}, {g[2]} {spell(g[3])}"),
    (L + r"p\.([A-Z])(\d+)([A-Z*])", lambda g: f"pê chấm {spell(g[0])} {g[1]} {'dừng' if g[2] == '*' else spell(g[2])}"),
    (L + r"(y?[pc]?)T(is|[0-4x][a-d]?)(N[0-3x][a-c]?)?(M[01x][a-c]?)?" + R, tnm),
    (L + r"([A-Z])(\d{2,4})([A-Z])" + R, lambda g: f"{spell(g[0])} {g[1]} {spell(g[2])}"),
    (L + r"([A-Z]{2,5})(\d{2,3})" + R, lambda g: f"{spell(g[0])} {g[1]}"),
]


def normalize(s):
    for pat, fn in RULES:
        s = re.sub(pat, lambda m: fn(m.groups()), s)
    return s.replace("×", " nhân ").replace("↑", " tăng ").replace("↓", " giảm ")


if __name__ == "__main__":
    for t in sys.argv[1:] or [
        "Đột biến IDH1 p.R132H dương tính; đồng mất đoạn 1p/19q; phân giai đoạn pT1aN1b.",
        "Dấu ấn CD20 dương tính lan toả, CD3 âm tính, Ki-67 khoảng 80%.",
        "BRAF V600E, EGFR T790M, KRAS p.G12D, TP53 p.R273*; ypT2N0M0, pTis; CK7, CK20, SOX10.",
    ]:
        print(normalize(t))
