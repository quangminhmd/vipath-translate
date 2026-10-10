#!/usr/bin/env python3
"""Bản Python của PHIRedactor.swift (cùng biểu thức ICU) để kiểm thử nhanh.
Chạy: pip install regex && python3 Tools/test_redactor.py"""
import regex as re

FAMILIES = ["Nguyễn", "Trần", "Lê", "Phạm", "Hoàng", "Huỳnh", "Phan", "Vũ", "Võ", "Đặng", "Bùi", "Đỗ",
            "Hồ", "Ngô", "Dương", "Lý", "Đinh", "Đoàn", "Lâm", "Trương", "Mai", "Tô", "Trịnh", "Hà",
            "Cao", "Lưu", "Châu", "Tạ", "Quách", "Thái", "Lương", "Tăng", "Kiều", "Triệu"]
# Địa danh / cụm thường gặp bắt đầu bằng họ — không che
NOT_NAMES = ["Hà Nội", "Hà Tĩnh", "Hà Giang", "Hà Nam", "Châu Âu", "Châu Á", "Châu Phi", "Châu Mỹ",
             "Cao Bằng", "Thái Bình", "Thái Nguyên", "Hồ Chí Minh", "Lâm Đồng", "Đồng Nai"]
# Họ trùng từ thường (Cao = cao, Mai = ngày mai…) → cần đủ họ + 2 chữ
AMBIGUOUS = ["Cao", "Mai", "Hà", "Lý", "Lâm", "Thái", "Tô", "Châu", "Tăng", "Lương", "Kiều", "Hồ", "Tạ", "Lưu"]
# Ngày đứng sau các cụm này là ngày truy cập / cập nhật tài liệu, không phải định danh
DOC_DATE_CUES = ["truy cập", "cập nhật", "ban hành", "phiên bản", "accessed", "updated", "published", "retrieved", "version"]
CAP = r"\p{Lu}[\p{Ll}\p{M}]*"
GAP = r"[ \t]+"   # tên không vắt qua dòng
SEP = r"\s*[:：#]?\s*"
STOP = r"(?=\s*(?:[\n,;|]|\s{2,}|$|\s-\s|\s(?i:tuổi|giới|nam|nữ|sinh|PID|mã|age|sex|DOB)\b))"
VALUE = r"([^\n,;|]{2,60}?)" + STOP
CODE = r"([A-Za-z0-9][A-Za-z0-9\-/\.]{1,23}[A-Za-z0-9])"
NAME_VALUE = r"(\p{Lu}[^\n,;|]{1,59}?)" + STOP

def R(kind, pat, ci=True):
    return (kind, re.compile(pat, re.I if ci else 0))

