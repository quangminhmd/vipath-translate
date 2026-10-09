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
// Máy chủ cục bộ
const hit = [{ matched: 'clear cell', translations: ['tế bào sáng'], ambiguous: false, notes: [] }];
const tg = L.localMessages('translategemma:27b', 'Clear cell carcinoma.', hit, L.DIR.enToVi);
ok(tg.length === 1 && tg[0].role === 'user' && tg[0].content.includes('English (en) to Vietnamese (vi)') && tg[0].content.includes('- clear cell → tế bào sáng') && tg[0].content.endsWith(':\n\n\nClear cell carcinoma.'), 'local tg ' + JSON.stringify(tg));
const hy = L.localMessages('hunyuan-mt-7b', 'Ung thư biểu mô.', [], L.DIR.viToEn);
ok(hy.length === 1 && hy[0].content === 'Translate the following segment into English, without additional explanation.\n\nUng thư biểu mô.', 'local hy ' + JSON.stringify(hy));
const qw = L.localMessages('qwen3:32b', 'x', [], L.DIR.enToVi);
ok(qw.length === 2 && qw[0].role === 'system', 'local chat');
ok(L.cleanOutput('Carcinoma.<|eos|>') === 'Carcinoma.', 'clean hunyuan');
// Đại thể — cùng bộ ca với Tools/test_gross.py (bản Swift)
const NM = [
  ['Bệnh phẩm kích thước bốn nhân ba nhân hai xăng ti mét, màu nâu', 'Bệnh phẩm kích thước 4 x 3 x 2 cm, màu nâu'],
  ['gồm ba mảnh, kích thước từ hai đến năm mi li mét', 'gồm 3 mảnh, kích thước từ 2 đến 5 mm'],
  ['u kích thước 4 nhân 3 nhân 2 cm', 'u kích thước 4 x 3 x 2 cm'],
  ['hai phẩy năm phân', '2,5 cm'], ['hai xăng ti mét rưỡi', '2,5 cm'], ['một khối u', '1 khối u'],
  ['nặng hai mươi lăm gam', 'nặng 25 g'], ['không có sỏi', 'không có sỏi'],
  ['cách diện cắt không phẩy năm xăng ti mét', 'cách diện cắt 0,5 cm'], ['4x3x2cm', '4 x 3 x 2 cm'], ['2.5 cm', '2,5 cm'],
  ['chiếm 30 phần trăm chu vi', 'chiếm 30% chu vi'], ['năm 2024 bệnh nhân', 'năm 2024 bệnh nhân'], ['mười hai hạch', '12 hạch'],
  ['một trăm linh năm gam', '105 g'], ['một đoạn đại tràng', 'một đoạn đại tràng'], ['ba tư gam', '34 g'],
  ['tumor measures 4 by 3 by 2 centimeters', 'tumor measures 4 x 3 x 2 cm'],
];
for (const [a, b] of NM) ok(L.normalizeMeasurements(a) === b, `measure "${a}" → "${L.normalizeMeasurements(a)}"`);
const PD = [
  ['Kích thước 4 cm. Xuống dòng.', 'text,newline'], ['Cát xét A1. Diện cắt gần.', 'cassette:A1,text'], ['cát xét a một mảnh u', 'cassette:A1,text'],
  ['mẫu bê hai', 'cassette:B2'], ['khối tiếp theo', 'nextCassette'], ['u màu trắng dấu phẩy chắc dấu chấm', 'text,punct,text,punct'],
  ['Xoá câu.', 'undo'], ['tạm dừng', 'pause'], ['Tiếp tục ghi.', 'resume'], ['cát xét số 3', 'cassette:3'], ['Cassette B12 tumor', 'cassette:B12,text'],
  ['mẫu bệnh phẩm gồm hai mảnh', 'text'], ['dấu hai chấm', 'punct'], ['cát xét c mười hai', 'cassette:C12'],
];
for (const [a, b] of PD) {
  const got = L.parseDictation(a).map((o) => (o.type === 'cassette' ? 'cassette:' + o.code : o.type)).join(',');
  ok(got === b, `parse "${a}" → ${got}`);
}
{
  const d = L.newGrossDoc();
  const say = (t, o) => L.applyDictation(d, L.parseDictation(t), o);
  say('Bệnh phẩm gồm một đoạn đại tràng dài hai mươi lăm xăng ti mét.');
  say('U dạng sùi kích thước bốn nhân ba nhân hai xăng ti mét.');
  say('Cách diện cắt xa năm xăng ti mét.');
  say('xoá câu');
  say('Cách diện cắt xa tám xăng ti mét. Xuống dòng.');
  say('Cát xét A1. Diện cắt gần và xa.');
  say('cát xét tiếp theo. U và thanh mạc sai rồi xoá câu');
  say('U và thanh mạc.');
  ok(JSON.stringify(say('tạm dừng')) === '["pause"]', 'pause signal');
  ok(JSON.stringify(say('nói chuyện riêng', { paused: true })) === '[]', 'ignored while paused');
  ok(JSON.stringify(say('tiếp tục ghi', { paused: true })) === '["resume"]', 'resume');
  say('quay lại mô tả. Mạc treo có mười hai hạch.');
  say('các xi nôm', { corrections: L.GROSS_DEFAULT_CORRECTIONS });
  const rep = L.grossReportText(d);
  const want = 'Bệnh phẩm gồm một đoạn đại tràng dài 25 cm. U dạng sùi kích thước 4 x 3 x 2 cm. Cách diện cắt xa 8 cm.\nMạc treo có 12 hạch. Carcinôm\n\nCẮT LỌC – CÁT XÉT:\nA1: Diện cắt gần và xa.\nA2: U và thanh mạc.';
  ok(rep === want, 'gross doc:\n' + rep);
}
console.log(fails ? `\n${fails} lỗi` : '\nTất cả đạt');
process.exit(fails ? 1 : 0);
