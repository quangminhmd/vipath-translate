// ViPath Web — phần logic thuần (không đụng DOM), bản JavaScript của các tệp Swift tương ứng.
// Kiểm thử: node Web/test/test_logic.mjs

// ---------- Chiều dịch ----------
export const DIR = {
  enToVi: { id: 'enToVi', label: 'Anh → Việt', source: 'Tiếng Anh', target: 'Tiếng Việt', src: 'en', tgt: 'vi' },
  viToEn: { id: 'viToEn', label: 'Việt → Anh', source: 'Tiếng Việt', target: 'Tiếng Anh', src: 'vi', tgt: 'en' },
};
export const reverseDir = (d) => (d.id === 'enToVi' ? DIR.viToEn : DIR.enToVi);

const VI_CHARS = new Set(
  'ăâđêôơưàáảãạằắẳẵặầấẩẫậèéẻẽẹềếểễệìíỉĩịòóỏõọồốổỗộờớởỡợùúủũụừứửữựỳýỷỹỵ' +
  'ĂÂĐÊÔƠƯÀÁẢÃẠẰẮẲẴẶẦẤẨẪẬÈÉẺẼẸỀẾỂỄỆÌÍỈĨỊÒÓỎÕỌỒỐỔỖỘỜỚỞỠỢÙÚỦŨỤỪỨỬỮỰỲÝỶỸỴ');

/** Đoán chiều dịch: ≥ 3% chữ cái mang dấu tiếng Việt → Việt → Anh. */
export function guessDirection(text) {
  let letters = 0, vi = 0;
  for (const ch of text.normalize('NFC').slice(0, 4000)) {
    if (/\p{L}/u.test(ch)) { letters++; if (VI_CHARS.has(ch)) vi++; }
  }
  if (letters < 3) return null;
  return vi / letters >= 0.03 ? DIR.viToEn : DIR.enToVi;
}

// ---------- Glossary: khớp thuật ngữ tiếng Anh ----------
const escRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function isAbbreviation(t) {
  if (t.includes(' ')) return false;
  const letters = [...t].filter((c) => /\p{L}/u.test(c));
  if (!letters.length) return false;
  const upper = letters.filter((c) => c === c.toUpperCase() && c !== c.toLowerCase()).length;
  return upper >= Math.max(2, letters.length * 0.6);
}

function termPattern(t) {
  const words = t.split(/[\s-]+/).filter(Boolean);
  let body = words.map(escRe).join('[\\s\\-]+');
  if (!isAbbreviation(t) && t.length >= 4) {
    const tail = body.slice(-2);
    if (body.endsWith('y') && !['ay', 'ey', 'oy', 'uy'].includes(tail)) body = body.slice(0, -1) + '(?:y|ies)';
    else if (!body.endsWith('s')) body += '(?:s|es)?';
  }
  return body;
}

/** Thuật ngữ bác sĩ đã duyệt (mục người dùng) thay thế mục gốc cùng khoá. */
const preferUser = (list) => { const u = list.filter((e) => e.isUser); return u.length ? u : list; };

export class GlossaryMatcher {
  constructor(entries) {
    const index = new Map(), ci = new Set(), cs = new Set();
    for (const e of entries) {
      for (const t of e.terms || []) {
        const abbr = isAbbreviation(t);
        const key = abbr ? t.replace(/[\s-]+/g, ' ') : t.replace(/[\s-]+/g, ' ').toLowerCase();
        if (!index.has(key)) index.set(key, []);
        index.get(key).push(e);
        (abbr ? cs : ci).add(t);
      }
    }
    for (const [k, v] of index) index.set(k, preferUser(v));
    this.index = index;
    const compile = (set, flags) => {
      if (!set.size) return null;
      const alts = [...set].sort((a, b) => b.length - a.length).map(termPattern).join('|');
      return new RegExp(`(?<![A-Za-z0-9])(?:${alts})(?![A-Za-z0-9])`, flags);
    };
    this.cs = compile(cs, 'g');
    this.ci = compile(ci, 'gi');
  }

  lookup(matched) {
    const norm = matched.replace(/[\s-]+/g, ' ');
    const low = norm.toLowerCase();
    const cands = [norm, low];
    if (low.endsWith('ies')) cands.push(low.slice(0, -3) + 'y');
    if (low.endsWith('es')) cands.push(low.slice(0, -2));
    if (low.endsWith('s')) cands.push(low.slice(0, -1));
    for (const c of cands) {
      if (this.index.has(c)) return this.index.get(c);
      const h = c.replace(/ /g, '-');
      if (this.index.has(h)) return this.index.get(h);
    }
    const flat = low.replace(/[\s-]/g, '');
    for (const [k, v] of this.index) {
      const kf = k.replace(/[\s-]/g, '').toLowerCase();
      if (kf === flat || kf + 's' === flat) return v;
    }
    return [];
  }

  hits(text) {
    const spans = [];
    for (const rx of [this.cs, this.ci]) {
      if (!rx) continue;
      rx.lastIndex = 0;
      let m;
      while ((m = rx.exec(text))) {
        const a = m.index, b = a + m[0].length;
        if (m[0].length === 0) { rx.lastIndex++; continue; }
        if (spans.some(([x, y]) => !(b <= x || a >= y))) continue;
        spans.push([a, b, m[0]]);
      }
    }
    spans.sort((p, q) => p[0] - q[0]);
    const seen = new Set(), out = [];
    for (const [, , s] of spans) {
      const entries = this.lookup(s).filter((e) => !seen.has(e.id) && seen.add(e.id));
      if (entries.length) out.push(makeHit(s, entries, false));
    }
    return out;
  }
}

function makeHit(matched, entries, reverse) {
  const tr = [];
  for (const e of entries) { const t = reverse ? e.en : e.vi; if (!tr.includes(t)) tr.push(t); }
  return {
    id: matched.toLowerCase(), matched, entries, reverse, translations: tr,
    ambiguous: tr.length > 1, notes: entries.map((e) => e.note).filter(Boolean),
  };
}

// ---------- Glossary: khớp thuật ngữ tiếng Việt (dịch Việt → Anh) ----------
const TONE_MOVES = (() => {
  const toned = { a: 'áàảãạ', e: 'éèẻẽẹ', y: 'ýỳỷỹỵ' };
  const lead = { a: 'óòỏõọ', e: 'óòỏõọ', y: 'úùủũụ' };
  const first = { a: 'o', e: 'o', y: 'u' };
  const out = [];
  for (const base of ['a', 'e', 'y']) for (let i = 0; i < 5; i++) out.push([first[base] + toned[base][i], lead[base][i] + base]);
  return out;
})();

/** Chữ thường, NFC, dấu thanh kiểu cũ (óa, óe, úy) — giữ nguyên độ dài chuỗi. */
export function viCanonical(s) {
  let t = s.normalize('NFC').toLowerCase();
  for (const [from, to] of TONE_MOVES) t = t.split(from).join(to);
  return t;
}

export function vietnameseTerms(e) {
  return e.vi.split(' / ').map((part) => part.replace(/\s*\([^)]*\)/g, '').trim()).filter((p) => {
    if (!p || p.toLowerCase().startsWith('giữ nguyên')) return false;
    if (p.split(/\s+/).length === 1 && [...p].length < 6) return false;   // bỏ "u", "ổ", "đám"…
    return true;
  });
}

export class VietnameseMatcher {
  constructor(entries) {
    const index = new Map();
    for (const e of entries) for (const t of vietnameseTerms(e)) {
      const k = viCanonical(t);
      if (!index.has(k)) index.set(k, []);
      index.get(k).push(e);
    }
    for (const [k, v] of index) index.set(k, preferUser(v));
    this.index = index;
    const alts = [...index.keys()].sort((a, b) => b.length - a.length).map((k) => escRe(k).replace(/ /g, '\\s+')).join('|');
    this.rx = alts ? new RegExp(`(?<![\\p{L}\\p{N}])(?:${alts})(?![\\p{L}\\p{N}])`, 'giu') : null;
  }

  hits(text) {
    if (!this.rx) return [];
    const nfc = text.normalize('NFC');
    const canon = viCanonical(nfc);
    const sameLen = canon.length === nfc.length;
    const seen = new Set(), out = [];
    this.rx.lastIndex = 0;
    let m;
    while ((m = this.rx.exec(canon))) {
      const key = viCanonical(m[0]).replace(/\s+/g, ' ');
      const entries = (this.index.get(key) || []).filter((e) => !seen.has(e.id) && seen.add(e.id));
      if (!entries.length) continue;
      const original = sameLen ? nfc.slice(m.index, m.index + m[0].length) : m[0];
      out.push(makeHit(original, entries, true));
    }
    return out;
  }
}

