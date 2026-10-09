import fs from 'node:fs';
import * as L from '../src/logic.js';
let fails = 0;
const ok = (c, msg) => { if (!c) { fails++; console.log('FAIL', msg); } };

// Redactor — cùng bộ ca với Tools/test_redactor.py
const CASES = [
  ["Họ tên: NGUYỄN VĂN AN, 56 tuổi, Nam. PID: 2401234567. Mã bệnh phẩm: GPB-24-012345", ["NGUYỄN VĂN AN", "2401234567", "GPB-24-012345"], ["56 tuổi"]],
  ["Bệnh nhân: Trần Thị Bích Ngọc - Ngày sinh: 12/03/1965 - CCCD: 001165012345", ["Trần Thị Bích Ngọc", "12/03/1965", "001165012345"], []],
  ["Patient: John Smith, DOB 1965-03-12, MRN: A1234567, Accession #: S24-01234", ["John Smith", "1965-03-12", "A1234567", "S24-01234"], []],
  ["Bà Lê Thị Hoa, SĐT 0912345678, email hoa.le@gmail.com, hộ chiếu C1234567, địa chỉ: 12 Lý Thường Kiệt, Hà Nội", ["Lê Thị Hoa", "0912345678", "hoa.le@gmail.com", "C1234567", "12 Lý Thường Kiệt"], []],
  ["Đại thể: Bệnh phẩm cắt thùy giáp phải kích thước 4 x 3 x 2 cm. Vi thể: carcinôm nhú tuyến giáp, biến thể nang. Hóa mô miễn dịch: CD20 (+), CD3 (-), Ki-67 80%. IDH1 p.R132H; đồng mất đoạn 1p/19q; pT1aN1b; BRAF V600E; ICD-O 8260/3. Tham khảo WHO 2021, Châu Âu, Hà Nội.", [], ["CD20", "Ki-67", "p.R132H", "1p/19q", "pT1aN1b", "V600E", "8260/3", "WHO 2021", "Châu Âu", "Hà Nội", "4 x 3 x 2 cm"]],
  ["The patient is a 62-year-old woman. Sections show diffuse large B-cell lymphoma, Hans classification non-GCB.", [], ["62-year-old", "Hans", "non-GCB"]],
  ["BN: Phạm Minh Tuấn, nam, NS 1978, số vào viện 24012345, tiêu bản B24.5678 nhuộm HE.", ["Phạm Minh Tuấn", "1978", "24012345", "B24.5678"], ["nhuộm HE"]],
];
for (const [text, gone, kept] of CASES) {
  const r = L.redactPHI(text);
  for (const g of gone) ok(!r.text.includes(g), `còn "${g}" trong: ${r.text}`);
  for (const k of kept) ok(r.text.includes(k), `mất "${k}" trong: ${r.text}`);
  ok(L.restorePHI(r.text, r.replacements) === text, 'khôi phục sai: ' + L.restorePHI(r.text, r.replacements));
  console.log(r.text);
}
ok(!L.redactPHI('Ca của Thầy Quang tại khoa X', ['Thầy Quang']).text.includes('Thầy Quang'), 'cụm tự che');

// Matcher
const g = JSON.parse(fs.readFileSync(new URL('../../ViPathTranslate/Resources/glossary.json', import.meta.url)));
const m = new L.GlossaryMatcher(g.entries);
const h = m.hits('Immunohistochemistry showed diffuse large B-cell lymphoma with high-power fields and 1p/19q codeletion.');
console.log('EN hits:', h.map((x) => `${x.matched} → ${x.translations[0]}`));
ok(h.length >= 2, 'EN matcher');
const vm = new L.VietnameseMatcher(g.entries);
const hv = vm.hits('Hoá mô miễn dịch cho thấy lymphôm tế bào B lớn lan tỏa.');
console.log('VI hits:', hv.map((x) => `${x.matched} → ${x.translations[0]}`));
ok(hv.length >= 2, 'VI matcher');
ok(L.guessDirection('Hoá mô miễn dịch cho thấy CD20 dương tính').id === 'viToEn', 'guess vi');
ok(L.guessDirection('The tumor cells are positive for CD20').id === 'enToVi', 'guess en');

// Sentences
const s = L.completeSentences('Markers (e.g. CD20, CD3) were tested. See Fig. 2 for details. Smith et al. reported this.');
ok(s.sentences.length === 3, 'sentences ' + JSON.stringify(s));
// Speech
const sp = L.normalizeSpeech('Đột biến IDH1 p.R132H; 1p/19q; pT1aN1b; BRAF V600E; CD20 dương tính');
console.log(sp);
ok(sp.includes('pê chấm rờ 132 hát') && sp.includes('xê đê 20') && sp.includes('1 pê, 19 quy'), 'speech');
// SRT
ok(L.srtTime(3723.5) === '01:02:03,500', 'srt time');
const seg = L.segmentText('Line one.\n\nLine two\nLine three');
ok(seg.length === 3 && seg[1].passthrough, 'segment');
ok(L.cleanOutput('<think>x</think>Xin chào<|im_end|>rác') === 'Xin chào', 'clean');
console.log(fails ? `\n${fails} lỗi` : '\nTất cả đạt');
process.exit(fails ? 1 : 0);