RULES = [
    R("TÊN", r"(?<![\p{L}])(?i:họ\s+và\s+tên|họ\s+tên|tên\s+bệnh\s+nhân|tên\s+BN|bệnh\s+nhân|BN|patient(?:'s)?\s+name|patient|name)\s*[:：]\s*" + NAME_VALUE, ci=False),
    R("PID", r"(?<![\p{L}])(?:PID|mã\s+BN|mã\s+bệnh\s+nhân|mã\s+y\s+tế|mã\s+hồ\s+sơ|số\s+hồ\s+sơ|số\s+bệnh\s+án|số\s+vào\s+viện|MRN|hospital\s+(?:number|no\.?)|medical\s+record\s+(?:number|no\.?))" + SEP + CODE),
    R("MÃ_BP", r"(?<![\p{L}])(?:mã\s+bệnh\s+phẩm|mã\s+GPB|số\s+GPB|mã\s+tiêu\s+bản|số\s+tiêu\s+bản|mã\s+mẫu|specimen\s+(?:ID|number|no\.?)|accession(?:\s+(?:number|no\.?))?|case\s+(?:ID|number|no\.?)|lab\s+(?:ID|no\.?))" + SEP + CODE),
    R("NGÀY_SINH", r"(?<![\p{L}])(?:ngày\s+sinh|năm\s+sinh|sinh\s+ngày|sinh\s+năm|NS|DOB|date\s+of\s+birth|born(?:\s+on)?)" + SEP + r"(\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}|\d{4}-\d{2}-\d{2}|(?:19|20)\d{2})"),
    R("ĐỊA_CHỈ", r"(?<![\p{L}])(?:địa\s+chỉ|address)\s*[:：]\s*([^\n]{3,120})"),
    R("SĐT", r"(?<![\p{L}])(?:SĐT|SDT|điện\s+thoại|phone|tel|mobile)" + SEP + r"(\+?\d[\d\s.\-]{7,14}\d)"),
    R("GIẤY_TỜ", r"(?<![\p{L}])(?:CCCD|CMND|CMT|căn\s+cước|passport|hộ\s+chiếu|ID\s+card)(?:\s+(?:số|no\.?))?" + SEP + r"([A-Z0-9]{6,12})"),
    R("TÊN", r"(?<![\p{L}])(?:[Ôô]ng|[Bb]à|anh|[Cc]hị|cô|chú|bác|cháu|Mr\.?|Mrs\.?|Ms\.?|Miss)" + GAP + "(" + CAP + r"(?:" + GAP + CAP + r"){0,4})", ci=False),
    R("TÊN", r"(?<![\p{L}])((?:" + "|".join(f for f in FAMILIES if f not in AMBIGUOUS) + r")(?:" + GAP + CAP + r"){1,3})(?![\p{L}])", ci=False),
    R("TÊN", r"(?<![\p{L}])((?:" + "|".join(sorted(AMBIGUOUS)) + r")(?:" + GAP + CAP + r"){2,3})(?![\p{L}])", ci=False),
    R("EMAIL", r"([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})"),
    R("MÃ_BP", r"(?<![A-Za-z0-9])([A-Z]{1,6}[\-/]?\d{2}[\-/.]\d{3,7})(?![A-Za-z0-9])", ci=False),
    R("GIẤY_TỜ", r"(?<![A-Za-z0-9])([A-Z]\d{7,8})(?![A-Za-z0-9])", ci=False),
    R("SĐT", r"(?<![\d])(\+84\s?\d{9}|0\d{9})(?![\d])"),
    R("GIẤY_TỜ", r"(?<![\d.,])(\d{9}|\d{12})(?![\d.,])"),
    R("NGÀY", r"(?<![\d/])(\d{1,2}[/\-.]\d{1,2}[/\-.](?:19|20)\d{2}|(?:19|20)\d{2}-\d{2}-\d{2})(?![\d/])"),
]

def redact(text, extra=()):
    mp, counters = {}, {}
    def ph(value, kind):
        k = value.strip().lower()
        if k in mp: return mp[k][0]
        counters[kind] = counters.get(kind, 0) + 1
        p = f"[{kind}_{counters[kind]}]"
        mp[k] = (p, value.strip(), kind)
        return p
    for t in extra:
        t = t.strip()
        if len(t) >= 2:
            text = re.sub(re.escape(t), ph(t, "ẨN"), text, flags=re.I)
    for kind, rx in RULES:
        out = text
        for m in reversed(list(rx.finditer(text))):
            v = m.group(1).strip()
            if len(v) < 2 or v.startswith("["): continue
            if kind == "TÊN" and any(v == n or v.startswith(n + " ") for n in NOT_NAMES): continue
            s, e = m.span(1)
            if kind == "NGÀY" and any(c in text[max(0, s - 24):s].lower() for c in DOC_DATE_CUES): continue
            # cắt khoảng trắng cuối giống Swift (trimming) — giữ khoảng trắng ngoài giá trị
            raw = text[s:e]
            lead = len(raw) - len(raw.lstrip()); trail = len(raw) - len(raw.rstrip())
            out = out[:s + lead] + ph(v, kind) + out[e - trail:]
        text = out
    return text, sorted(mp.values())

def restore(text, reps):
    for p, orig, _ in sorted(reps, key=lambda r: -len(r[0])):
        text = text.replace(p, orig)
    return text