/** Thuật ngữ mà bản dịch KHÔNG dùng đúng như glossary. */
export function glossaryMissing(hits, output) {
  const out = output.toLowerCase();
  return hits.filter((hit) => {
    if (hit.reverse) {
      const opts = hit.entries.flatMap((e) => [...(e.terms || []), e.en]).map((s) => s.toLowerCase());
      return !opts.some((o) => out.includes(o));
    }
    const opts = hit.translations.flatMap((vi) => viVariants(vi, hit.matched));
    if (!opts.length) return false;
    return !opts.some((o) => out.includes(o.toLowerCase()));
  });
}

function viVariants(vi, source) {
  const out = [];
  for (const part of vi.split(' / ')) {
    const p = part.trim();
    if (p.toLowerCase().startsWith('giữ nguyên')) {
      const rest = p.slice('giữ nguyên'.length).replace(/^[\s"“”']+|[\s"“”']+$/g, '');
      out.push(rest || source);
      continue;
    }
    out.push(p);
    const np = p.replace(/\s*\([^)]*\)/g, '').trim();
    if (np !== p && np) out.push(np);
  }
  return out.filter(Boolean);
}

// ---------- Prompt ----------
export function glossaryBlock(hits, maxNote = 90) {
  return hits.map((h) => {
    let line = `- ${h.matched} → ${h.translations.join(' | ')}`;
    if (h.ambiguous) line += ' (chọn nghĩa hợp ngữ cảnh)';
    if (maxNote > 0 && h.notes[0]) line += ` — ${h.notes[0].slice(0, maxNote)}`;
    return line;
  }).join('\n');
}

export function systemPrompt(dir, styleGuide) {
  if (dir.id === 'enToVi') {
    return [
      'Bạn là biên dịch viên giải phẫu bệnh, dịch Anh → Việt.',
      '- Chỉ trả về bản dịch tiếng Việt, không giải thích.',
      '- Dùng đúng bản dịch trong mục THUẬT NGỮ.',
      '- Giữ nguyên tiếng Anh: tên gen, protein, kháng thể, dấu ấn (CD20, HER2, BRAF V600E), mã TNM, tên người.',
      '- Giữ nguyên số liệu, đơn vị, xuống dòng, gạch đầu dòng.',
      '- Văn phong giáo trình y khoa, chủ động, chính xác.',
    ].join('\n') + (styleGuide ? '\n' + styleGuide : '');
  }
  return [
    'You are an anatomic pathology translator, Vietnamese → English.',
    '- Output only the English translation, no explanations.',
    '- Use exactly the English terms given under TERMS.',
    '- Use standard English pathology terminology (WHO/CAP style).',
    '- Keep gene, protein, antibody and marker names, TNM codes and person names unchanged.',
    '- Keep numbers, units, line breaks and bullet points.',
  ].join('\n');
}

export function userPrompt(text, hits, dir) {
  if (dir.id === 'enToVi') {
    return (hits.length ? `THUẬT NGỮ (bắt buộc dùng):\n${glossaryBlock(hits)}\n\n` : '') + `Dịch sang tiếng Việt:\n\n${text}`;
  }
  return (hits.length ? `TERMS (must use):\n${glossaryBlock(hits)}\n\n` : '') + `Translate into English:\n\n${text}`;
}

/** Họ mô hình suy ra từ tên trên máy chủ cục bộ (Ollama / LM Studio). */
export function localFamily(model) {
  const m = String(model || '').toLowerCase();
  if (m.includes('translategemma')) return 'translateGemma';
  if (m.includes('hunyuan')) return 'hunyuanMT';
  return 'chat';
}

/**
 * Tin nhắn cho máy chủ cục bộ. TranslateGemma và Hunyuan-MT được huấn luyện với một tin nhắn user
 * duy nhất (không system prompt) → dựng đúng câu lệnh gốc, chèn khối thuật ngữ gọn.
 */
export function localMessages(model, text, hits, dir, styleGuide = '') {
  const fam = localFamily(model);
  const src = dir.id === 'enToVi' ? 'English' : 'Vietnamese';
  const tgt = dir.id === 'enToVi' ? 'Vietnamese' : 'English';
  const terms = hits.length ? glossaryBlock(hits, 0) : '';
  const body = text.trim();
  if (fam === 'translateGemma') {
    let s = `You are a professional ${src} (${dir.src}) to ${tgt} (${dir.tgt}) translator specialising in anatomical pathology. ` +
      `Your goal is to accurately convey the meaning and nuances of the original ${src} text while adhering to ${tgt} medical terminology.\n` +
      `Produce only the ${tgt} translation, without any additional explanations or commentary.\n` +
      'Keep gene, protein, antibody and marker names, TNM codes and person names unchanged.';
    if (terms) s += `\nUse exactly these ${tgt} terms:\n${terms}`;
    s += `\nPlease translate the following ${src} text into ${tgt}:\n\n\n${body}`;
    return [{ role: 'user', content: s }];
  }
  if (fam === 'hunyuanMT') {
    let s = `Translate the following segment into ${tgt}, without additional explanation.`;
    if (terms) s += ` Use these term translations:\n${terms}`;
    return [{ role: 'user', content: `${s}\n\n${body}` }];
  }
  return [{ role: 'system', content: systemPrompt(dir, styleGuide) }, { role: 'user', content: userPrompt(body, hits, dir) }];
}

/** Bỏ phần suy luận <think>…</think> và chuỗi dừng. */
export function cleanOutput(raw) {
  let t = raw.replace(/<think>[\s\S]*?<\/think>/g, '');
  const open = t.indexOf('<think>');
  if (open >= 0) t = t.slice(0, open);
  for (const m of ['<end_of_turn>', '<|im_end|>', '<eos>', '<|eos|>', '<|endoftext|>']) { const i = t.indexOf(m); if (i >= 0) t = t.slice(0, i); }
  return t.trim();
}

/** Tách văn bản thành đoạn ≤ maxChars; dòng trống / chỉ ký hiệu giữ nguyên. */
export function segmentText(text, maxChars = 900) {
  const out = [];
  let buf = [];
  const flush = () => { if (buf.length) { out.push({ id: out.length, text: buf.join('\n'), passthrough: false }); buf = []; } };
  for (const line of text.replace(/\r\n/g, '\n').split('\n')) {
    const tr = line.trim();
    if (!tr || ![...tr].some((c) => /\p{L}/u.test(c))) { flush(); out.push({ id: out.length, text: line, passthrough: true }); continue; }
    if (buf.join('\n').length + line.length > maxChars) flush();
    buf.push(line);
  }
  flush();
  return out;
}

// ---------- Tách câu (phụ đề / dịch khi gõ) ----------
const ABBR = new Set(['e.g', 'i.e', 'al', 'etc', 'fig', 'figs', 'dr', 'drs', 'prof', 'mr', 'mrs', 'ms', 'vs', 'approx',
  'no', 'nos', 'cf', 'st', 'ca', 'resp', 'vol', 'ref', 'refs', 'tab', 'eq', 'dept', 'univ', 'inc', 'ltd', 'jr', 'sr',
  'mt', 'min', 'max', 'pt', 'pts', 'bs', 'ts', 'ths', 'pgs', 'gs']);
const CLOSERS = '.!?)]"”’\'';

export function completeSentences(text) {
  const ch = [...text];
  const out = [];
  let start = 0, i = 0;
  const boundary = (dot, nxt) => {
    if (ch[dot] !== '.') return true;
    let j = dot - 1;
    while (j >= start && !/\s/.test(ch[j]) && ch[j] !== '(') j--;
    const word = ch.slice(j + 1, dot).join('').toLowerCase();
    if (ABBR.has(word)) return false;
    if (word.length === 1 && /\p{L}/u.test(word)) return false;
    let k = nxt;
    while (k < ch.length && /\s/.test(ch[k])) k++;
    if (k >= ch.length) return true;
    const n = ch[k];
    return /\p{Lu}/u.test(n) || /\d/.test(n) || '("“\'['.includes(n);
  };
  while (i < ch.length) {
    if ('.!?'.includes(ch[i])) {
      let end = i + 1;
      while (end < ch.length && CLOSERS.includes(ch[end])) end++;
      const atEnd = end >= ch.length;
      const sp = !atEnd && /\s/.test(ch[end]);
      if ((atEnd || sp) && boundary(i, end)) {
        const s = ch.slice(start, end).join('').trim();
        if (s) out.push(s);
        start = end;
      }
      i = end;
      continue;
    }
    i++;
  }
  return { sentences: out, rest: ch.slice(start).join('') };
}

export function splitSentences(text) {
  const { sentences, rest } = completeSentences(text);
  return rest.trim() ? [...sentences, rest.trim()] : sentences;
}

// ---------- Che thông tin định danh (bản JS của PHIRedactor.swift / Tools/test_redactor.py) ----------
export const PHI_KINDS = {
  'TÊN': 'Họ tên', 'PID': 'Mã bệnh nhân / hồ sơ', 'MÃ_BP': 'Mã bệnh phẩm', 'NGÀY_SINH': 'Ngày sinh', 'NGÀY': 'Ngày tháng',
  'GIẤY_TỜ': 'CCCD / CMND / hộ chiếu', 'SĐT': 'Số điện thoại', 'EMAIL': 'Email', 'ĐỊA_CHỈ': 'Địa chỉ', 'ẨN': 'Cụm tự che',
};
const FAMILIES = ['Nguyễn', 'Trần', 'Lê', 'Phạm', 'Hoàng', 'Huỳnh', 'Phan', 'Vũ', 'Võ', 'Đặng', 'Bùi', 'Đỗ', 'Hồ', 'Ngô',
  'Dương', 'Lý', 'Đinh', 'Đoàn', 'Lâm', 'Trương', 'Mai', 'Tô', 'Trịnh', 'Hà', 'Cao', 'Lưu', 'Châu', 'Tạ', 'Quách', 'Thái',
  'Lương', 'Tăng', 'Kiều', 'Triệu'];
const NOT_NAMES = ['Hà Nội', 'Hà Tĩnh', 'Hà Giang', 'Hà Nam', 'Châu Âu', 'Châu Á', 'Châu Phi', 'Châu Mỹ', 'Cao Bằng',
  'Thái Bình', 'Thái Nguyên', 'Hồ Chí Minh', 'Lâm Đồng', 'Đồng Nai'];
// Họ trùng từ thường (Cao = cao, Mai = ngày mai…) → cần đủ họ + 2 chữ
const AMBIGUOUS = ['Cao', 'Mai', 'Hà', 'Lý', 'Lâm', 'Thái', 'Tô', 'Châu', 'Tăng', 'Lương', 'Kiều', 'Hồ', 'Tạ', 'Lưu'];
// Ngày đứng sau các cụm này là ngày truy cập / cập nhật tài liệu, không phải định danh
const DOC_DATE_CUES = ['truy cập', 'cập nhật', 'ban hành', 'phiên bản', 'accessed', 'updated', 'published', 'retrieved', 'version'];
const CAP = '\\p{Lu}[\\p{Ll}\\p{M}]*';
const GAP = '[ \\t]+'; // tên không vắt qua dòng
const WB = '(?<![\\p{L}])'; // nhãn / danh xưng phải đứng đầu từ ("Không" không chứa "ông", "Mucoepidermoid" không chứa "PID")
const SEP = '\\s*[:：#]?\\s*';
// JS không có nhóm cờ (?i:…) → viết dạng [Tt]… cho nhãn trường cần phân biệt hoa thường ở phần giá trị
const STOP = '(?=\\s*(?:[\\n,;|]|\\s{2,}|$|\\s-\\s|\\s(?:[Tt]uổi|[Gg]iới|[Nn]am|[Nn]ữ|[Ss]inh|PID|[Mm]ã|[Aa]ge|[Ss]ex|DOB)(?![\\p{L}])))';
const NAME_VALUE = '(\\p{Lu}[^\\n,;|]{1,59}?)' + STOP;
const CODE = '([A-Za-z0-9][A-Za-z0-9\\-/\\.]{1,23}[A-Za-z0-9])';
/** Biến nhãn trường thành không phân biệt hoa thường (bỏ qua chuỗi thoát như \s). */
const ci = (src) => {
  let out = '';
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (c === '\\') { out += c + (src[i + 1] ?? ''); i++; continue; }
    out += c.toLowerCase() !== c.toUpperCase() ? `[${c.toLowerCase()}${c.toUpperCase()}]` : c;
  }
  return out;
};

