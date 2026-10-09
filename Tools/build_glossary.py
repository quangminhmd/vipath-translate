#!/usr/bin/env python3
"""
Chuyển glossary Markdown của Vitranslate (glossary/*.md + domains/*.md) thành glossary.json
để nhúng vào app iOS ViPath Translate.

Dùng:
    python3 build_glossary.py <đường-dẫn-repo-Vitranslate> <file-ra.json> [domain ...]
    # mặc định domain = pathology

Mỗi dòng bảng | English | Tiếng Việt | Ghi chú | thành một entry:
  - Cột English tách theo " / " thành nhiều biến thể (anaplasia / anaplastic).
  - Ngoặc đơn là viết tắt  → thêm làm alias:  "immunohistochemistry (IHC)" → IHC
  - Ngoặc đơn là diễn giải của viết tắt → alias: "HPF (high power field)"
  - Ngoặc đơn khác là ngữ cảnh → bỏ khỏi chuỗi khớp, đưa vào ghi chú:
        "nest (of cells)", "alteration (molecular)"
Các dòng gạch đầu dòng ngoài bảng (giọng văn, quy tắc) được gom vào "rules".
"""
import json
import re
import sys
from pathlib import Path

ABBR = re.compile(r"^[A-Za-z0-9][A-Za-z0-9\-\./]{0,14}$")


def is_abbreviation(s: str) -> bool:
    s = s.strip()
    if not ABBR.match(s) or " " in s:
        return False
    upper = sum(c.isupper() for c in s)
    return upper >= 2 or (upper >= 1 and any(c.isdigit() for c in s))


def clean_md(s: str) -> str:
    return re.sub(r"\*\*|`", "", s).strip()


def parse_english(cell: str):
    """Trả về (danh sách chuỗi khớp, ngữ cảnh bị bỏ)."""
    cell = clean_md(cell)
    terms, contexts = [], []
    for part in [p.strip() for p in cell.split(" / ")]:
        if not part or part.startswith("-"):
            continue
        m = re.match(r"^(.*?)\s*\(([^)]*)\)\s*(.*)$", part)
        if m:
            head = (m.group(1) + " " + m.group(3)).strip()
            inner = m.group(2).strip()
            if is_abbreviation(inner):
                terms.append(head)
                terms += [a.strip() for a in inner.split("/") if a.strip()]
            elif is_abbreviation(head) and len(inner.split()) >= 2:
                terms += [head, inner]
            else:
                terms.append(head)
                contexts.append(inner)
        else:
            terms.append(part)
    # bỏ trùng, giữ thứ tự
    seen, out = set(), []
    for t in terms:
        t = re.sub(r"\s+", " ", t).strip(" .,;")
        k = t.lower()
        if len(t) >= 2 and k not in seen:
            seen.add(k)
            out.append(t)
    return out, contexts


def parse_glossary(path: Path, domain: str):
    entries, rules = [], []
    section = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("#"):
            section = line.lstrip("#").strip()
            continue
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            if len(cells) < 2 or set(cells[0]) <= set("-: ") or cells[0].lower() == "english":
                continue
            en, vi = cells[0], clean_md(cells[1])
            note = clean_md(cells[2]) if len(cells) > 2 else ""
            if not en or not vi:
                continue
            terms, contexts = parse_english(en)
            if not terms:
                continue
            if contexts:
                note = (f"ngữ cảnh: {', '.join(contexts)}. " + note).strip()
            entries.append({
                "en": clean_md(en),
                "vi": vi,
                "note": note,
                "terms": terms,
                "section": section,
                "domain": domain,
            })
        elif line.startswith("- ") and section not in ("Bảng thuật ngữ",):
            rules.append({"section": section, "text": clean_md(line[2:])})
    return entries, rules


def parse_domain(path: Path):
    """Lấy mục 'Giọng văn', 'Giữ nguyên tiếng Anh', 'Ghi chú' của hồ sơ ngành."""
    if not path.exists():
        return {}
    out, cur = {}, None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            cur = line[3:].strip()
            out[cur] = []
        elif cur and line.strip():
            out[cur].append(clean_md(line.strip("- ").strip()))
    keep = ("Giọng văn", "Giữ nguyên tiếng Anh", "Ghi chú")
    return {k: " ".join(v) for k, v in out.items() if k in keep}


def main():
    repo = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    domains = sys.argv[3:] or ["pathology"]
    all_entries, all_rules, profiles = [], [], {}
    for d in domains:
        e, r = parse_glossary(repo / "glossary" / f"{d}.md", d)
        all_entries += e
        all_rules += r
        profiles[d] = parse_domain(repo / "domains" / f"{d}.md")
    for i, e in enumerate(all_entries):
        e["id"] = i
    data = {
        "source": "github.com/cloud1710/Vitranslate",
        "domains": domains,
        "profiles": profiles,
        "rules": all_rules,
        "entries": all_entries,
    }
    dst.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    n_terms = sum(len(e["terms"]) for e in all_entries)
    print(f"{len(all_entries)} entries, {n_terms} chuỗi khớp, {len(all_rules)} quy tắc → {dst}")


if __name__ == "__main__":
    main()
