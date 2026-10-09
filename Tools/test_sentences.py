#!/usr/bin/env python3
"""Bản Python của SentenceSplitter.swift để kiểm thử nhanh: python3 test_sentences.py"""

ABBR = {"e.g", "i.e", "al", "etc", "fig", "figs", "dr", "drs", "prof", "mr", "mrs", "ms",
        "vs", "approx", "no", "nos", "cf", "st", "ca", "resp", "vol", "ref", "refs",
        "tab", "eq", "dept", "univ", "inc", "ltd", "jr", "sr", "mt", "min", "max", "pt", "pts"}
CLOSERS = ".!?)]\"”’'"


def is_boundary(ch, dot, start, nxt):
    if ch[dot] != ".":
        return True
    j = dot - 1
    while j >= start and not ch[j].isspace() and ch[j] != "(":
        j -= 1
    word = "".join(ch[j + 1:dot]).lower()
    if word in ABBR:
        return False
    if len(word) == 1 and word.isalpha():
        return False
    k = nxt
    while k < len(ch) and ch[k].isspace():
        k += 1
    if k >= len(ch):
        return True
    n = ch[k]
    return n.isupper() or n.isdigit() or n in "(\"“'["


def complete(text):
    ch = list(text)
    out, start, i = [], 0, 0
    while i < len(ch):
        if ch[i] in ".!?":
            end = i + 1
            while end < len(ch) and ch[end] in CLOSERS:
                end += 1
            at_end = end >= len(ch)
            sp = (not at_end) and ch[end].isspace()
            if (at_end or sp) and is_boundary(ch, i, start, end):
                s = "".join(ch[start:end]).strip()
                if s:
                    out.append(s)
                start = end
            i = end
            continue
        i += 1
    return out, "".join(ch[start:])


if __name__ == "__main__":
    cases = [
        ("The tumor measured 3.5 cm. Margins were negative.", 2, ""),
        ("Markers (e.g. CD20, CD3) were tested. See Fig. 2 for details. Smith et al. reported this.", 3, ""),
        ("IDH1 p.R132H was detected. The diagnosis is astrocytoma", 1, "The diagnosis is astrocytoma"),
        ("Was it high grade? Yes! Mitoses were brisk.", 3, ""),
        ("Dr. Tan and Prof. Lee reviewed the case vs. the prior biopsy.", 1, ""),
        ("Reviewed by J. Smith. Final report issued.", 2, ""),
        ("so the next slide shows the nests of cells and", 0, "so the next slide shows the nests of cells and"),
    ]
    ok = True
    for text, n, rest in cases:
        s, r = complete(text)
        good = len(s) == n and r.strip() == rest
        ok &= good
        print("OK  " if good else "FAIL", s, "| rest:", repr(r.strip()))
    print("\nTất cả đạt" if ok else "\nCó ca lỗi")