const PHI_RULES = [
  ['TÊN', WB + ci('(?:họ\\s+và\\s+tên|họ\\s+tên|tên\\s+bệnh\\s+nhân|tên\\s+BN|bệnh\\s+nhân|BN|patient\'?s?\\s+name|patient|name)') + '\\s*[:：]\\s*' + NAME_VALUE, 'gu'],
  ['PID', WB + '(?:PID|mã\\s+BN|mã\\s+bệnh\\s+nhân|mã\\s+y\\s+tế|mã\\s+hồ\\s+sơ|số\\s+hồ\\s+sơ|số\\s+bệnh\\s+án|số\\s+vào\\s+viện|MRN|hospital\\s+(?:number|no\\.?)|medical\\s+record\\s+(?:number|no\\.?))' + SEP + CODE, 'giu'],
  ['MÃ_BP', WB + '(?:mã\\s+bệnh\\s+phẩm|mã\\s+GPB|số\\s+GPB|mã\\s+tiêu\\s+bản|số\\s+tiêu\\s+bản|mã\\s+mẫu|specimen\\s+(?:ID|number|no\\.?)|accession(?:\\s+(?:number|no\\.?))?|case\\s+(?:ID|number|no\\.?)|lab\\s+(?:ID|no\\.?))' + SEP + CODE, 'giu'],
  ['NGÀY_SINH', '(?<![\\p{L}])(?:ngày\\s+sinh|năm\\s+sinh|sinh\\s+ngày|sinh\\s+năm|NS|DOB|date\\s+of\\s+birth|born(?:\\s+on)?)' + SEP + '(\\d{1,2}[/\\-.]\\d{1,2}[/\\-.]\\d{2,4}|\\d{4}-\\d{2}-\\d{2}|(?:19|20)\\d{2})', 'giu'],
  ['ĐỊA_CHỈ', WB + '(?:địa\\s+chỉ|address)\\s*[:：]\\s*([^\\n]{3,120})', 'giu'],
  ['SĐT', WB + '(?:SĐT|SDT|điện\\s+thoại|phone|tel|mobile)' + SEP + '(\\+?\\d[\\d\\s.\\-]{7,14}\\d)', 'giu'],
  ['GIẤY_TỜ', WB + '(?:CCCD|CMND|CMT|căn\\s+cước|passport|hộ\\s+chiếu|ID\\s+card)(?:\\s+(?:số|no\\.?))?' + SEP + '([A-Z0-9]{6,12})', 'giu'],
  ['TÊN', WB + '(?:[Ôô]ng|[Bb]à|anh|[Cc]hị|cô|chú|bác|cháu|Mr\\.?|Mrs\\.?|Ms\\.?|Miss)' + GAP + '(' + CAP + '(?:' + GAP + CAP + '){0,4})', 'gu'],
  ['TÊN', WB + '((?:' + FAMILIES.filter((f) => !AMBIGUOUS.includes(f)).join('|') + ')(?:' + GAP + CAP + '){1,3})(?![\\p{L}])', 'gu'],
  ['TÊN', WB + '((?:' + [...AMBIGUOUS].sort().join('|') + ')(?:' + GAP + CAP + '){2,3})(?![\\p{L}])', 'gu'],
  ['EMAIL', '([A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,})', 'giu'],
  ['MÃ_BP', '(?<![A-Za-z0-9])([A-Z]{1,6}[\\-/]?\\d{2}[\\-/.]\\d{3,7})(?![A-Za-z0-9])', 'gu'],
  ['GIẤY_TỜ', '(?<![A-Za-z0-9])([A-Z]\\d{7,8})(?![A-Za-z0-9])', 'gu'],
  ['SĐT', '(?<![\\d])(\\+84\\s?\\d{9}|0\\d{9})(?![\\d])', 'gu'],
  ['GIẤY_TỜ', '(?<![\\d.,])(\\d{9}|\\d{12})(?![\\d.,])', 'gu'],
  ['NGÀY', '(?<![\\d/])(\\d{1,2}[/\\-.]\\d{1,2}[/\\-.](?:19|20)\\d{2}|(?:19|20)\\d{2}-\\d{2}-\\d{2})(?![\\d/])', 'gu'],
].map(([kind, src, flags]) => ({ kind, rx: new RegExp(src, flags + 'd') }));