CASES = [
    # (văn bản, chuỗi PHẢI biến mất, chuỗi PHẢI còn lại)
    ("Họ tên: NGUYỄN VĂN AN, 56 tuổi, Nam. PID: 2401234567. Mã bệnh phẩm: GPB-24-012345",
     ["NGUYỄN VĂN AN", "2401234567", "GPB-24-012345"], ["56 tuổi"]),
    ("Bệnh nhân: Trần Thị Bích Ngọc - Ngày sinh: 12/03/1965 - CCCD: 001165012345",
     ["Trần Thị Bích Ngọc", "12/03/1965", "001165012345"], []),
    ("Patient: John Smith, DOB 1965-03-12, MRN: A1234567, Accession #: S24-01234",
     ["John Smith", "1965-03-12", "A1234567", "S24-01234"], []),
    ("Bà Lê Thị Hoa, SĐT 0912345678, email hoa.le@gmail.com, hộ chiếu C1234567, địa chỉ: 12 Lý Thường Kiệt, Hà Nội",
     ["Lê Thị Hoa", "0912345678", "hoa.le@gmail.com", "C1234567", "12 Lý Thường Kiệt"], []),
    ("Đại thể: Bệnh phẩm cắt thùy giáp phải kích thước 4 x 3 x 2 cm. Vi thể: carcinôm nhú tuyến giáp, biến thể nang. "
     "Hóa mô miễn dịch: CD20 (+), CD3 (-), Ki-67 80%. IDH1 p.R132H; đồng mất đoạn 1p/19q; pT1aN1b; BRAF V600E; ICD-O 8260/3. "
     "Tham khảo WHO 2021, Châu Âu, Hà Nội.",
     [], ["CD20", "Ki-67", "p.R132H", "1p/19q", "pT1aN1b", "V600E", "8260/3", "WHO 2021", "Châu Âu", "Hà Nội", "4 x 3 x 2 cm"]),
    ("The patient is a 62-year-old woman. Sections show diffuse large B-cell lymphoma, Hans classification non-GCB.",
     [], ["62-year-old", "Hans", "non-GCB"]),
    ("BN: Phạm Minh Tuấn, nam, NS 1978, số vào viện 24012345, tiêu bản B24.5678 nhuộm HE.",
     ["Phạm Minh Tuấn", "1978", "24012345", "B24.5678"], ["nhuộm HE"]),
    # Báo nhầm thật trên tài liệu WHO vú (Sổ tay, 11/10): thiếu ranh giới từ, họ trùng từ thường, ngày truy cập, tên vắt dòng
    ("Papillary carcinoma Không Carcinôm Thường không Trong. Mucoepidermoid carcinoma; Epidemiology.",
     [], ["Không Carcinôm", "Thường", "Mucoepidermoid", "Epidemiology"]),
    ("Nhân Cao Lớn; Độ Cao Thay đổi. WHO Online, truy cập 08/10/2026. Cập nhật: 8/10/2026.\nTăng\nTăng\nTăng",
     [], ["Cao Lớn", "Cao Thay", "08/10/2026", "8/10/2026", "Tăng\nTăng"]),
    ("Người bệnh Cao Văn Minh nhập viện; ông Lâm khám lại.",
     ["Cao Văn Minh", "Lâm"], []),
]

fails = 0
for text, gone, kept in CASES:
    red, reps = redact(text)
    bad = [g for g in gone if g in red] + [f"mất '{k}'" for k in kept if k not in red]
    back = restore(red, reps)
    if back != text: bad.append("khôi phục sai: " + back)
    print(("OK  " if not bad else "FAIL") + " " + red)
    for b in bad: print("      ✗", b)
    fails += bool(bad)

red, reps = redact("Ca của Thầy Quang tại khoa X", extra=["Thầy Quang"])
print("custom:", red); assert "Thầy Quang" not in red
print(f"\n{len(CASES) - fails}/{len(CASES)} đạt")
