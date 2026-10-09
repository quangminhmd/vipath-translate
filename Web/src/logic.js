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
const CAP = '\\p{Lu}[\\p{Ll}\\p{M}]*';
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
  ['TÊN', ci('(?:họ\\s+và\\s+tên|họ\\s+tên|tên\\s+bệnh\\s+nhân|tên\\s+BN|bệnh\\s+nhân|BN|patient\'?s?\\s+name|patient|name)') + '\\s*[:：]\\s*' + NAME_VALUE, 'gu'],
  ['PID', '(?:PID|mã\\s+BN|mã\\s+bệnh\\s+nhân|mã\\s+y\\s+tế|mã\\s+hồ\\s+sơ|số\\s+hồ\\s+sơ|số\\s+bệnh\\s+án|số\\s+vào\\s+viện|MRN|hospital\\s+(?:number|no\\.?)|medical\\s+record\\s+(?:number|no\\.?))' + SEP + CODE, 'giu'],
  ['MÃ_BP', '(?:mã\\s+bệnh\\s+phẩm|mã\\s+GPB|số\\s+GPB|mã\\s+tiêu\\s+bản|số\\s+tiêu\\s+bản|mã\\s+mẫu|specimen\\s+(?:ID|number|no\\.?)|accession(?:\\s+(?:number|no\\.?))?|case\\s+(?:ID|number|no\\.?)|lab\\s+(?:ID|no\\.?))' + SEP + CODE, 'giu'],
  ['NGÀY_SINH', '(?<![\\p{L}])(?:ngày\\s+sinh|năm\\s+sinh|sinh\\s+ngày|sinh\\s+năm|NS|DOB|date\\s+of\\s+birth|born(?:\\s+on)?)' + SEP + '(\\d{1,2}[/\\-.]\\d{1,2}[/\\-.]\\d{2,4}|\\d{4}-\\d{2}-\\d{2}|(?:19|20)\\d{2})', 'giu'],
  ['ĐỊA_CHỈ', '(?:địa\\s+chỉ|address)\\s*[:：]\\s*([^\\n]{3,120})', 'giu'],
  ['SĐT', '(?:SĐT|SDT|điện\\s+thoại|phone|tel|mobile)' + SEP + '(\\+?\\d[\\d\\s.\\-]{7,14}\\d)', 'giu'],
  ['GIẤY_TỜ', '(?:CCCD|CMND|CMT|căn\\s+cước|passport|hộ\\s+chiếu|ID\\s+card)(?:\\s+(?:số|no\\.?))?' + SEP + '([A-Z0-9]{6,12})', 'giu'],
  ['TÊN', '(?:[Ôô]ng|[Bb]à|anh|[Cc]hị|cô|chú|bác|cháu|Mr\\.?|Mrs\\.?|Ms\\.?|Miss)\\s+(' + CAP + '(?:\\s+' + CAP + '){0,4})', 'gu'],
  ['TÊN', '(?<![\\p{L}])((?:' + FAMILIES.join('|') + ')(?:\\s+' + CAP + '){1,3})(?![\\p{L}])', 'gu'],
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