export function redactPHI(input, extraTerms = []) {
  let text = input;
  const map = new Map(), counters = {};
  const ph = (value, kind) => {
    const key = value.trim().toLowerCase();
    if (map.has(key)) return map.get(key).placeholder;
    counters[kind] = (counters[kind] || 0) + 1;
    const p = `[${kind}_${counters[kind]}]`;
    map.set(key, { placeholder: p, original: value.trim(), kind });
    return p;
  };
  for (const raw of extraTerms) {
    const t = raw.trim();
    if (t.length < 2) continue;
    const p = ph(t, 'ẨN');
    text = text.replace(new RegExp(escRe(t), 'giu'), p);
  }
  for (const { kind, rx } of PHI_RULES) {
    rx.lastIndex = 0;
    const matches = [...text.matchAll(rx)];
    if (!matches.length) continue;
    let out = text;
    for (const m of matches.reverse()) {
      const span = m.indices && m.indices[1];
      if (!span) continue;
      const [s, e] = span;
      const raw = text.slice(s, e);
      const v = raw.trim();
      if (v.length < 2 || v.startsWith('[')) continue;
      if (kind === 'TÊN' && NOT_NAMES.some((n) => v === n || v.startsWith(n + ' '))) continue;
      if (kind === 'NGÀY' && DOC_DATE_CUES.some((c) => text.slice(Math.max(0, s - 24), s).toLowerCase().includes(c))) continue;
      const lead = raw.length - raw.trimStart().length, trail = raw.length - raw.trimEnd().length;
      out = out.slice(0, s + lead) + ph(v, kind) + out.slice(e - trail);
    }
    text = out;
  }
  const replacements = [...map.values()].sort((a, b) => a.placeholder.localeCompare(b.placeholder, 'vi', { numeric: true }));
  const counts = {};
  for (const r of replacements) counts[r.kind] = (counts[r.kind] || 0) + 1;
  return { text, replacements, counts };
}

export function restorePHI(text, replacements) {
  let out = text;
  for (const r of [...replacements].sort((a, b) => b.placeholder.length - a.placeholder.length)) out = out.split(r.placeholder).join(r.original);
  return out;
}

export const PLACEHOLDER_RX = /\[(?:TÊN|PID|MÃ_BP|NGÀY_SINH|NGÀY|GIẤY_TỜ|SĐT|EMAIL|ĐỊA_CHỈ|ẨN)_\d+\]/g;

// ---------- Đọc tiếng Việt: chuẩn hoá ký hiệu GPB (bản JS của GPBSpeechNormalizer.swift) ----------
const LN = { A: 'a', B: 'bê', C: 'xê', D: 'đê', E: 'e', F: 'ép', G: 'giê', H: 'hát', I: 'i', J: 'gi', K: 'ca', L: 'lờ', M: 'mờ',
  N: 'nờ', O: 'o', P: 'pê', Q: 'quy', R: 'rờ', S: 'ét', T: 'tê', U: 'u', V: 'vê', W: 'vê kép', X: 'ích', Y: 'i', Z: 'dét' };
const spell = (s) => [...s].map((c) => LN[c.toUpperCase()] ?? c).join(' ');
const spaced = (s) => {
  if (s === 'is') return 'i ét';
  const groups = [];
  let buf = '';
  for (const ch of s) {
    if (buf && /\d/.test(buf.at(-1)) !== /\d/.test(ch)) { groups.push(buf); buf = ''; }
    buf += ch;
  }
  if (buf) groups.push(buf);
  return groups.map((g) => (/\d/.test(g[0]) ? g : g === 'x' ? 'ích' : g)).join(' ');
};
const SB_L = '(?<![A-Za-z0-9])', SB_R = '(?![A-Za-z0-9])';
const SPEECH_RULES = [
  [new RegExp(SB_L + '(\\d{1,2})([pq])/(\\d{1,2})([pq])' + SB_R, 'g'), (m, a, b, c, d) => `${a} ${spell(b)}, ${c} ${spell(d)}`],
  [new RegExp(SB_L + 'p\\.([A-Z])(\\d+)([A-Z*])', 'g'), (m, a, n, b) => `pê chấm ${spell(a)} ${n} ${b === '*' ? 'dừng' : spell(b)}`],
  [new RegExp(SB_L + '(y?[pc]?)T(is|[0-4x][a-d]?)(N[0-3x][a-c]?)?(M[01x][a-c]?)?' + SB_R, 'g'), (m, pre, t, n, mm) => {
    const head = [...(pre ? [spell(pre)] : []), 'tê', spaced(t)].join(' ');
    const parts = [head];
    if (n) parts.push('nờ ' + spaced(n.slice(1)));
    if (mm) parts.push('mờ ' + spaced(mm.slice(1)));
    return parts.join(', ');
  }],
  [new RegExp(SB_L + '([A-Z])(\\d{2,4})([A-Z])' + SB_R, 'g'), (m, a, n, b) => `${spell(a)} ${n} ${spell(b)}`],
  [new RegExp(SB_L + '([A-Z]{2,5})(\\d{2,3})' + SB_R, 'g'), (m, a, n) => `${spell(a)} ${n}`],
];
export function normalizeSpeech(input) {
  let s = input;
  for (const [rx, fn] of SPEECH_RULES) s = s.replace(rx, fn);
  return s.replace(/×/g, ' nhân ').replace(/↑/g, ' tăng ').replace(/↓/g, ' giảm ');
}

// ---------- Phụ đề: định dạng thời gian và xuất ----------
export function srtTime(t, sep = ',') {
  const ms = Math.round(Math.max(0, t) * 1000);
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)}${sep}${p(ms % 1000, 3)}`;
}
export function clock(t) {
  const s = Math.floor(Math.max(0, t));
  const p = (n) => String(n).padStart(2, '0');
  return `${p(Math.floor(s / 3600))}:${p(Math.floor(s / 60) % 60)}:${p(s % 60)}`;
}
function segLines(s, content) {
  if (content === 'source') return s.text;
  if (content === 'translation') return s.translation || s.text;
  return s.translation ? `${s.text}\n${s.translation}` : s.text;
}
export function renderSubtitles(segments, format, content) {
  if (format === 'srt') return segments.map((s, i) => `${i + 1}\n${srtTime(s.start)} --> ${srtTime(s.end)}\n${segLines(s, content)}\n`).join('\n');
  if (format === 'vtt') return 'WEBVTT\n\n' + segments.map((s) => `${srtTime(s.start, '.')} --> ${srtTime(s.end, '.')}\n${segLines(s, content)}\n`).join('\n');
  return segments.map((s) => `[${clock(s.start)}] ${segLines(s, content)}`).join('\n');
}
export function plainSubtitles(segments, content) {
  return content === 'bilingual'
    ? segments.map((s) => segLines(s, 'bilingual')).join('\n\n')
    : segments.map((s) => segLines(s, content)).join(' ');
}

/** Ghép các đoạn Whisper (timestamp [s, e]) thành đoạn phụ đề, cộng độ lệch cửa sổ. */
export function whisperChunksToSegments(chunks, offset, windowEnd) {
  const out = [];
  for (const c of chunks || []) {
    const text = (c.text || '').replace(/<\|[^|>]*\|>/g, '').replace(/\s+/g, ' ').trim();
    if (!text || !/[\p{L}\p{N}]/u.test(text)) continue;
    const [s, e] = c.timestamp || [0, null];
    const start = offset + Math.max(0, s ?? 0);
    const end = Math.min(windowEnd, Math.max(start + 0.5, offset + (e ?? (s ?? 0) + 3)));
    out.push({ start, end, text });
  }
  return out;
}

// ============================================================================
// Đọc mô tả đại thể (phẫu tích – cắt lọc bệnh phẩm) bằng giọng nói
// Bản Swift tương ứng: ViPathTranslate/GrossDictation.swift — giữ hai bản giống nhau.
// ============================================================================
const GW_L = '(?<![\\p{L}\\p{N}])', GW_R = '(?![\\p{L}\\p{N}])';

/** Từ chỉ số đếm tiếng Việt (đọc số đo). */
const VI_DIGIT = { 'không': 0, 'một': 1, 'mốt': 1, 'hai': 2, 'ba': 3, 'bốn': 4, 'tư': 4, 'năm': 5, 'lăm': 5, 'sáu': 6, 'bảy': 7, 'bẩy': 7, 'tám': 8, 'chín': 9 };
const VI_NUMWORDS = new Set([...Object.keys(VI_DIGIT), 'mười', 'mươi', 'linh', 'lẻ', 'trăm', 'rưỡi']);
/** Không thể đứng đầu một số. */
const VI_NOT_FIRST = new Set(['mốt', 'lăm', 'tư', 'linh', 'lẻ', 'mươi', 'trăm', 'rưỡi']);

/** "hai mươi lăm" → 25, "một trăm linh năm" → 105, "ba tư" → 34 (cách nói tắt). */
export function viNumber(words) {
  let group = 0, pending = null;
  for (const w of words) {
    if (w in VI_DIGIT) {
      const d = VI_DIGIT[w];
      if (pending !== null) { group += pending * 10 + d; pending = null; } else pending = d;
    } else if (w === 'mười') { group += 10; pending = null; }
    else if (w === 'mươi') { group += (pending ?? 1) * 10; pending = null; }
    else if (w === 'trăm') { group += (pending ?? 1) * 100; pending = null; }
  }
  return group + (pending ?? 0);
}

/** Đơn vị đọc → ký hiệu. Thứ tự: cụm dài trước. */
const GROSS_UNITS = [
  [['xăng', 'ti', 'mét'], 'cm'], [['xen', 'ti', 'mét'], 'cm'], [['xăng', 'ti'], 'cm'], [['xen', 'ti'], 'cm'],
  [['centimet'], 'cm'], [['centimét'], 'cm'], [['cm'], 'cm'], [['phân'], 'cm'],
  [['centimeters'], 'cm'], [['centimeter'], 'cm'], [['millimeters'], 'mm'], [['millimeter'], 'mm'],
  [['mi', 'li', 'mét'], 'mm'], [['mi', 'li', 'lít'], 'ml'], [['ki', 'lô', 'gam'], 'kg'],
  [['milimet'], 'mm'], [['milimét'], 'mm'], [['mm'], 'mm'], [['mi', 'li'], 'mm'], [['li'], 'mm'], [['ly'], 'mm'],
  [['kilôgam'], 'kg'], [['kg'], 'kg'], [['ký'], 'kg'], [['ki', 'lô'], 'kg'],
  [['gờ', 'ram'], 'g'], [['gam'], 'g'], [['gram'], 'g'], [['grams'], 'g'], [['g'], 'g'],
  [['ml'], 'ml'], [['phần', 'trăm'], '%'], [['%'], '%'], [['percent'], '%'],
];
/** Danh từ đếm: "ba mảnh" → "3 mảnh". */
const GROSS_COUNT_NOUNS = new Set(['mảnh', 'hạch', 'lát', 'nốt', 'khối', 'polyp', 'sỏi', 'viên', 'pieces', 'fragments', 'nodes']);
const GROSS_TIMES = new Set(['nhân', 'x', '×', 'by']);
const GROSS_RANGE = new Set(['đến', 'tới', '-', '–', 'to']);

const isDigitTok = (t) => /^\d+(?:[.,]\d+)?$/.test(t);
function unitAt(lw, i) {
  for (const [seq, sym] of GROSS_UNITS) {
    if (seq.every((w, k) => lw[i + k] === w)) return { len: seq.length, sym };
  }
  return null;
}
function joinTokens(toks) {
  let out = '';
  for (const t of toks) {
    if (!out) out = t;
    else if (/^[.,;:!?)%]/.test(t) || out.endsWith('(')) out += t;
    else out += ' ' + t;
  }
  return out;
}

/**
 * Chuẩn hoá số đo trong một câu đọc: "bốn nhân ba nhân hai xăng ti mét" → "4 x 3 x 2 cm",
 * "hai phẩy năm phân" → "2,5 cm", "ba mảnh" → "3 mảnh", "hai xăng ti mét rưỡi" → "2,5 cm".
 * Chỉ đổi chữ số khi đứng cạnh đơn vị / "nhân" / danh từ đếm → "một khối u" vẫn giữ nguyên.
 */
export function normalizeMeasurements(input) {
  let s = input.normalize('NFC')
    .replace(/(xăng|xen|mi)-(ti|li)-(mét|lít)/giu, '$1 $2 $3').replace(/ki-lô-gam/giu, 'ki lô gam')
    .replace(/×/g, ' x ')
    .replace(/(\d)(?=(?:cm|mm|kg|ml|g)(?![\p{L}\p{N}]))/gu, '$1 ')
    .replace(/(\d)\s*[xX](?=\s*\d)/g, '$1 x ');
  const toks = s.match(/[\p{L}\p{M}]+|\d+(?:[.,]\d+)?|%|[^\s\p{L}\p{M}\d]/gu) || [];
  const lw = toks.map((t) => t.toLowerCase());
  const isNum = (i) => isDigitTok(lw[i]) || VI_NUMWORDS.has(lw[i]);

  // 1) Tìm các cụm số
  const spans = [];
  for (let i = 0; i < toks.length;) {
    if (!isNum(i) || VI_NOT_FIRST.has(lw[i])) { i++; continue; }
    let j = i, comma = -1;
    while (j < toks.length) {
      if (isNum(j)) { j++; continue; }
      if (lw[j] === 'phẩy' && comma < 0 && j + 1 < toks.length && isNum(j + 1) && !VI_NOT_FIRST.has(lw[j + 1])) { comma = j; j++; continue; }
      break;
    }
    // "không" đứng một mình là phủ định, không phải số 0
    if (!(j - i === 1 && lw[i] === 'không')) spans.push({ start: i, end: j, comma, conv: false });
    i = j;
  }
  // 2) Đánh dấu cụm cần đổi
  for (const sp of spans) {
    const u = unitAt(lw, sp.end);
    if (u) { sp.unit = u; sp.conv = true; } else if (GROSS_COUNT_NOUNS.has(lw[sp.end])) sp.conv = true;
  }
  for (let changed = true; changed;) {
    changed = false;
    for (let k = 0; k + 1 < spans.length; k++) {
      const a = spans[k], b = spans[k + 1];
      if (b.start !== a.end + 1) continue;
      const link = lw[a.end];
      const times = GROSS_TIMES.has(link), range = GROSS_RANGE.has(link);
      if (!times && !range) continue;
      // "nhân" giữa hai số luôn là phép nhân kích thước; "đến" chỉ khi một bên đã là số đo
      const want = times ? true : (a.conv || b.conv);
      if (want && (!a.conv || !b.conv)) { a.conv = b.conv = true; changed = true; }
      if (times) a.times = true;
    }
  }
  // 3) Dựng lại câu
  const value = (words) => {
    const half = words[words.length - 1] === 'rưỡi';
    if (half) words = words.slice(0, -1);
    const str = words.length === 1 && isDigitTok(words[0]) ? words[0].replace('.', ',') : String(viNumber(words));
    return { str, half };
  };
  const out = [];
  let i = 0;
  for (const sp of spans) {
    while (i < sp.start) out.push(toks[i++]);
    if (!sp.conv) { while (i < sp.end) out.push(toks[i++]); continue; }
    const intW = lw.slice(sp.start, sp.comma >= 0 ? sp.comma : sp.end);
    const fracW = sp.comma >= 0 ? lw.slice(sp.comma + 1, sp.end) : null;
    const iv = value(intW);
    let num = iv.str;
    if (fracW) num += ',' + value(fracW).str;
    i = sp.end;
    let unitSym = null;
    if (sp.unit) { unitSym = sp.unit.sym; i += sp.unit.len; }
    if ((iv.half || (unitSym && lw[i] === 'rưỡi')) && !num.includes(',')) { num += ',5'; if (lw[i] === 'rưỡi') i++; }
    out.push(num);
    if (unitSym) out.push(unitSym);
    if (sp.times) { out.push('x'); i++; }
  }
  while (i < toks.length) out.push(toks[i++]);
  return joinTokens(out);
}

/** Sửa lỗi nhận dạng theo danh sách {from, to} (không phân biệt hoa thường, nguyên cụm từ). */
export function applyCorrections(text, list) {
  let s = text.normalize('NFC');
  for (const { from, to } of list || []) {
    const f = String(from || '').trim();
    if (!f) continue;
    const rx = new RegExp(GW_L + f.normalize('NFC').split(/\s+/).map(escRe).join('\\s+') + GW_R, 'giu');
    s = s.replace(rx, to);
  }
  return s;
}

/** Ví dụ sửa lỗi ban đầu — bác sĩ thêm / sửa theo lỗi gặp thực tế. */
export const GROSS_DEFAULT_CORRECTIONS = [
  { from: 'các xi nôm', to: 'carcinôm' }, { from: 'cát xi nôm', to: 'carcinôm' },
  { from: 'xa côm', to: 'sarcôm' }, { from: 'lim phôm', to: 'lymphôm' },
  { from: 'pô líp', to: 'polyp' }, { from: 'pô lyp', to: 'polyp' },
];

/** Từ vựng đại thể gợi ý cho bộ nhận dạng (contextual strings). */
export const GROSS_VOCAB = [
  'đại thể', 'cắt lọc', 'cát xét', 'bệnh phẩm', 'mảnh mô', 'mô mềm', 'mô mỡ', 'nhu mô', 'vỏ bao', 'thanh mạc', 'niêm mạc',
  'dưới niêm mạc', 'lớp cơ', 'mạc treo', 'mạc nối', 'diện cắt', 'bờ phẫu thuật', 'diện cắt gần', 'diện cắt xa', 'diện cắt quanh',
  'chấm mực', 'mực tàu', 'mực xanh', 'mực đen', 'mực đỏ', 'mặt cắt', 'mật độ', 'chắc', 'mềm', 'bở', 'dai', 'xơ', 'nhầy', 'dạng keo',
  'dạng nang', 'dạng nhú', 'dạng sùi', 'loét', 'thâm nhiễm', 'xâm nhập', 'hoại tử', 'xuất huyết', 'vôi hoá', 'sỏi', 'giả mạc',
  'hạch', 'hạch bạch huyết', 'polyp', 'cuống', 'không cuống', 'u', 'khối u', 'nốt', 'giới hạn rõ', 'giới hạn không rõ',
  'màu trắng xám', 'màu vàng', 'màu nâu', 'màu đỏ sẫm', 'carcinôm', 'sarcôm', 'lymphôm', 'tuyến giáp', 'túi mật', 'ruột thừa',
  'đại tràng', 'trực tràng', 'dạ dày', 'tử cung', 'cổ tử cung', 'nội mạc', 'buồng trứng', 'vòi trứng', 'tuyến vú', 'núm vú',
  'hố nách', 'thận', 'tuyến tiền liệt', 'cố định formol', 'cắt lọc toàn bộ', 'đại diện', 'xăng ti mét', 'mi li mét', 'gam',
];

// ---------- Lệnh giọng nói ----------
const GROSS_LETTER = {
  'ép phờ': 'F', 'bê': 'B', 'bờ': 'B', 'xê': 'C', 'cê': 'C', 'cờ': 'C', 'đê': 'D', 'dê': 'D', 'đờ': 'D',
  'giê': 'G', 'gờ': 'G', 'hát': 'H', 'ép': 'F', 'ca': 'K', 'a': 'A', 'b': 'B', 'c': 'C', 'd': 'D', 'e': 'E', 'ê': 'E',
  'f': 'F', 'g': 'G', 'h': 'H', 'i': 'I', 'k': 'K',
  // biến thể bộ nhận dạng hay viết: "Á 1", "à một", "bi hai" (đọc kiểu Anh)…
  'á': 'A', 'à': 'A', 'ả': 'A', 'ã': 'A', 'ạ': 'A', 'â': 'A', 'ă': 'A', 'ây': 'A', 'bi': 'B', 'si': 'C', 'xi': 'C', 'đi': 'D',
};
/** "cát xét" và các cách bộ nhận dạng hay viết sai: các xét, cát sét, ca-xét, cassette, khối nến… */
// Whisper/PhoWhisper còn viết: "cắt xét", "cách xét", "cắt xe,", "khắc sét"… (quan sát thực tế)
/** Từ khoá pathcode, kể cả cách bộ nhận dạng hay viết sai ("mã k", "mã cà", "mả ca"…). */
const CODE_KW_RX = '(?:m[ãảạá]\\s+(?:ca|cà|cá|cả|cạ|ka|kha|k)|mã\\s+bệnh\\s+phẩm|mã\\s+giải\\s+phẫu\\s+bệnh|pathcode|path\\s+code|case\\s+number)(?:\\s+là)?';
const CASS_RX = '(?:(?:c|k|kh)[aáàảãạăắằẳẵặâấầẩẫậ](?:t|c|ch)?[\\s,-]*[xs][eéèẻẽẹêếềểễệ](?:t|c)?|cass?ett?e|khối\\s+nến|khuôn\\s+nến|block|blốc)';
const LET_RX = Object.keys(GROSS_LETTER).sort((a, b) => b.length - a.length).map((k) => k.replace(' ', '\\s+')).join('|');
const NUMW_RX = '(?:một|mốt|hai|ba|bà|bá|bả|bốn|tư|năm|lăm|sáu|bảy|bẩy|tám|chín|mười|mươi|linh|lẻ|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)';
const NUM_RX = `(\\d{1,2}|${NUMW_RX}(?:\\s+${NUMW_RX})*)`;
const EN_NUM = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12 };
const NUM_FIX = { 'bà': 'ba', 'bá': 'ba', 'bả': 'ba' };   // Whisper hay viết "a bà" cho "a ba"
function cassetteNumber(s) {
  const w = s.toLowerCase().trim().split(/\s+/).map((x) => NUM_FIX[x] || x);
  if (/^\d+$/.test(w[0])) return parseInt(w[0], 10);
  if (w.length === 1 && w[0] in EN_NUM) return EN_NUM[w[0]];
  return viNumber(w);
}
const cmd = (src) => new RegExp(GW_L + src + GW_R, 'iu');
/** Thứ tự quan trọng: cụm dài trước ("dấu hai chấm" trước "dấu chấm"). */
const GROSS_COMMANDS = [
  // "ca mới" / "chuyển ca" / "ca tiếp theo" [, mã ca …] → lưu ca đang đọc, mở ca mới
  [cmd('(?:(?:(?:chuyển|sang|bắt\\s+đầu|mở)\\s+)?ca\\s+(?:mới|tiếp(?:\\s+theo)?|kế(?:\\s+tiếp)?)|chuyển\\s+ca|new\\s+case|next\\s+case)'
    + `(?:[\\s,.:]+${CODE_KW_RX}[\\s:]+(.+)$)?`),
   (m) => ({ type: 'newCase', code: m[1] ? spokenCode(m[1]) : '' })],
  [cmd(`${CODE_KW_RX}[\\s:]+(.+)$`), (m) => ({ type: 'pathcode', code: spokenCode(m[1]) })],
  [cmd(`${CASS_RX}[\\s,]+(?:số\\s+|number\\s+)?(?:(${LET_RX})[\\s,-]*)?${NUM_RX}(?:[\\s,]+là(?=\\s|$))?`), (m) => ({ type: 'cassette', code: (m[1] ? GROSS_LETTER[m[1].toLowerCase().replace(/\s+/g, ' ')] : '') + cassetteNumber(m[2]) })],
  [cmd(`mẫu\\s+(${LET_RX})\\s*-?\\s*${NUM_RX}(?:\\s+là(?=\\s|$))?`), (m) => ({ type: 'cassette', code: GROSS_LETTER[m[1].toLowerCase().replace(/\s+/g, ' ')] + cassetteNumber(m[2]) })],
  [cmd(`(?:${CASS_RX}|khối|mẫu)\\s+(?:tiếp(?:\\s+theo)?|kế\\s+tiếp|next)|next\\s+(?:cassette|block)`), () => ({ type: 'nextCassette' })],
  [cmd('(?:quay\\s+(?:lại|về)|về|trở\\s+lại)\\s+(?:phần\\s+)?mô\\s+tả|phần\\s+mô\\s+tả|back\\s+to\\s+description'), () => ({ type: 'body' })],
  [cmd('dấu\\s+chấm\\s+phẩy|semicolon'), () => ({ type: 'punct', text: ';' })],
  [cmd('dấu\\s+hai\\s+chấm|colon'), () => ({ type: 'punct', text: ':' })],
  [cmd('dấu\\s+chấm\\s+hỏi|question\\s+mark'), () => ({ type: 'punct', text: '?' })],
  [cmd('dấu\\s+chấm|chấm\\s+câu|full\\s+stop|period'), () => ({ type: 'punct', text: '.' })],
  [cmd('dấu\\s+phẩy|comma'), () => ({ type: 'punct', text: ',' })],
  [cmd('mở\\s+ngoặc|open\\s+(?:paren|parenthesis|bracket)'), () => ({ type: 'punct', text: '(' })],
  [cmd('đóng\\s+ngoặc|close\\s+(?:paren|parenthesis|bracket)'), () => ({ type: 'punct', text: ')' })],
  [cmd('gạch\\s+đầu\\s+dòng|bullet'), () => ({ type: 'bullet' })],
  // "XXX ne ne Ex Ex Ex": cách bộ nhận dạng iPhone đã viết "xuống dòng" (quan sát thực tế)
  [cmd('xuống\\s+(?:dòng|giòng|ròng)|xxx(?:\\s+(?:ne|ex))*|new\\s+line'), () => ({ type: 'newline' })],
  [cmd('đoạn\\s+mới|sang\\s+đoạn(?:\\s+mới)?|new\\s+paragraph'), () => ({ type: 'para' })],
  [cmd('(?:xoá|xóa)\\s+câu(?:\\s+(?:cuối|vừa\\s+rồi|trước))?|hoàn\\s+tác|scratch\\s+that|undo\\s+that'), () => ({ type: 'undo' })],
  [cmd('tạm\\s+dừng(?:\\s+ghi)?|pause\\s+dictation'), () => ({ type: 'pause' })],
  [cmd('tiếp\\s+tục\\s+ghi|ghi\\s+tiếp|resume\\s+dictation'), () => ({ type: 'resume' })],
  [cmd('(?:dừng|kết\\s+thúc)\\s+ghi(?:\\s+âm)?|stop\\s+dictation'), () => ({ type: 'stop' })],
];

// ---------- Pathcode đọc bằng giọng: "gê pê bê hai bốn gạch không một hai" → "GPB24-012" ----------
const CODE_LETTER = { ...GROSS_LETTER, 'gê': 'G', 'pê': 'P', 'pờ': 'P', 'ét': 'S', 'ét xì': 'S', 'xờ': 'S', 'en': 'N', 'nờ': 'N', 'em': 'M', 'mờ': 'M',
  'o': 'O', 'ô': 'O', 'quy': 'Q', 'rờ': 'R', 'e rờ': 'R', 'tê': 'T', 'tờ': 'T', 'u': 'U', 'vê': 'V', 'vờ': 'V', 'ích': 'X', 'ích xì': 'X', 'i dài': 'Y', 'dét': 'Z', 'ka': 'K', 'lờ': 'L', 'e lờ': 'L', 'gi': 'J' };
const CODE_DIGIT = { 'không': '0', 'linh': '0', 'một': '1', 'mốt': '1', 'hai': '2', 'ba': '3', 'bốn': '4', 'tư': '4', 'năm': '5', 'lăm': '5', 'sáu': '6', 'bảy': '7', 'bẩy': '7', 'tám': '8', 'chín': '9',
  zero: '0', oh: '0', one: '1', two: '2', three: '3', four: '4', five: '5', six: '6', seven: '7', eight: '8', nine: '9' };
export function spokenCode(raw) {
  const w = raw.normalize('NFC').toLowerCase().replace(/[.,;:!?]+$/u, '').split(/\s+/).filter(Boolean);
  let out = '';
  for (let i = 0; i < w.length; i++) {
    const two = i + 1 < w.length ? w[i] + ' ' + w[i + 1] : null;
    if (two && CODE_LETTER[two]) { out += CODE_LETTER[two]; i++; continue; }
    const t = w[i];
    if (t === 'gạch' || t === 'ngang' || t === 'dash' || t === '-') { if (two === 'gạch ngang') i++; out += '-'; continue; }
    if (t === 'mươi' || t === 'mười' || t === 'trăm') continue;   // pathcode đọc từng chữ số
    if (t in CODE_DIGIT) { out += CODE_DIGIT[t]; continue; }
    if (CODE_LETTER[t]) { out += CODE_LETTER[t]; continue; }
    out += t.replace(/[^\p{L}\p{N}\-\/]/gu, '').toUpperCase();
  }
  return out;
}

// Lệnh bị cắt đôi ở chỗ ngừng nói: "mã ca" | (ngừng) | "bốn không không một".
const DANGLING_CODE_RX = new RegExp(GW_L + '(' + CODE_KW_RX + ')[\\s,.:;]*$', 'iu');
const DANGLING_CASS_RX = new RegExp('(?:^|[.,;:]\\s*)(' + CASS_RX + ')[\\s,.:;]*$', 'iu');
/** Tách phần lệnh còn dở ở cuối câu → { keep, carry }; carry được ghép vào đầu đoạn sau. */
export function splitDangling(text) {
  const s = (text || '').normalize('NFC');
  for (const r of [DANGLING_CODE_RX, DANGLING_CASS_RX]) {
    const m = r.exec(s);
    if (m && m[1]) {
      const at = m.index + m[0].indexOf(m[1]);
      return { keep: s.slice(0, at).trim(), carry: m[1] };
    }
  }
  return { keep: s, carry: '' };
}

/** Tách một câu đọc thành văn bản và lệnh. */
export function parseDictation(input) {
  const ops = [];
  let rest = input.normalize('NFC');
  for (;;) {
    let best = null;
    for (const [rx, make] of GROSS_COMMANDS) {
      const m = rx.exec(rest);
      if (m && (!best || m.index < best.m.index || (m.index === best.m.index && m[0].length > best.m[0].length))) best = { m, make };
    }
    if (!best) break;
    const op = best.make(best.m);
    let before = rest.slice(0, best.m.index);
    // dấu câu tự thêm của bộ nhận dạng ngay trước lệnh dấu câu → bỏ (lệnh thay thế nó)
    if (op.type === 'punct') before = before.replace(/[\s.,;:!?]+$/u, '');
    before = before.replace(/^[\s.,;:]+/u, '');
    if (before.trim()) ops.push({ type: 'text', text: before.trim() });
    ops.push(op);
    // dấu câu tự thêm ngay sau lệnh → bỏ
    rest = rest.slice(best.m.index + best.m[0].length).replace(/^[\s.,;:!?]+/u, '');
  }
  rest = rest.replace(/^[\s.,;:]+/u, '');
  if (rest.trim()) ops.push({ type: 'text', text: rest.trim() });
  return ops;
}

// ---------- Văn bản đại thể ----------
export function newGrossDoc(pathcode = '') { return { body: '', cassettes: [], target: -1, history: [], pathcode, oneShot: false }; }
const grossSnapshot = (d) => ({ body: d.body, cassettes: d.cassettes.map((c) => ({ ...c })), target: d.target, pathcode: d.pathcode || '', oneShot: !!d.oneShot });
/** Mã cát xét đầy đủ: "GPB-24-012345-A1" (có pathcode) hoặc "A1". */
export const cassetteLabel = (c) => (c.pathcode ? `${c.pathcode}-${c.code}` : c.code);
/** Ghi chú "(A1)" vào mô tả tại chỗ đang đọc — đặt trước dấu câu cuối nếu có. */
function appendMarker(prev, code) {
  const t = prev.replace(/\s+$/, '');
  if (!t) return prev;
  const tail = prev.slice(t.length);   // giữ xuống dòng phía sau
  // câu mô tả kết thúc tại lệnh cát xét → "… xanh (A1)." (dấu phẩy / không dấu → dấu chấm)
  const m = /([.,;:!?])$/.exec(t);
  const mark = m && m[1] !== ',' && m[1] !== ';' ? m[1] : '.';
  return `${m ? t.slice(0, -1) : t} (${code})${mark}` + tail;
}
/** Đổi pathcode của ca: cát xét đang mang pathcode cũ (hoặc chưa có) đổi theo. */
export function setGrossPathcode(doc, code) {
  const old = doc.pathcode || '';
  doc.pathcode = code;
  for (const c of doc.cassettes) if (!c.pathcode || c.pathcode === old) c.pathcode = code;
}
const isSentenceEnd = (s) => /(^|[.!?:\n])\s*$/.test(s);
function appendText(prev, piece) {
  if (!piece) return prev;
  let p = piece;
  if (!prev.trim() || isSentenceEnd(prev)) p = p.charAt(0).toUpperCase() + p.slice(1);
  else if (/^\p{Lu}\p{Ll}/u.test(p)) p = p.charAt(0).toLowerCase() + p.slice(1);   // bộ nhận dạng viết hoa đầu mỗi lượt
  if (!prev) return p;
  if (/[\s(]$/.test(prev) || /^[.,;:!?)%]/.test(p)) return prev + p;
  return prev + ' ' + p;
}
function appendPunct(prev, mark) {
  if (mark === '(') return prev.replace(/\s*$/, prev.trim() ? ' (' : '(');
  const t = prev.replace(/[\s]+$/, '');
  if (/[.,;:]$/.test(t) && mark !== ')') return t.slice(0, -1) + mark;
  return t + mark;
}
function nextCode(doc) {
  const last = doc.cassettes[doc.cassettes.length - 1]?.code;
  if (!last) return 'A1';
  const m = /^([A-Z]*)(\d+)$/.exec(last);
  return m ? m[1] + (parseInt(m[2], 10) + 1) : last + '1';
}

/**
 * Áp các lệnh của MỘT câu đọc vào văn bản. Trả về tín hiệu điều khiển ('pause' | 'resume' | 'stop'
 * | { newCase: <ảnh chụp ca vừa kết thúc> } — bộ điều khiển lưu ca đó).
 * `paused`: đang tạm dừng → chỉ nhận lệnh "tiếp tục ghi".
 */
export function applyDictation(doc, ops, { paused = false, corrections = [], cassetteReturn = true, inlineMarker = true } = {}) {
  const signals = [];
  let snap = grossSnapshot(doc), pushed = false, textSnap = null, gotNote = false;
  // Mở cát xét khi đang đọc mô tả: phần ghi chú cát xét được tách riêng, xong câu thì quay lại mô tả
  const openCassette = (code) => {
    // đang ở mô tả, hoặc vừa ghi chú một cát xét khác trong cùng mạch → mã vẫn vào mô tả
    if (doc.target >= 0) doc.cassettes[doc.target].text = doc.cassettes[doc.target].text.replace(/\s*[,;]\s*$/, '.');   // khép ghi chú trước
    if ((doc.target < 0 || doc.oneShot) && inlineMarker) doc.body = appendMarker(doc.body, code);
    const pc = doc.pathcode || '';
    const k = doc.cassettes.findIndex((c) => c.code === code && (c.pathcode || '') === pc);
    if (k >= 0) doc.target = k; else { doc.cassettes.push({ code, text: '', pathcode: pc }); doc.target = doc.cassettes.length - 1; }
    doc.oneShot = cassetteReturn; gotNote = false;
  };
  // ghi chú cát xét đã có chữ → khép lại, quay về mô tả
  const closeNote = () => {
    if (doc.oneShot && doc.target >= 0 && doc.cassettes[doc.target].text.trim()) { doc.target = -1; doc.oneShot = false; gotNote = false; }
  };
  const remember = () => { if (!pushed) { doc.history.push(snap); if (doc.history.length > 50) doc.history.shift(); pushed = true; } };
  const get = () => (doc.target < 0 ? doc.body : doc.cassettes[doc.target].text);
  const set = (v) => { if (doc.target < 0) doc.body = v; else doc.cassettes[doc.target].text = v; };
  for (const op of ops) {
    if (paused) { if (op.type === 'resume') { paused = false; signals.push('resume'); } continue; }
    switch (op.type) {
      case 'text': {
        remember(); textSnap = grossSnapshot(doc);
        let t = normalizeMeasurements(applyCorrections(op.text, corrections));
        // ghi chú cát xét đến ở lượt nói sau, bắt đầu bằng "Là …" → bỏ chữ "là"
        if (doc.target >= 0 && doc.oneShot && !doc.cassettes[doc.target].text.trim()) t = t.replace(/^là\s+/iu, '');
        // ghi chú cát xét chỉ kéo dài tới hết câu đầu tiên; phần còn lại của lượt nói về mô tả
        const end = doc.target >= 0 && doc.oneShot ? /[.!?](?=\s|$)/.exec(t) : null;
        if (end) {
          set(appendText(get(), t.slice(0, end.index + 1).trim()));
          doc.target = -1; doc.oneShot = false; gotNote = false;
          const rest = t.slice(end.index + 1).trim();
          if (rest) set(appendText(get(), rest));
        } else { set(appendText(get(), t)); if (doc.target >= 0) gotNote = true; }
        break;
      }
      case 'punct': remember(); set(appendPunct(get(), op.text)); if (/[.!?]/.test(op.text)) closeNote(); break;
      case 'newline': remember(); closeNote(); set(get().replace(/[ \t]+$/, '') + '\n'); break;
      case 'para': remember(); closeNote(); set(get().replace(/\s+$/, '') + '\n\n'); break;
      case 'bullet': remember(); closeNote(); set(get().replace(/[ \t]+$/, '').replace(/([^\n])$/, '$1\n') + '- '); break;
      case 'cassette': remember(); openCassette(op.code); break;
      case 'nextCassette': remember(); openCassette(nextCode(doc)); break;
      case 'body': remember(); doc.target = -1; doc.oneShot = false; break;
      case 'pathcode': remember(); if (op.code) setGrossPathcode(doc, op.code); break;
      case 'newCase': {
        closeNote();
        const finished = grossSnapshot(doc);
        Object.assign(doc, newGrossDoc(op.code || ''));   // lịch sử hoàn tác cũng bắt đầu lại
        signals.push({ newCase: finished });
        snap = grossSnapshot(doc); pushed = false; textSnap = null; gotNote = false;
        break;
      }
      case 'undo':
        // có chữ đọc trước lệnh trong cùng câu → chỉ xoá đoạn chữ đó; lệnh đứng riêng → xoá câu đọc trước
        if (textSnap) { Object.assign(doc, textSnap); textSnap = null; gotNote = false; }
        else { const prev = doc.history.pop(); if (prev) Object.assign(doc, prev); snap = grossSnapshot(doc); pushed = false; }
        break;
      case 'pause': paused = true; signals.push('pause'); break;
      case 'resume': signals.push('resume'); break;
      case 'stop': signals.push('stop'); break;
    }
  }
  // ghi chú cát xét đã có nội dung → các câu sau quay lại phần mô tả
  if (doc.oneShot && gotNote && doc.target >= 0) { doc.target = -1; doc.oneShot = false; }
  return signals;
}

/**
 * Nút "Cát xét +": thêm cát xét kế tiếp (và mã "(A2)" vào mô tả) nhưng KHÔNG đổi chỗ đang ghi —
 * lời đọc vẫn vào phần mô tả; chạm "Ghi vào đây" trên thẻ để đọc vào cát xét.
 */
export function addCassette(doc, { inlineMarker = true } = {}) {
  doc.history.push(grossSnapshot(doc)); if (doc.history.length > 50) doc.history.shift();
  const code = nextCode(doc);
  if (doc.target >= 0) doc.cassettes[doc.target].text = doc.cassettes[doc.target].text.replace(/\s*[,;]\s*$/, '.');
  if ((doc.target < 0 || doc.oneShot) && inlineMarker) doc.body = appendMarker(doc.body, code);
  doc.cassettes.push({ code, text: '', pathcode: doc.pathcode || '' });
  if (doc.oneShot) { doc.target = -1; doc.oneShot = false; }
  return doc.cassettes.length - 1;
}

/** Xem trước tức thì: áp phần đang nghe (chưa chốt) lên bản sao — không đụng văn bản thật. */
export function previewDictation(doc, volatile, opts = {}) {
  const d = { ...grossSnapshot(doc), history: [] };
  applyDictation(d, parseDictation(volatile), opts);
  return d;
}

export function grossReportText(doc, lang = 'vi') {
  const head = doc.pathcode ? `Pathcode: ${doc.pathcode}\n` : '';
  const body = doc.body.trim();
  const cs = doc.cassettes;
  if (!cs.length) return (head + body).trim();
  const title = lang === 'en' ? 'SECTIONS / CASSETTES:' : 'CẮT LỌC – CÁT XÉT:';
  return head + (body ? body + '\n\n' : '') + title + '\n' + cs.map((c) => `${cassetteLabel(c)}: ${c.text.trim()}`).join('\n');
}

/** Gợi ý cấu trúc mô tả theo loại bệnh phẩm (hiển thị khi đọc, không tự chèn). */
export const GROSS_TEMPLATES = [
  { id: 'biopsy', name: 'Sinh thiết nhỏ', items: ['Số mảnh', 'Kích thước (mảnh lớn nhất / gộp)', 'Màu sắc, mật độ', 'Cắt lọc toàn bộ / số cát xét'] },
  { id: 'gallbladder', name: 'Túi mật', items: ['Kích thước', 'Thanh mạc', 'Độ dày thành', 'Niêm mạc', 'Sỏi: số lượng, kích thước, màu', 'Ống túi mật, hạch cổ túi mật', 'Cát xét'] },
  { id: 'appendix', name: 'Ruột thừa', items: ['Chiều dài × đường kính', 'Thanh mạc (giả mạc, thủng)', 'Lòng (sỏi phân, mủ)', 'Đầu tận', 'Diện cắt', 'Cát xét'] },
  { id: 'thyroid', name: 'Tuyến giáp', items: ['Thuỳ / eo, trọng lượng', 'Kích thước', 'Vỏ bao', 'Nốt: số lượng, vị trí, kích thước, vỏ bao, mặt cắt', 'Khoảng cách tới bờ (chấm mực)', 'Tuyến cận giáp, hạch', 'Cát xét'] },
  { id: 'breast', name: 'Vú', items: ['Định hướng (chỉ khâu)', 'Kích thước, da, núm vú', 'U: vị trí, 3 chiều, bờ, mặt cắt', 'Khoảng cách tới từng diện cắt (màu mực)', 'Clip / dấu định vị', 'Hạch nách: số lượng', 'Cát xét'] },
  { id: 'colon', name: 'Đại – trực tràng', items: ['Đoạn ruột, chiều dài', 'U: kích thước, dạng, % chu vi, mức xâm nhập', 'Khoảng cách tới diện cắt gần / xa / quanh (CRM)', 'Mạc treo, hạch (số lượng)', 'Polyp / tổn thương khác', 'Cát xét'] },
  { id: 'uterus', name: 'Tử cung', items: ['Trọng lượng', 'Kích thước thân / cổ', 'Nội mạc: độ dày, tổn thương', 'Cơ tử cung: u xơ (số lượng, kích thước)', 'Cổ tử cung', 'Phần phụ', 'Cát xét'] },
];
