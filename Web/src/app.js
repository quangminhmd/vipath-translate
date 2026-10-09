// ViPath Web — giao diện và kết nối thư viện (WebLLM, Transformers.js, Tesseract.js, pdf.js, Claude API).

// ============================================================================
// Tiện ích
// ============================================================================
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const store = {
  get(k, d) { try { const v = localStorage.getItem('vp.' + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('vp.' + k, JSON.stringify(v)); } catch { /* bộ nhớ trình duyệt bị chặn */ } },
};
let toastTimer;
function toast(msg) {
  document.querySelector('.toast')?.remove();
  const t = document.createElement('div');
  t.className = 'toast';
  t.textContent = msg;
  document.body.append(t);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.remove(), 1900);
}
async function copyText(text) {
  try { await navigator.clipboard.writeText(text); toast('Đã chép'); }
  catch {
    const ta = document.createElement('textarea');
    ta.value = text; document.body.append(ta); ta.select();
    try { document.execCommand('copy'); toast('Đã chép'); } catch { toast('Không chép được — hãy chọn và chép tay'); }
    ta.remove();
  }
}
function downloadText(name, text) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain;charset=utf-8' }));
  a.download = name.replace(/[\\/:*?"<>|]+/g, '-');
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 4000);
}
function loadScript(src) {
  return new Promise((res, rej) => {
    if ($(`script[src="${src}"]`)) return res();
    const s = document.createElement('script');
    s.src = src; s.onload = res; s.onerror = () => rej(new Error('Không tải được ' + src));
    document.head.append(s);
  });
}
function setPressed(group, v) { $$('button', group).forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.v === v))); }
function onSeg(group, fn) { group.addEventListener('click', (e) => { const b = e.target.closest('button[data-v]'); if (b) { setPressed(group, b.dataset.v); fn(b.dataset.v); } }); }
const fmtBytes = (n) => (n > 1e9 ? (n / 1e9).toFixed(2) + ' GB' : (n / 1e6).toFixed(0) + ' MB');

// IndexedDB: saved (bản lưu), user (thuật ngữ của tôi), sugg (đề xuất chờ duyệt), meta
const idb = {
  _db: null,
  open() {
    if (this._db) return Promise.resolve(this._db);
    return new Promise((res, rej) => {
      let req;
      try { req = indexedDB.open('vipath', 1); } catch (e) { rej(e); return; }
      req.onupgradeneeded = () => { const d = req.result; for (const s of ['saved', 'user', 'sugg', 'meta']) if (!d.objectStoreNames.contains(s)) d.createObjectStore(s, { keyPath: 'id' }); };
      req.onsuccess = () => { this._db = req.result; res(this._db); };
      req.onerror = () => rej(req.error);
    });
  },
  async tx(store, mode, fn) {
    const d = await this.open();
    return new Promise((res, rej) => { const t = d.transaction(store, mode); const r = fn(t.objectStore(store)); t.oncomplete = () => res(r?.result); t.onerror = () => rej(t.error); });
  },
  async all(store) { try { return (await this.tx(store, 'readonly', (s) => s.getAll())) || []; } catch { return []; } },
  async put(store, obj) { try { await this.tx(store, 'readwrite', (s) => s.put(obj)); return true; } catch { return false; } },
  async del(store, id) { try { await this.tx(store, 'readwrite', (s) => s.delete(id)); } catch { /* bỏ qua */ } },
  async get(store, id) { try { return await this.tx(store, 'readonly', (s) => s.get(id)); } catch { return undefined; } },
};

// ============================================================================
// Thiết bị
// ============================================================================
const device = { webgpu: false, f16: false, checked: false, mobile: /iPhone|iPad|Android/i.test(navigator.userAgent) };
let deviceCheck = null;
function checkDevice() {
  deviceCheck ??= (async () => {
    try {
      // requestAdapter có thể treo trên máy không có GPU → giới hạn 3 s
      const adapter = await Promise.race([navigator.gpu?.requestAdapter(), sleep(3000).then(() => null)]);
      device.webgpu = !!adapter;
      device.f16 = !!adapter?.features?.has('shader-f16');
    } catch { device.webgpu = false; }
    device.checked = true;
    return device;
  })();
  return deviceCheck;
}

// ============================================================================
// Glossary
// ============================================================================
const GL = JSON.parse($('#glossary-data').textContent);
let userEntries = [];
let matcherEN = new GlossaryMatcher(GL.entries);
let matcherVI = new VietnameseMatcher(GL.entries);
const styleGuide = (GL.domains || []).map((d) => GL.profiles?.[d]?.['Ghi chú']).filter(Boolean).map((v) => '- ' + v).join('\n');
const allEntries = () => [...GL.entries, ...userEntries];
function rebuildMatchers() { matcherEN = new GlossaryMatcher(allEntries()); matcherVI = new VietnameseMatcher(allEntries()); }
const hitsFor = (text, dir) => (dir.id === 'enToVi' ? matcherEN.hits(text) : matcherVI.hits(text));
async function addUserEntry(en, vi, note) {
  const terms = en.split(' / ').map((t) => t.trim()).filter((t) => t.length >= 2);
  if (!terms.length || !vi.trim()) return false;
  const key = new Set(terms.map((t) => t.toLowerCase()));
  for (const u of userEntries.filter((u) => u.terms.length === key.size && u.terms.every((t) => key.has(t.toLowerCase())))) await idb.del('user', u.id);
  const entry = { id: 1e6 + Date.now() % 1e9, en, vi: vi.trim(), note: note || '', terms, section: 'Người dùng', domain: 'user', isUser: true };
  await idb.put('user', entry);
  userEntries = await idb.all('user');
  rebuildMatchers();
  return true;
}
function entryForEnglish(en) {
  const e = en.trim().toLowerCase();
  const found = allEntries().filter((x) => (x.terms || []).some((t) => t.toLowerCase() === e) || x.en.toLowerCase() === e);
  const u = found.filter((x) => x.isUser);
  return (u.length ? u : found).at(-1);
}
const glossaryContains = (en, vi) => {
  const e = en.trim().toLowerCase(), v = vi.trim().toLowerCase();
  return allEntries().some((x) => ((x.terms || []).some((t) => t.toLowerCase() === e) || x.en.toLowerCase() === e) && x.vi.toLowerCase().includes(v));
};

// ============================================================================
// Mô hình dịch offline (WebLLM, chạy trên GPU qua WebGPU)
// ============================================================================
const WEBLLM_URL = 'https://cdn.jsdelivr.net/npm/@mlc-ai/web-llm@0.2.84/+esm';
const LLM_MODELS = [
  { id: 'Qwen3.5-4B-q4f16_1-MLC', name: 'Qwen3.5 4B', size: '~2,6 GB', vram: 3.9, note: 'Khuyên dùng trên máy tính: cân bằng chất lượng và tốc độ.' },
  { id: 'Qwen3.5-2B-q4f16_1-MLC', name: 'Qwen3.5 2B', size: '~1,4 GB', vram: 2.3, note: 'Nhẹ — hợp iPhone, máy RAM thấp, phụ đề trực tiếp.' },
  { id: 'Qwen3.5-9B-q4f16_1-MLC', name: 'Qwen3.5 9B', size: '~5,5 GB', vram: 6.5, note: 'Chất lượng cao nhất, cần GPU ≥ 8 GB.' },
  { id: 'Qwen3.5-0.8B-q4f16_1-MLC', name: 'Qwen3.5 0.8B', size: '~0,6 GB', vram: 1.2, note: 'Rất nhanh nhưng dịch thuật ngữ kém; chỉ để thử.' },
];
const llm = { engine: null, modelId: null, loading: false, progress: 0, progressText: '', tps: 0, queue: Promise.resolve(), error: '' };
const modelIdFor = (id) => (device.f16 ? id : id.replace('q4f16_1', 'q4f32_1'));
const llmName = () => llm.engine?.local ? `${llm.engine.model} (máy chủ cục bộ)`
  : LLM_MODELS.find((m) => modelIdFor(m.id) === llm.modelId)?.name || llm.modelId || '';

// ---------- Máy chủ cục bộ (Ollama / LM Studio, API kiểu OpenAI) ----------
// Dùng cho mô hình quá lớn với trình duyệt: TranslateGemma 12B/27B, Hunyuan-MT-7B, Gemma 3 27B…
// Mô hình chạy trên GPU/RAM của PC/Mac; văn bản chỉ đi tới địa chỉ do bạn nhập (mặc định localhost).
const LOCAL_DEFAULT_URL = 'http://localhost:11434/v1';
const localCfg = {
  url: () => store.get('localUrl', LOCAL_DEFAULT_URL),
  model: () => store.get('localModel', 'translategemma:27b'),
};
const normBase = (u) => String(u || '').trim().replace(/\/+$/, '').replace(/\/chat\/completions$/, '');
function localFetchError(e, base) {
  if (e?.name === 'AbortError') return e;
  const hint = base.includes('11434')
    ? 'Ollama: đặt biến môi trường OLLAMA_ORIGINS="*" rồi khởi động lại Ollama.'
    : 'LM Studio: Developer → bật "Enable CORS" và Start Server.';
  return new Error(`Không kết nối được ${base}. Kiểm tra máy chủ đang chạy; ${hint}`);
}
async function localListModels(base) {
  base = normBase(base);
  let r;
  try { r = await fetch(base + '/models', { signal: AbortSignal.timeout(6000) }); } catch (e) { throw localFetchError(e, base); }
  if (!r.ok) throw new Error(`Máy chủ trả lỗi ${r.status} tại ${base}/models`);
  const j = await r.json();
  return (j.data || []).map((m) => m.id).filter(Boolean);
}
/** Đọc luồng SSE "data: {...}" của API kiểu OpenAI thành async iterator các chunk JSON. */
async function* sseChunks(body) {
  const reader = body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line.startsWith('data:')) continue;
        const data = line.slice(5).trim();
        if (data === '[DONE]') return;
        try { yield JSON.parse(data); } catch { /* dòng hỏng — bỏ qua */ }
      }
    }
  } catch (e) { if (e?.name !== 'AbortError') throw e; } finally { try { reader.releaseLock(); } catch { /* */ } }
}
/** Bọc máy chủ cục bộ thành đối tượng có cùng giao diện với engine WebLLM. */
function makeLocalEngine(base, model) {
  let ctrl = null;
  return {
    local: true, base, model,
    chat: { completions: { async create(req) {
      ctrl = new AbortController();
      const { extra_body: _ignored, ...rest } = req;
      let r;
      try {
        r = await fetch(base + '/chat/completions', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ ...rest, model }), signal: ctrl.signal });
      } catch (e) { throw localFetchError(e, base); }
      if (!r.ok) { let m = ''; try { m = (await r.json()).error?.message || ''; } catch { /* */ } throw new Error(`Máy chủ cục bộ lỗi ${r.status}${m ? ': ' + m : ''}`); }
      return sseChunks(r.body);
    } } },
    interruptGenerate() { ctrl?.abort(); },
    async unload() { ctrl?.abort(); },
  };
}
async function loadLocal(url, model) {
  const base = normBase(url);
  if (!model) throw new Error('Nhập tên mô hình trên máy chủ (vd. translategemma:27b).');
  llm.loading = true; llm.progress = 0; llm.progressText = 'Đang kết nối máy chủ cục bộ…'; llm.error = ''; updateChips(); refreshSettingsProgress();
  try {
    const ids = await localListModels(base);
    if (ids.length && !ids.includes(model)) throw new Error(`Máy chủ không có "${model}". Có: ${ids.slice(0, 12).join(', ')}`);
    if (llm.engine) { try { await llm.engine.unload(); } catch { /* bỏ qua */ } }
    llm.engine = makeLocalEngine(base, model);
    llm.modelId = 'local:' + model;
    store.set('localUrl', base); store.set('localModel', model); store.set('llmModel', 'local');
  } catch (e) {
    llm.error = e.message || String(e);
    throw e;
  } finally {
    llm.loading = false; updateChips(); refreshSettingsProgress();
  }
}

async function loadLLM(baseId) {
  await checkDevice();
  if (!device.webgpu) throw new Error('Trình duyệt chưa bật WebGPU. Dùng Chrome / Edge bản mới trên máy tính, hoặc Safari iOS 26 trở lên.');
  const id = modelIdFor(baseId);
  llm.loading = true; llm.progress = 0; llm.error = ''; updateChips();
  try {
    const webllm = await import(WEBLLM_URL);
    const appConfig = { ...webllm.prebuiltAppConfig, cacheBackend: 'indexeddb' };
    try { await navigator.storage?.persist?.(); } catch { /* không bắt buộc */ }
    if (llm.engine) { try { await llm.engine.unload(); } catch { /* bỏ qua */ } }
    llm.engine = await webllm.CreateMLCEngine(id, {
      appConfig,
      initProgressCallback: (r) => { llm.progress = r.progress ?? 0; llm.progressText = r.text || ''; updateChips(); refreshSettingsProgress(); },
    });
    llm.modelId = id;
    store.set('llmModel', baseId);
  } catch (e) {
    llm.engine = null; llm.modelId = null; llm.error = e.message || String(e);
    throw e;
  } finally {
    llm.loading = false; updateChips(); refreshSettingsProgress();
  }
}

function runQueued(fn) { const p = llm.queue.then(fn, fn); llm.queue = p.catch(() => {}); return p; }
class Cancelled extends Error { constructor() { super('Đã dừng'); this.name = 'Cancelled'; } }

/** Dịch một đoạn; các lượt gọi được xếp hàng (WebLLM chỉ sinh một chuỗi một lúc). */
function translateLLM(text, hits, dir, onText, isCancelled = () => false) {
  return runQueued(async () => {
    if (!llm.engine) throw new Error('Chưa nạp mô hình dịch — mở Cài đặt để nạp.');
    if (isCancelled()) throw new Cancelled();
    const guide = dir.id === 'enToVi' ? styleGuide : '';
    const messages = llm.engine.local
      ? localMessages(llm.engine.model, text, hits, dir, guide)
      : [{ role: 'system', content: systemPrompt(dir, guide) }, { role: 'user', content: userPrompt(text, hits, dir) }];
    const t0 = performance.now();
    let first = 0, out = '', tokens = 0, lastEmit = 0;
    const stream = await llm.engine.chat.completions.create({
      messages, stream: true, temperature: 0, max_tokens: Math.min(2048, Math.max(256, text.length)),
      extra_body: { enable_thinking: false }, stream_options: { include_usage: true },
    });
    for await (const chunk of stream) {
      if (isCancelled()) { try { llm.engine.interruptGenerate(); } catch { /* bỏ qua */ } break; }
      const d = chunk.choices?.[0]?.delta?.content || '';
      if (d) {
        if (!first) first = performance.now();
        out += d; tokens++;
        const now = performance.now();
        if (now - lastEmit > 50) { lastEmit = now; onText?.(cleanOutput(out)); }
      }
      if (chunk.usage?.completion_tokens) tokens = chunk.usage.completion_tokens;
    }
    if (isCancelled()) throw new Cancelled();
    const end = performance.now();
    const gen = first ? (end - first) / 1000 : 0;
    const stats = { text: cleanOutput(out), tps: gen > 0 ? Math.max(tokens - 1, 1) / gen : 0, promptS: first ? (first - t0) / 1000 : 0 };
    llm.tps = stats.tps; updateChips();
    return stats;
  });
}

// ============================================================================
// Dịch nhanh (Translator API tích hợp trong Chrome, chạy trên máy)
// ============================================================================
const fast = { supported: typeof self !== 'undefined' && 'Translator' in self, inst: {}, state: {} };
fast.enabled = () => store.get('fastEnabled', true);
async function fastAvailability(dir) {
  if (!fast.supported) return 'unsupported';
  try {
    // có trình duyệt trả lời rất chậm / không trả lời → tối đa 2,5 s
    const a = await Promise.race([self.Translator.availability({ sourceLanguage: dir.src, targetLanguage: dir.tgt }), sleep(2500).then(() => 'unknown')]);
    fast.state[dir.id] = a; return a;
  } catch { return 'unsupported'; }
}
/** gesture = true khi gọi từ nút bấm (Chrome chỉ cho tải gói ngôn ngữ khi người dùng bấm). */
async function fastInstance(dir, gesture = false, onProgress) {
  if (fast.inst[dir.id]) return fast.inst[dir.id];
  const a = await fastAvailability(dir);
  if (a === 'unsupported' || a === 'unavailable' || a === 'unknown') return null;
  if (a !== 'available' && !gesture) return null;
  fast.inst[dir.id] = await self.Translator.create({
    sourceLanguage: dir.src, targetLanguage: dir.tgt,
    monitor(m) { m.addEventListener('downloadprogress', (e) => onProgress?.(e.loaded)); },
  });
  fast.state[dir.id] = 'available';
  return fast.inst[dir.id];
}
async function fastTranslate(text, dir) {
  if (!fast.enabled()) return null;
  try { const t = await fastInstance(dir); return t ? await t.translate(text) : null; } catch { return null; }
}
const fastActive = (dir) => fast.enabled() && fast.state[dir.id] === 'available';

// ============================================================================
// Claude (tuỳ chọn, cần Internet)
// ============================================================================
const CLAUDE_MODELS = [
  { id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5', note: 'Cân bằng chất lượng / tốc độ — khuyên dùng.' },
  { id: 'claude-haiku-5-5', name: 'Claude Haiku 5.5', note: 'Nhanh và rẻ nhất — đủ cho slide, đoạn ngắn.' },
  { id: 'claude-opus-5-5', name: 'Claude Opus 5.5', note: 'Chất lượng cao nhất cho câu phức, thuật ngữ hiếm.' },
];
const claude = {
  enabled: () => store.get('claudeEnabled', false),
  model: () => store.get('claudeModel', 'claude-sonnet-5-5'),
  key() { try { return sessionStorage.getItem('vp.claudeKey') || localStorage.getItem('vp.claudeKey') || ''; } catch { return ''; } },
  setKey(k, remember) {
    try { sessionStorage.removeItem('vp.claudeKey'); localStorage.removeItem('vp.claudeKey'); (remember ? localStorage : sessionStorage).setItem('vp.claudeKey', k); } catch { /* bỏ qua */ }
  },
  clearKey() { try { sessionStorage.removeItem('vp.claudeKey'); localStorage.removeItem('vp.claudeKey'); } catch { /* bỏ qua */ } },
  ready() { return this.enabled() && !!this.key() && navigator.onLine; },
  busy: false,
};
const CLAUDE_SYSTEM = `You are an expert medical translator specialising in anatomical pathology (surgical pathology, cytopathology, immunohistochemistry, molecular pathology), translating between English and Vietnamese for Vietnamese pathologists. Typical content: gross descriptions, microscopic descriptions, diagnoses/conclusions, journal articles, textbooks and teaching slides.

Rules:
1. Translate faithfully and completely. Do not summarise, add, explain or omit anything. Keep the original structure: line breaks, headings, bullet points, numbering, tables.
2. English → Vietnamese: use standard Vietnamese pathology terminology as in Vietnamese medical textbooks and pathology reports; natural, concise report style. Vietnamese → English: use standard English terminology (WHO Classification of Tumours, CAP protocols).
3. Glossary terms supplied by the user are mandatory unless clearly wrong in context.
4. Keep unchanged: gene and protein names, IHC markers (CD20, Ki-67), HGVS variants (p.R132H), TNM staging (pT1aN1b), numbers, units, ICD-O codes, drug names, established Latin/English eponyms.
5. The text is de-identified with placeholders such as [TÊN_1], [PID_1], [MÃ_BP_1], [NGÀY_SINH_1]. Copy every placeholder exactly as written, in the matching position. Never translate, change, merge or guess them.
6. If an offline draft translation is supplied, use it as a starting point: fix terminology, meaning and grammar errors, improve fluency, keep the parts that are already correct.
7. term_suggestions: list rare or specialised pathology/medical terms (not common words, numbers, gene symbols or placeholders) that are missing from the supplied glossary or that the offline draft translated wrongly. Give the English term in canonical dictionary form (singular, lower case unless an abbreviation or proper noun) and its standard Vietnamese equivalent. note: one short Vietnamese sentence explaining why (e.g. what the draft got wrong). At most 15 items; an empty list is fine.
Always answer by calling the submit_translation tool.`;

function claudeHeaders() {
  return { 'x-api-key': claude.key(), 'anthropic-version': '2023-06-01', 'content-type': 'application/json', 'anthropic-dangerous-direct-browser-access': 'true' };
}
function claudeError(status, msg) {
  const map = { 401: 'API key không hợp lệ hoặc đã bị thu hồi (401).', 403: 'Key không có quyền dùng mô hình này (403).', 404: 'Không tìm thấy mô hình (404) — thử mô hình khác.', 413: 'Văn bản quá lớn (413).', 429: 'Vượt giới hạn tốc độ / hạn mức (429). Đợi một lát rồi thử lại.', 529: 'Claude đang quá tải (529). Thử lại sau ít phút.' };
  return new Error(map[status] || `Lỗi Claude API (${status}): ${msg}`);
}
async function claudeVerify() {
  const r = await fetch('https://api.anthropic.com/v1/models?limit=1', { headers: claudeHeaders() });
  if (!r.ok) { let m = ''; try { m = (await r.json()).error?.message || ''; } catch { /* */ } throw claudeError(r.status, m); }
}
function chunkForClaude(text, max = 9000) {
  if (text.length <= max) return [text];
  const out = []; let cur = '';
  for (const p of text.split('\n')) { if (cur.length + p.length + 1 > max && cur) { out.push(cur); cur = ''; } cur += (cur ? '\n' : '') + p; }
  if (cur) out.push(cur);
  return out;
}
async function claudeTranslate({ source, draft, dir, hits, onProgress }) {
  const start = performance.now();
  const parts = chunkForClaude(source);
  const useDraft = parts.length === 1 ? draft : null;
  const texts = [], sugg = []; let inTok = 0, outTok = 0;
  for (let i = 0; i < parts.length; i++) {
    onProgress?.(parts.length > 1 ? `Phần ${i + 1}/${parts.length}` : '');
    const part = parts[i];
    const partHits = hits.filter((h) => part.toLowerCase().includes(h.matched.toLowerCase())).slice(0, 120);
    let user = `Direction: ${dir.id === 'enToVi' ? 'English → Vietnamese' : 'Vietnamese → English'}\n`;
    if (partHits.length) user += '\nGlossary (mandatory):\n' + partHits.map((h) => `- ${h.matched} → ${h.translations.join(' | ')}`).join('\n') + '\n';
    user += `\n<source>\n${part}\n</source>\n`;
    if (useDraft && useDraft.trim()) user += `\n<offline_draft>\n${useDraft}\n</offline_draft>\n`;
    const body = {
      model: claude.model(), max_tokens: Math.min(32000, Math.max(2048, part.length * 2)), system: CLAUDE_SYSTEM,
      tools: [{ name: 'submit_translation', description: 'Return the final translation and glossary term suggestions.',
        input_schema: { type: 'object', properties: {
          translation: { type: 'string', description: 'Complete translation with all placeholders preserved.' },
          term_suggestions: { type: 'array', items: { type: 'object', properties: { english: { type: 'string' }, vietnamese: { type: 'string' }, note: { type: 'string' } }, required: ['english', 'vietnamese'] } },
        }, required: ['translation', 'term_suggestions'] } }],
      tool_choice: { type: 'tool', name: 'submit_translation' },
      messages: [{ role: 'user', content: user }],
    };
    const r = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST', headers: claudeHeaders(), body: JSON.stringify(body) });
    const json = await r.json().catch(() => ({}));
    if (!r.ok) throw claudeError(r.status, json.error?.message || '');
    if (json.stop_reason === 'max_tokens') throw new Error('Văn bản quá dài, Claude trả lời bị cắt. Hãy chia nhỏ văn bản.');
    inTok += json.usage?.input_tokens || 0; outTok += json.usage?.output_tokens || 0;
    const tool = (json.content || []).find((c) => c.type === 'tool_use');
    if (tool?.input?.translation) { texts.push(tool.input.translation); sugg.push(...(tool.input.term_suggestions || [])); }
    else texts.push((json.content || []).map((c) => c.text || '').join(''));
  }
  const seen = new Set();
  return { text: texts.join('\n\n'), suggestions: sugg.filter((s) => s.english && !seen.has(s.english.toLowerCase()) && seen.add(s.english.toLowerCase())),
    inTok, outTok, seconds: (performance.now() - start) / 1000, model: CLAUDE_MODELS.find((m) => m.id === claude.model())?.name || claude.model() };
}

// Vòng học thuật ngữ
async function ingestSuggestions(list) {
  const rejected = new Set((await idb.get('meta', 'rejected'))?.keys || []);
  const pending = await idb.all('sugg');
  let added = 0;
  for (const s of list) {
    const en = (s.english || '').trim(), vi = (s.vietnamese || '').trim();
    if (en.length < 2 || vi.length < 2 || en.length > 80 || vi.length > 120 || en.includes('[') || vi.includes('[')) continue;
    if (en.toLowerCase() === vi.toLowerCase() || !/\p{L}/u.test(en) || rejected.has(`${en.toLowerCase()}→${vi.toLowerCase()}`) || glossaryContains(en, vi)) continue;
    const existing = pending.find((p) => p.english.toLowerCase() === en.toLowerCase());
    const item = { id: existing?.id || `s${Date.now()}${Math.random().toString(36).slice(2, 6)}`, english: en, vietnamese: vi, note: s.note || '',
      existingVi: entryForEnglish(en)?.vi || null, model: CLAUDE_MODELS.find((m) => m.id === claude.model())?.name || '', createdAt: Date.now() };
    await idb.put('sugg', item);
    if (!existing) added++;
  }
  await refreshBadge();
  return added;
}
async function refreshBadge() {
  const n = (await idb.all('sugg')).length;
  const b = $('#badge-terms'); b.textContent = n; b.hidden = n === 0;
}

// ============================================================================
// Đọc tiếng Việt (Web Speech Synthesis)
// ============================================================================
const tts = {
  speaking: false,
  voice() {
    const vs = speechSynthesis.getVoices().filter((v) => v.lang?.toLowerCase().startsWith('vi'));
    const pref = store.get('ttsVoice', '');
    return vs.find((v) => v.name === pref) || vs.find((v) => /premium|enhanced|natural|online/i.test(v.name)) || vs[0] || null;
  },
  speak(text, { enqueue = false } = {}) {
    if (!('speechSynthesis' in window)) { toast('Trình duyệt không hỗ trợ đọc'); return; }
    if (!enqueue) speechSynthesis.cancel();
    const v = this.voice();
    // Chrome cắt câu đọc dài sau ~15 s → đọc từng câu
    for (const s of splitSentences(normalizeSpeech(text).replace(/\n+/g, '. '))) {
      const u = new SpeechSynthesisUtterance(s);
      u.lang = 'vi-VN'; if (v) u.voice = v; u.rate = 1;
      speechSynthesis.speak(u);
    }
  },
  stop() { try { speechSynthesis.cancel(); } catch { /* */ } },
};

// ============================================================================
// Khung ứng dụng: tab, chip trạng thái
// ============================================================================
const TITLES = { translate: 'Dịch', gross: 'Đọc mô tả đại thể', captions: 'Phụ đề trực tiếp', transcribe: 'Chép lời từ tệp', image: 'Chữ trong ảnh', glossary: 'Thuật ngữ', saved: 'Đã lưu' };
let currentTab = 'translate';
function showTab(name) {
  if (!TITLES[name]) name = 'translate';
  currentTab = name;
  $$('.tab[data-tab]').forEach((t) => t.setAttribute('aria-selected', String(t.dataset.tab === name)));
  for (const k of Object.keys(TITLES)) $('#view-' + k).hidden = k !== name;
  $('#view-title').textContent = TITLES[name];
  if (name === 'glossary') renderGlossary();
  if (name === 'saved') renderSaved();
  if (name === 'captions') updateCapHint();
  if (name === 'gross') { updateGrossHint(); renderGross(); }
  try { history.replaceState(null, '', '#' + name); } catch { /* */ }
}
$$('.tab[data-tab]').forEach((t) => t.addEventListener('click', () => showTab(t.dataset.tab)));
$('[data-open="settings"]').addEventListener('click', openSettings);
$('#chip-model').addEventListener('click', openSettings);
$('#chip-claude').addEventListener('click', () => {
  if (!claude.key()) { openSettings('claude'); return; }
  store.set('claudeEnabled', !claude.enabled()); updateChips(); renderClaudeRow();
});
function updateChips() {
  const c = $('#chip-model');
  c.classList.toggle('on', !!llm.engine); c.classList.toggle('busy', llm.loading);
  $('#chip-model-text').textContent = llm.loading ? `Đang nạp ${Math.round(llm.progress * 100)}%`
    : llm.engine ? `${llmName()}${llm.tps ? ' · ' + llm.tps.toFixed(0) + ' tok/s' : ''}` : 'Chưa nạp mô hình';
  const k = $('#chip-claude');
  const on = claude.enabled() && !!claude.key();
  k.classList.toggle('on', on);
  $('#chip-claude-text').textContent = !claude.key() ? 'Claude: chưa có key' : !claude.enabled() ? 'Claude: tắt' : navigator.onLine ? 'Claude: bật' : 'Claude: mất mạng';
}
addEventListener('online', updateChips); addEventListener('offline', updateChips);

// ============================================================================
// Hộp thoại
// ============================================================================
function modal(html, { onClose } = {}) {
  const back = document.createElement('div');
  back.className = 'modal-back';
  back.innerHTML = `<div class="modal" role="dialog" aria-modal="true">${html}</div>`;
  const close = () => { back.remove(); onClose?.(); };
  back.addEventListener('click', (e) => { if (e.target === back) close(); });
  back.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
  $('#modal-root').append(back);
  back.querySelector('[data-close]')?.addEventListener('click', close);
  $$('[data-close]', back).forEach((b) => b.addEventListener('click', close));
  return { el: back.firstElementChild, close };
}

// ============================================================================
// Tab DỊCH
// ============================================================================
const T = {
  dirMode: store.get('dirMode', 'auto'),
  segments: [], outDir: DIR.enToVi, run: 0, running: false, promptS: 0, totalS: 0,
  liveCache: new Map(), liveTimer: null,
  claudeOut: '', claudeInfo: '', claudeLost: [], claudeDir: DIR.enToVi,
};
const input = $('#input');
const currentDir = () => (T.dirMode === 'enToVi' ? DIR.enToVi : T.dirMode === 'viToEn' ? DIR.viToEn : guessDirection(input.value) || DIR.enToVi);
setPressed($('#dir-mode'), T.dirMode);
onSeg($('#dir-mode'), (v) => { T.dirMode = v; store.set('dirMode', v); refreshInputMeta(); if ($('#live-typing').checked) scheduleLive(); });
$('#btn-swap').addEventListener('click', () => {
  const nd = reverseDir(currentDir());
  const out = T.claudeOut || outputText();
  if (out.trim() && !T.running) { input.value = out; T.segments = []; resetClaude(); renderOutput(); }
  T.dirMode = nd.id; store.set('dirMode', nd.id); setPressed($('#dir-mode'), nd.id); refreshInputMeta();
});
$('#btn-paste').addEventListener('click', async () => { try { input.value = await navigator.clipboard.readText(); refreshInputMeta(); } catch { toast('Trình duyệt chặn đọc bộ nhớ tạm — hãy dán bằng ⌘V / Ctrl+V'); input.focus(); } });
$('#btn-clear').addEventListener('click', () => { stopTranslate(); input.value = ''; T.segments = []; resetClaude(); renderOutput(); refreshInputMeta(); });
$('#btn-to-image').addEventListener('click', () => showTab('image'));
$('#btn-sample').addEventListener('click', () => { input.value = 'Immunohistochemistry shows diffuse large B-cell lymphoma; Ki-67 is about 80%. The neoplastic cells are positive for CD20 and negative for CD3.'; refreshInputMeta(); });
$('#live-typing').checked = store.get('liveTyping', false);
$('#live-typing').addEventListener('change', (e) => { store.set('liveTyping', e.target.checked); if (e.target.checked) scheduleLive(); else stopTranslate(); });
input.addEventListener('input', () => { refreshInputMeta(); if ($('#live-typing').checked) scheduleLive(); });

function refreshInputMeta() {
  const d = currentDir();
  $('#dir-label').textContent = d.id === 'enToVi' ? 'EN → VI' : 'VI → EN';
  $('#btn-translate').textContent = `Dịch sang ${d.target.replace('Tiếng', 'tiếng')}`;
  const hits = input.value.trim() ? hitsFor(input.value, d) : [];
  $('#hits-line').innerHTML = hits.length
    ? `<span class="muted">${hits.length} thuật ngữ glossary sẽ được chèn:</span> ${hits.slice(0, 8).map((h) => `<span class="term">${esc(h.matched)}</span>`).join(' ')}${hits.length > 8 ? ' …' : ''}`
    : '';
  $('#btn-translate').disabled = !input.value.trim() || T.running;
  renderClaudeRow();
}

function outputText() { return T.segments.map((s) => (s.passthrough ? s.text : s.output)).join('\n'); }

function stopTranslate() { T.run++; T.running = false; $('#btn-stop').hidden = true; $('#btn-translate').hidden = false; refreshInputMeta(); }
$('#btn-stop').addEventListener('click', stopTranslate);
$('#btn-translate').addEventListener('click', () => translateInput());

async function translateInput(segsOverride) {
  const text = input.value.trim();
  if (!text) return;
  if (!llm.engine) { showError('Chưa nạp mô hình dịch. Mở Cài đặt → Mô hình dịch offline để nạp (lần đầu cần Internet).'); openSettings(); return; }
  showError('');
  resetClaude();
  const dir = currentDir();
  T.outDir = dir;
  const pieces = segsOverride || segmentText(text);
  T.segments = pieces.map((p, i) => ({ id: i, text: p.text, passthrough: p.passthrough, hits: p.passthrough ? [] : hitsFor(p.text, dir), output: '', missing: [], done: false }));
  await runSegments(T.segments.map((s) => s.id));
}

async function runSegments(ids) {
  const run = ++T.run;
  const cancelled = () => run !== T.run;
  T.running = true; $('#btn-stop').hidden = false; $('#btn-translate').hidden = true;
  const t0 = performance.now(); T.promptS = 0;
  renderOutput();
  for (const id of ids) {
    const s = T.segments.find((x) => x.id === id);
    if (!s || s.passthrough || s.done) continue;
    s.active = true; renderOutput();
    try {
      const st = await translateLLM(s.text, s.hits, T.outDir, (t) => { if (!cancelled()) { s.output = t; renderSegment(s); } }, cancelled);
      s.output = st.text; s.done = true; s.missing = glossaryMissing(s.hits, st.text);
      T.promptS += st.promptS;
      if ($('#live-typing').checked) T.liveCache.set(cacheKey(s.text), { output: s.output, missing: s.missing });
    } catch (e) {
      if (e instanceof Cancelled || cancelled()) return;
      showError(e.message);
      break;
    } finally { s.active = false; }
    if (cancelled()) return;
    renderOutput();
  }
  if (cancelled()) return;
  T.totalS = (performance.now() - t0) / 1000;
  T.running = false; $('#btn-stop').hidden = true; $('#btn-translate').hidden = false;
  renderOutput(); refreshInputMeta();
}

// Dịch khi gõ: chờ ngừng gõ 0,7 s, chỉ dịch câu mới / câu đã sửa
const cacheKey = (s) => `${llm.modelId}|${T.outDir.id}|${s}`;
function scheduleLive() {
  clearTimeout(T.liveTimer);
  T.liveTimer = setTimeout(() => {
    if (!llm.engine || !input.value.trim()) return;
    const dir = currentDir();
    T.outDir = dir;
    const sents = splitSentences(input.value).filter((s) => /\p{L}/u.test(s));
    const old = T.segments;
    T.segments = sents.map((t, i) => {
      const c = T.liveCache.get(cacheKey(t));
      return { id: i, text: t, passthrough: false, hits: hitsFor(t, dir), output: c ? c.output : (old[i]?.output || ''), missing: c ? c.missing : [], done: !!c };
    });
    runSegments(T.segments.filter((s) => !s.done).map((s) => s.id));
  }, 700);
}

function showError(msg) { const n = $('#translate-error'); n.textContent = msg; n.hidden = !msg; }

function renderSegment(s) {
  const el = $(`#seg-${s.id}`);
  if (el) el.querySelector('.out').textContent = s.output || (s.active ? 'Đang dịch…' : 'Chờ dịch');
}
function renderOutput() {
  const has = T.segments.some((s) => !s.passthrough);
  $('#out-card').hidden = !has;
  $('#empty-out').hidden = has || !!T.claudeOut;
  if (!has) return;
  $('#out-title').textContent = `${T.outDir.target} · offline`;
  $('#btn-speak').hidden = T.outDir.id !== 'enToVi';
  const live = $('#live-typing').checked;
  $('#segments').innerHTML = T.segments.filter((s) => !s.passthrough).map((s) => `
    <div class="seg-out${s.active ? ' active' : ''}" id="seg-${s.id}">
      <div class="out">${esc(s.output || (s.active ? 'Đang dịch…' : 'Chờ dịch'))}</div>
      ${live ? '' : `<details><summary class="tiny muted">Văn bản gốc</summary><div class="src">${esc(s.text)}</div></details>`}
      ${s.done && s.missing.length ? `<div class="miss">⚠︎ ${s.missing.map((h) => `${esc(h.matched)} → ${esc(h.translations.join(' | '))}`).join('; ')}
        <button class="btn ghost small" data-retry="${s.id}">Dịch lại đoạn này</button></div>` : ''}
    </div>`).join('');
  const missing = new Set(T.segments.flatMap((s) => s.missing.map((h) => h.id)));
  $('#miss-line').textContent = missing.size ? `${missing.size} thuật ngữ chưa dùng đúng glossary (màu cam).` : '';
  $('#stats-line').textContent = !T.running && T.totalS ? `Tổng ${T.totalS.toFixed(1)} s · đọc prompt ${T.promptS.toFixed(1)} s · ${llm.tps.toFixed(0)} tok/s · ${T.segments.filter((s) => !s.passthrough).length} đoạn` : '';
}
$('#segments').addEventListener('click', (e) => {
  const b = e.target.closest('[data-retry]');
  if (!b || T.running) return;
  const s = T.segments.find((x) => x.id === Number(b.dataset.retry));
  if (!s) return;
  s.done = false; s.output = ''; s.hits = hitsFor(s.text, T.outDir);
  runSegments([s.id]);
});
$('#btn-copy-out').addEventListener('click', () => copyText(outputText()));
$('#btn-speak').addEventListener('click', () => tts.speak(outputText()));
$('#btn-save-out').addEventListener('click', () => saveText(false));
$('#btn-save-claude').addEventListener('click', () => saveText(true));
$('#btn-copy-claude').addEventListener('click', () => copyText(T.claudeOut));

async function saveText(fromClaude) {
  const source = input.value.trim();
  if (!source) return;
  const item = { id: 'v' + Date.now(), kind: 'text', createdAt: Date.now(), title: autoTitle(source), dir: (fromClaude ? T.claudeDir : T.outDir).id,
    engine: llmName() || '—', source, translation: outputText(), claude: T.claudeOut || '', claudeModel: T.claudeOut ? (CLAUDE_MODELS.find((m) => m.id === claude.model())?.name || '') : '' };
  toast((await idb.put('saved', item)) ? 'Đã lưu vào tab Đã lưu' : 'Không lưu được (trình duyệt chặn bộ nhớ)');
}
function autoTitle(t) { const line = t.split('\n')[0].trim(); return line.length > 60 ? line.slice(0, 60) + '…' : line || 'Không tiêu đề'; }

// ---------- Claude trong tab Dịch ----------
function renderClaudeRow() {
  const on = claude.enabled() && !!claude.key();
  $('#claude-row').hidden = !on;
  const hasDraft = T.segments.some((s) => !s.passthrough) && !T.running && T.segments.every((s) => s.passthrough || s.done);
  $('#btn-claude').textContent = hasDraft ? 'Hiệu đính bằng Claude' : 'Dịch bằng Claude';
  $('#btn-claude').disabled = !input.value.trim() || claude.busy || T.running;
}
function resetClaude() { T.claudeOut = ''; T.claudeInfo = ''; T.claudeLost = []; $('#claude-card').hidden = true; }
$('#btn-claude').addEventListener('click', () => {
  if (!claude.ready()) { openSettings('claude'); return; }
  const text = input.value.trim();
  const hasDraft = T.segments.some((s) => !s.passthrough) && T.segments.every((s) => s.passthrough || s.done);
  const dir = hasDraft ? T.outDir : currentDir();
  openRedaction({ source: text, draft: hasDraft ? outputText() : null, dir, hits: hitsFor(text, dir) });
});
const DRAFT_SEP = '\n\n<<<DRAFT>>>\n\n';
function buildRedaction(req, extra) {
  const combined = req.draft ? req.source + DRAFT_SEP + req.draft : req.source;
  const r = redactPHI(combined, extra);
  const parts = r.text.split(DRAFT_SEP);
  return { ...r, redSource: parts[0], redDraft: parts.length > 1 ? parts.slice(1).join(DRAFT_SEP) : null };
}
const highlightPH = (t) => esc(t).replace(PLACEHOLDER_RX, (m) => `<span class="ph">${m}</span>`);
function openRedaction(req) {
  let extra = [];
  let red = buildRedaction(req, extra);
  const m = modal(`
    <h3>Xác nhận trước khi gửi tới Claude</h3>
    <div class="small muted">${req.draft ? 'Hiệu đính bản dịch offline' : 'Dịch'} · ${req.dir.label} · ${esc(CLAUDE_MODELS.find((x) => x.id === claude.model())?.name || '')}</div>
    <div id="rd-counts"></div>
    <div><div class="tiny muted" style="margin-bottom:4px">Nội dung sẽ gửi đi</div><div class="preview" id="rd-src"></div></div>
    <details id="rd-draft-wrap"><summary class="small">Bản dịch offline gửi kèm</summary><div class="preview" id="rd-draft"></div></details>
    <div class="stack"><div class="tiny muted">Còn sót thông tin định danh? Nhập cụm cần che thêm, cách nhau bởi dấu phẩy (tên bác sĩ, bệnh viện, số giường…)</div>
      <div class="row"><input type="text" id="rd-extra" style="flex:1"><button class="btn" id="rd-apply">Che thêm</button></div></div>
    <details><summary class="small">Bảng đối chiếu (chỉ nằm trên máy, không gửi đi)</summary><div class="kv mono" id="rd-map" style="margin-top:8px"></div></details>
    <label class="check" style="align-items:flex-start"><input type="checkbox" id="rd-ok"> <span>Tôi đã kiểm tra: nội dung trên không còn họ tên, PID, CCCD / hộ chiếu, mã bệnh phẩm, ngày sinh hay thông tin định danh nào khác của bệnh nhân.</span></label>
    <div class="foot"><button class="btn" data-close>Huỷ</button><button class="btn hema" id="rd-send" disabled>Gửi tới Claude</button></div>`);
  const render = () => {
    const counts = Object.entries(red.counts);
    $('#rd-counts', m.el).innerHTML = counts.length
      ? `<div class="row">${counts.map(([k, n]) => `<span class="chip on"><span class="dot"></span>${esc(PHI_KINDS[k] || k)}: ${n} đã che</span>`).join('')}</div>`
      : '<div class="note warn">Không phát hiện thông tin định danh. Hãy đọc kỹ văn bản bên dưới trước khi gửi.</div>';
    $('#rd-src', m.el).innerHTML = highlightPH(red.redSource);
    $('#rd-draft-wrap', m.el).hidden = !red.redDraft;
    if (red.redDraft) $('#rd-draft', m.el).innerHTML = highlightPH(red.redDraft);
    $('#rd-map', m.el).innerHTML = red.replacements.map((r) => `<span>${esc(r.placeholder)}</span><span>${esc(r.original)}</span>`).join('') || '<span class="muted">Trống</span>';
  };
  render();
  const ok = $('#rd-ok', m.el), send = $('#rd-send', m.el);
  ok.addEventListener('change', () => { send.disabled = !ok.checked; });
  $('#rd-apply', m.el).addEventListener('click', () => {
    extra = $('#rd-extra', m.el).value.split(',').map((s) => s.trim()).filter(Boolean);
    red = buildRedaction(req, extra); ok.checked = false; send.disabled = true; render();
  });
  send.addEventListener('click', () => { m.close(); sendClaude(req, red); });
}
async function sendClaude(req, red) {
  claude.busy = true; renderClaudeRow();
  T.claudeDir = req.dir;
  $('#claude-card').hidden = false; $('#empty-out').hidden = true;
  $('#claude-model-label').textContent = req.dir.target;
  $('#claude-out').textContent = 'Đang gửi văn bản đã che định danh tới Claude…';
  $('#claude-lost').textContent = ''; $('#claude-info').textContent = ''; $('#btn-review-terms').hidden = true;
  try {
    const r = await claudeTranslate({ source: red.redSource, draft: red.redDraft, dir: req.dir, hits: req.hits,
      onProgress: (p) => { if (p) $('#claude-info').textContent = p; } });
    T.claudeLost = red.replacements.map((x) => x.placeholder).filter((p) => red.redSource.includes(p) && !r.text.includes(p));
    T.claudeOut = restorePHI(r.text, red.replacements);
    $('#claude-out').textContent = T.claudeOut;
    $('#claude-lost').textContent = T.claudeLost.length ? `Claude làm mất ${T.claudeLost.join(', ')} — kiểm tra lại định danh trong bản dịch.` : '';
    $('#claude-info').textContent = `${r.model} · ${r.seconds.toFixed(1)} s · ${r.inTok}→${r.outTok} token`;
    const added = await ingestSuggestions(r.suggestions);
    const pending = (await idb.all('sugg')).length;
    const b = $('#btn-review-terms');
    b.hidden = pending === 0;
    b.textContent = added ? `Claude đề xuất ${added} thuật ngữ mới — duyệt để mô hình offline học` : `${pending} thuật ngữ đang chờ duyệt`;
  } catch (e) {
    $('#claude-out').textContent = '';
    const msg = e instanceof TypeError ? 'Không kết nối được tới Claude (mất mạng, hoặc mạng / tiện ích trình duyệt chặn api.anthropic.com).' : (e.message || String(e));
    $('#claude-info').innerHTML = `<span class="danger">${esc(msg)}</span>`;
  } finally { claude.busy = false; renderClaudeRow(); }
}
$('#btn-review-terms').addEventListener('click', () => showTab('glossary'));

// ============================================================================
// Thu âm thanh (micro / tab) → 16 kHz mono
// ============================================================================
async function startCapture(source, onSamples) {
  const stream = source === 'tab'
    ? await navigator.mediaDevices.getDisplayMedia({ video: true, audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } })
    : await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
  if (!stream.getAudioTracks().length) {
    stream.getTracks().forEach((t) => t.stop());
    throw new Error('Không có âm thanh. Khi chọn tab Zoom / Teams / YouTube, hãy bật “Chia sẻ âm thanh của tab”.');
  }
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const src = ctx.createMediaStreamSource(new MediaStream(stream.getAudioTracks()));
  const proc = ctx.createScriptProcessor(4096, 1, 1);
  const ratio = ctx.sampleRate / 16000;
  proc.onaudioprocess = (e) => {
    const x = e.inputBuffer.getChannelData(0);
    const n = Math.floor(x.length / ratio);
    const y = new Float32Array(n);
    for (let i = 0; i < n; i++) { const a = i * ratio, j = Math.floor(a), f = a - j; y[i] = x[j] * (1 - f) + (x[j + 1] ?? x[j]) * f; }
    onSamples(y);
  };
  src.connect(proc); proc.connect(ctx.destination);   // đầu ra im lặng (không chép vào output) — cần nối để Chrome chạy xử lý
  return { stop() { try { proc.disconnect(); src.disconnect(); ctx.close(); } catch { /* */ } stream.getTracks().forEach((t) => t.stop()); }, stream };
}
const rms = (a) => { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * a[i]; return Math.sqrt(s / Math.max(1, a.length)); };

// ============================================================================
// Whisper (Transformers.js, WebGPU / WASM)
// ============================================================================
const TRANSFORMERS_URL = 'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.8.1/dist/transformers.min.js';
const WHISPER_MODELS = [
  { id: 'onnx-community/whisper-large-v3-turbo', name: 'Whisper large-v3 turbo', size: '~1 GB', note: 'Chính xác nhất, tốt cho tiếng Việt và bài giảng trộn Anh–Việt (cần WebGPU).' },
  { id: 'onnx-community/whisper-small', name: 'Whisper small', size: '~300 MB', note: 'Cân bằng — hợp iPhone và phụ đề trực tiếp.' },
  { id: 'onnx-community/whisper-base', name: 'Whisper base', size: '~150 MB', note: 'Nhanh nhất, kém chính xác hơn với tiếng Việt.' },
];
const asr = { pipe: null, id: null, loading: null, progress: 0 };
async function getASR(id, onProgress) {
  if (asr.pipe && asr.id === id) return asr.pipe;
  if (asr.loading && asr.loadingId === id) return asr.loading;
  asr.loadingId = id;
  asr.loading = (async () => {
    await checkDevice();
    const tf = await import(TRANSFORMERS_URL);
    tf.env.allowLocalModels = false;
    if (!('caches' in self)) tf.env.useBrowserCache = false;
    const files = new Map();
    const dtype = device.webgpu ? { encoder_model: device.f16 ? 'fp16' : 'fp32', decoder_model_merged: 'q4' } : 'q8';
    const pipe = await tf.pipeline('automatic-speech-recognition', id, {
      device: device.webgpu ? 'webgpu' : 'wasm', dtype,
      progress_callback: (p) => {
        if (p.status === 'progress' && p.file) {
          files.set(p.file, { loaded: p.loaded || 0, total: p.total || 0 });
          let l = 0, t = 0; for (const v of files.values()) { l += v.loaded; t += v.total; }
          asr.progress = t ? l / t : 0;
          onProgress?.(asr.progress, `Tải ${fmtBytes(l)} / ${fmtBytes(t)}`);
        }
      },
    });
    asr.pipe = pipe; asr.id = id;
    return pipe;
  })();
  try { return await asr.loading; } finally { asr.loading = null; }
}
const whisperLang = (code) => (code === 'vi' ? 'vietnamese' : 'english');

// ============================================================================
// Tab PHỤ ĐỀ
// ============================================================================
const C = {
  source: 'mic', asrMode: 'web', running: false, caps: [], volatile: '', pending: '', lastFinal: 0, nextId: 0,
  queue: [], working: false, capture: null, rec: null, chunk: [], chunkLen: 0, silence: 0, speech: 0, asrQueue: [], asrBusy: false, flushTimer: null, startedAt: 0,
};
const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
if (!SR) C.asrMode = 'whisper';
setPressed($('#cap-asr'), C.asrMode);
onSeg($('#cap-source'), (v) => { C.source = v; if (v === 'tab' && C.asrMode === 'web') { C.asrMode = 'whisper'; setPressed($('#cap-asr'), 'whisper'); } updateCapHint(); });
onSeg($('#cap-asr'), (v) => { C.asrMode = v; if (v === 'web' && C.source === 'tab') { C.source = 'mic'; setPressed($('#cap-source'), 'mic'); } updateCapHint(); });
function updateCapHint() {
  const parts = [];
  if (C.source === 'tab') parts.push(device.mobile ? 'Điện thoại không cho trình duyệt thu âm thanh app khác — dùng Micro.' : 'Bấm Bắt đầu, chọn tab Zoom / Teams / Meet / YouTube và bật “Chia sẻ âm thanh của tab”.');
  if (C.asrMode === 'web') parts.push(SR ? 'Bộ nhận dạng của trình duyệt: Chrome gửi âm thanh lên máy chủ Google để nhận dạng; Safari dùng nhận dạng của Apple. Muốn hoàn toàn offline, chọn Whisper.' : 'Trình duyệt này không có nhận dạng giọng nói — dùng Whisper.');
  else parts.push(`Whisper chạy trên máy (${(WHISPER_MODELS.find((m) => m.id === store.get('capWhisper', 'onnx-community/whisper-small')) || WHISPER_MODELS[1]).name}); nên dùng bản small cho phụ đề.`);
  if (!llm.engine) parts.push(fast.supported ? 'Chưa nạp mô hình dịch — chỉ có ⚡ Dịch nhanh (Chrome).' : 'Chưa nạp mô hình dịch — mở Cài đặt để nạp.');
  $('#cap-hint').textContent = parts.join(' ');
  $('#cap-fast').disabled = !fast.supported;
  if (!fast.supported) $('#cap-fast').checked = false;
}
$('#cap-fast').checked = fast.supported && store.get('capFast', true);
$('#cap-fast').addEventListener('change', async (e) => {
  store.set('capFast', e.target.checked);
  if (e.target.checked) { try { await fastInstance(DIR.enToVi, true, (p) => setCapStatus(`Tải gói Anh→Việt ${Math.round(p * 100)}%`)); setCapStatus(''); } catch { /* */ } }
});
$('#cap-speak').addEventListener('change', (e) => { if (!e.target.checked) tts.stop(); });
const setCapStatus = (s) => { $('#cap-status').textContent = s; };

$('#cap-start').addEventListener('click', startCaptions);
$('#cap-stop').addEventListener('click', stopCaptions);
$('#cap-clear').addEventListener('click', () => { if (C.running) return; C.caps = []; C.volatile = ''; renderCaps(); });
$('#cap-copy').addEventListener('click', () => copyText(C.caps.map((c) => `${c.en}\n${c.vi || c.fast}`).join('\n\n')));
$('#cap-save').addEventListener('click', saveCaptions);

async function startCaptions() {
  if (C.running) return;
  const canTranslate = !!llm.engine || ($('#cap-fast').checked && fast.supported);
  if (!canTranslate) { toast('Nạp mô hình dịch trong Cài đặt, hoặc bật ⚡ Dịch nhanh (Chrome)'); openSettings(); return; }
  if ($('#cap-fast').checked) { try { await fastInstance(DIR.enToVi, true); } catch { /* */ } }
  C.running = true; C.pending = ''; C.volatile = ''; C.queue = []; C.asrQueue = []; C.startedAt = Date.now();
  $('#cap-start').hidden = true; $('#cap-stop').hidden = false; $('#cap-live-en').hidden = false;
  try {
    if (C.asrMode === 'web') startWebSpeech();
    else {
      const id = store.get('capWhisper', 'onnx-community/whisper-small');
      setCapStatus('Đang nạp Whisper…');
      await getASR(id, (p, t) => setCapStatus(`Nạp Whisper ${Math.round(p * 100)}% · ${t}`));
      if (!C.running) return;
      setCapStatus('Đang nghe');
      C.chunk = []; C.chunkLen = 0; C.silence = 0; C.speech = 0;
      C.capture = await startCapture(C.source, onCapSamples);
      C.capture.stream.getTracks().forEach((t) => t.addEventListener('ended', () => stopCaptions()));
    }
  } catch (e) {
    setCapStatus(e.message || String(e)); C.running = false;
    $('#cap-start').hidden = false; $('#cap-stop').hidden = true; $('#cap-live-en').hidden = true;
    return;
  }
  C.flushTimer = setInterval(() => { if (C.pending && Date.now() - C.lastFinal > 900) flushPending(); }, 300);
}
async function stopCaptions() {
  if (!C.running) return;
  C.running = false;
  try { C.rec?.stop(); } catch { /* */ }
  C.rec = null;
  C.capture?.stop(); C.capture = null;
  if (C.chunkLen > 16000) pushAsrChunk();
  clearInterval(C.flushTimer);
  flushPending();
  C.volatile = '';
  $('#cap-start').hidden = false; $('#cap-stop').hidden = true; $('#cap-live-en').hidden = true;
  setCapStatus('Đã dừng');
  renderCaps();
  if (store.get('capAutoSave', true) && C.caps.some((c) => c.vi || c.fast)) { await saveCaptions(); setCapStatus('Đã dừng · đã lưu vào tab Đã lưu'); }
}
function startWebSpeech() {
  const rec = new SR();
  rec.lang = 'en-US'; rec.continuous = true; rec.interimResults = true;
  rec.onresult = (e) => {
    let interim = '';
    for (let i = e.resultIndex; i < e.results.length; i++) {
      const r = e.results[i];
      if (r.isFinal) handleFinal(r[0].transcript); else interim += r[0].transcript;
    }
    C.volatile = interim; renderCapsEN(); translateVolatile();
  };
  rec.onerror = (e) => { if (e.error === 'not-allowed' || e.error === 'service-not-allowed') { setCapStatus('Chưa cấp quyền micro / nhận dạng giọng nói'); stopCaptions(); } };
  rec.onend = () => { if (C.running && C.rec === rec) { try { rec.start(); } catch { /* */ } } };
  C.rec = rec;
  rec.start();
  setCapStatus('Đang nghe');
}
// Whisper trực tiếp: cắt đoạn khi im lặng ≥ 0,6 s (đoạn ≥ 1,5 s) hoặc dài 8 s
function onCapSamples(y) {
  if (!C.running) return;
  C.chunk.push(y); C.chunkLen += y.length;
  const loud = rms(y) > 0.012;
  if (loud) { C.speech += y.length; C.silence = 0; } else C.silence += y.length;
  if ((C.silence > 9600 && C.chunkLen > 24000 && C.speech > 4000) || C.chunkLen > 16000 * 8) pushAsrChunk();
  else if (C.silence > 16000 * 2 && C.speech < 4000) { C.chunk = []; C.chunkLen = 0; C.speech = 0; }   // bỏ đoạn chỉ có im lặng
}
function pushAsrChunk() {
  const a = new Float32Array(C.chunkLen);
  let o = 0; for (const c of C.chunk) { a.set(c, o); o += c.length; }
  C.chunk = []; C.chunkLen = 0; C.silence = 0; C.speech = 0;
  C.asrQueue.push(a);
  runAsrQueue();
}
async function runAsrQueue() {
  if (C.asrBusy) return;
  C.asrBusy = true;
  while (C.asrQueue.length) {
    const a = C.asrQueue.shift();
    C.volatile = '…đang nhận dạng'; renderCapsEN();
    try {
      const out = await asr.pipe(a, { language: 'english', task: 'transcribe' });
      const text = (out.text || '').replace(/\[[^\]]*\]|\([^)]*\)/g, ' ').trim();   // bỏ [Music], (applause)…
      if (text) { handleFinal(text); flushPending(); }
    } catch (e) { setCapStatus('Lỗi Whisper: ' + (e.message || e)); }
    C.volatile = ''; renderCapsEN();
  }
  C.asrBusy = false;
}
function handleFinal(text) {
  const t = text.trim();
  C.volFast = '';
  if (!t) return;
  C.pending = C.pending ? C.pending + ' ' + t : t;
  C.lastFinal = Date.now();
  const { sentences, rest } = completeSentences(C.pending);
  sentences.forEach(enqueueCaption);
  C.pending = rest.trim();
  splitLongClause();
  if (C.pending.split(/\s+/).length >= 24) flushPending();
  renderCapsEN();
}
function flushPending() { const t = C.pending.trim(); C.pending = ''; if (t) enqueueCaption(t); if (C.volatile) translateVolatile(); else C.volFast = ''; }
/** Câu dài chưa có dấu chấm: cắt ở dấu phẩy / chấm phẩy cuối (vế trái ≥ 8 từ) — câu ngắn dịch nhanh hơn. */
function splitLongClause() {
  const w = C.pending.split(/\s+/);
  if (w.length < 14) return;
  let cut = -1, words = 0;
  for (let i = 0; i < C.pending.length; i++) {
    if (C.pending[i] === ' ') words++;
    if ((C.pending[i] === ',' || C.pending[i] === ';') && words >= 7) cut = i + 1;
  }
  if (cut < 0) return;
  const left = C.pending.slice(0, cut).trim(), right = C.pending.slice(cut).trim();
  if (right.split(/\s+/).length < 2) return;
  enqueueCaption(left); C.pending = right;
}
/** ⚡ dịch câu đang nói (chưa chốt) — một lượt một lúc, luôn lấy bản mới nhất. */
async function translateVolatile() {
  if (C.volBusy || !$('#cap-fast').checked || !fastActive(DIR.enToVi)) return;
  C.volBusy = true;
  let last = '';
  while (C.running) {
    const src = (C.pending ? C.pending + ' ' : '') + C.volatile;
    if (!C.volatile || src === last) break;
    last = src;
    const t = await fastTranslate(src, DIR.enToVi);
    if (t && C.volatile) { C.volFast = t; renderCapsVI(); }
    await sleep(120);
  }
  C.volBusy = false;
}
const capMode = () => (!llm.engine ? 'fastest' : (C.mode === 'fastest' && !fastActive(DIR.enToVi)) ? 'balanced' : C.mode);
C.mode = store.get('capMode', 'balanced');
setPressed($('#cap-mode'), C.mode);
onSeg($('#cap-mode'), (v) => { C.mode = v; store.set('capMode', v); updateCapHint(); });
function finalizeFast(cap) {
  cap.vi = cap.fast; cap.missing = glossaryMissing(cap.hits, cap.fast); cap.state = 'done'; cap.fastFinal = true;
  if ($('#cap-speak').checked) tts.speak(cap.fast, { enqueue: true });
}
function enqueueCaption(sentence) {
  if (!/\p{L}/u.test(sentence)) return;
  const cap = { id: C.nextId++, en: sentence, vi: '', fast: '', hits: hitsFor(sentence, DIR.enToVi), missing: [], state: 'queued', at: Date.now() };
  C.caps.push(cap);
  const useModel = capMode() !== 'fastest';
  if ($('#cap-fast').checked && fastActive(DIR.enToVi)) {
    fastTranslate(sentence, DIR.enToVi).then((t) => {
      if (!t || cap.state === 'done') return;
      cap.fast = t;
      if (!useModel) finalizeFast(cap);
      renderCapsVI();
    });
  }
  if (useModel) { C.queue.push(cap.id); runCapQueue(); }
  renderCaps();
}
async function runCapQueue() {
  if (C.working) return;
  C.working = true;
  while (C.queue.length) {
    // Cân bằng: câu cũ đã có ⚡ (tồn đọng / chờ > 6 s) → giữ ⚡, mô hình chỉ dịch câu mới nhất
    const mode = capMode();
    if (mode !== 'accurate') {
      const newest = mode === 'fastest' ? null : C.queue[C.queue.length - 1];
      C.queue = C.queue.filter((id) => {
        const c = C.caps.find((x) => x.id === id);
        if (c && c.fast && (id !== newest || Date.now() - c.at > 6000)) { finalizeFast(c); return false; }
        return true;
      });
      renderCapsVI();
      if (!C.queue.length) break;
    }
    if (C.queue.length >= 3) {   // tồn đọng → gộp các câu chờ vào câu đầu
      const ids = C.queue.splice(0);
      const caps = ids.map((id) => C.caps.find((c) => c.id === id)).filter(Boolean);
      const first = caps[0];
      first.en = caps.map((c) => c.en).join(' ');
      first.fast = caps.map((c) => c.fast).filter(Boolean).join(' ');
      first.hits = hitsFor(first.en, DIR.enToVi);
      C.caps = C.caps.filter((c) => !caps.slice(1).includes(c));
      C.queue = [first.id];
    }
    const cap = C.caps.find((c) => c.id === C.queue.shift());
    if (!cap) continue;
    cap.state = 'translating'; renderCaps();
    try {
      const st = await translateLLM(cap.en, cap.hits, DIR.enToVi, (t) => { if (!cap.fast) { cap.vi = t; renderCapsVI(); } });
      cap.fastFinal = false;
      cap.vi = st.text; cap.missing = glossaryMissing(cap.hits, st.text); cap.state = 'done';
      setCapStatus(`trễ ${((Date.now() - cap.at) / 1000).toFixed(1)} s · ${st.tps.toFixed(0)} tok/s`);
      if ($('#cap-speak').checked) tts.speak(st.text, { enqueue: true });
    } catch (e) { cap.vi = '⚠︎ ' + (e.message || e); cap.state = 'done'; }
    renderCapsVI();
  }
  C.working = false;
}
function renderCaps() { renderCapsEN(); renderCapsVI(); }
function renderCapsEN() {
  const box = $('#cap-en');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  box.innerHTML = C.caps.map((c) => `<div class="cap-en">${esc(c.en)}</div>`).join('') + (C.volatile ? `<div class="cap-en vol">${esc(C.volatile)}</div>` : '')
    + (C.pending ? `<div class="cap-en vol">${esc(C.pending)}</div>` : '')
    + (!C.caps.length && !C.volatile && !C.pending ? `<div class="muted small">${C.running ? 'Đang nghe…' : 'Lời nói tiếng Anh nhận dạng được sẽ hiện ở đây.'}</div>` : '');
  if (atBottom) box.scrollTop = box.scrollHeight;
}
/** Khung phụ đề: cập nhật từng dòng theo id thay vì dựng lại toàn bộ khung mỗi token (mượt với phiên dài). */
function capViHTML(c) {
  if (c.state !== 'done' && c.fast) return `<div class="cap-vi pending fast">${esc(c.fast)}</div>`;
  if (c.state === 'queued') return '<div class="cap-vi pending">…</div>';
  return `<div class="cap-vi${c.state === 'done' ? '' : ' pending'}${c.fastFinal ? ' fast' : ''}">${esc(c.vi || '…')}</div>${c.missing.length ? `<div class="miss">⚠︎ ${c.missing.map((h) => `${esc(h.matched)} → ${esc(h.translations[0])}`).join('  ')}</div>` : ''}`;
}
function renderCapsVI() {
  if (C.raf) return;
  C.raf = requestAnimationFrame(() => { C.raf = 0; drawCapsVI(); });
}
function drawCapsVI() {
  const box = $('#cap-vi');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
  $('#cap-live-vi').hidden = !C.caps.some((c) => c.state === 'translating') && !C.volFast;
  if (!C.caps.length && !C.volFast) {
    box.innerHTML = '<div class="muted small">Phụ đề tiếng Việt hiện ở đây: ⚡ bản dịch nhanh trước, bản chuẩn theo glossary thay vào sau.</div>';
    return;
  }
  box.querySelector(':scope > .muted')?.remove();
  const ids = new Set(C.caps.map((c) => String(c.id)));
  for (const el of [...box.querySelectorAll(':scope > [data-cid]')]) if (!ids.has(el.dataset.cid)) el.remove();
  let vol = box.querySelector(':scope > .cap-vol');
  for (const c of C.caps) {
    let el = box.querySelector(`:scope > [data-cid="${c.id}"]`);
    const html = capViHTML(c);
    if (!el) { el = document.createElement('div'); el.dataset.cid = c.id; box.insertBefore(el, vol); }
    if (el._html !== html) { el.innerHTML = html; el._html = html; }
  }
  if (C.volFast) {
    if (!vol) { vol = document.createElement('div'); vol.className = 'cap-vol'; box.append(vol); }
    vol.textContent = '〜 ' + C.volFast;
  } else vol?.remove();
  if (atBottom) box.scrollTop = box.scrollHeight;
}
async function saveCaptions() {
  const done = C.caps.filter((c) => c.vi || c.fast);
  if (!done.length) return;
  const t0 = done[0].at;
  const item = { id: C.savedId || 'c' + Date.now(), kind: 'captions', createdAt: t0, title: `Phụ đề ${new Date(t0).toLocaleString('vi-VN')} — ${autoTitle(done[0].en)}`,
    dir: 'enToVi', engine: llmName() || 'Dịch nhanh', pairs: done.map((c) => ({ source: c.en, translation: c.vi || c.fast, start: (c.at - t0) / 1000 })) };
  C.savedId = item.id;
  if (await idb.put('saved', item)) toast('Đã lưu vào tab Đã lưu');
}

// ============================================================================
// Tab ĐẠI THỂ — đọc mô tả khi phẫu tích, cắt lọc bệnh phẩm (lệnh giọng nói rảnh tay)
// ============================================================================
const G = {
  doc: newGrossDoc(), lang: store.get('grLang', 'vi'), asrMode: store.get('grAsr', 'whisper'),
  running: false, paused: false, volatile: '', rec: null, capture: null,
  chunk: [], chunkLen: 0, silence: 0, speech: 0, queue: [], busy: false, savedId: null, engine: '',
  corrections: store.get('grCorrections', null) || GROSS_DEFAULT_CORRECTIONS,
};
if (!SR && G.asrMode === 'web') G.asrMode = 'whisper';
setPressed($('#gr-lang'), G.lang); setPressed($('#gr-asr'), G.asrMode);
$('#gr-template').innerHTML = GROSS_TEMPLATES.map((t) => `<option value="${t.id}">${esc(t.name)}</option>`).join('');
$('#gr-template').value = store.get('grTemplate', 'biopsy');
$('#gr-return').checked = store.get('grReturn', true);
$('#gr-marker').checked = store.get('grMarker', true);
$('#gr-return').addEventListener('change', (e) => store.set('grReturn', e.target.checked));
$('#gr-marker').addEventListener('change', (e) => store.set('grMarker', e.target.checked));
const grOpts = () => ({ corrections: G.corrections, cassetteReturn: $('#gr-return').checked, inlineMarker: $('#gr-marker').checked });
$('#gr-label').addEventListener('input', (e) => { setGrossPathcode(G.doc, e.target.value.trim().toUpperCase()); renderGross(); });
$('#gr-label').addEventListener('change', (e) => { e.target.value = G.doc.pathcode; });
$('#gr-newcase').addEventListener('click', async () => {
  if (G.running) return;
  if (!G.doc.body.trim() && !G.doc.cassettes.length) { $('#gr-label').value = ''; G.doc = newGrossDoc(); $('#gr-label').focus(); return; }
  await saveGross();
  G.doc = newGrossDoc(); G.savedId = null; $('#gr-label').value = ''; renderGross(); setGrStatus('Đã lưu ca trước · nhập pathcode ca mới'); $('#gr-label').focus();
});
function renderGrossChecklist() {
  const t = GROSS_TEMPLATES.find((x) => x.id === $('#gr-template').value);
  $('#gr-checklist').innerHTML = (t?.items || []).map((i) => `<span>${esc(i)}</span>`).join('');
}
renderGrossChecklist();
$('#gr-template').addEventListener('change', (e) => { store.set('grTemplate', e.target.value); renderGrossChecklist(); });
onSeg($('#gr-lang'), (v) => { G.lang = v; store.set('grLang', v); updateGrossHint(); $('#gr-translate').textContent = v === 'vi' ? 'Dịch sang tiếng Anh' : 'Dịch sang tiếng Việt'; });
onSeg($('#gr-asr'), (v) => { G.asrMode = v; store.set('grAsr', v); updateGrossHint(); });
const grWhisperId = () => store.get('grWhisper', device.webgpu ? 'onnx-community/whisper-large-v3-turbo' : 'onnx-community/whisper-small');
function updateGrossHint() {
  const w = WHISPER_MODELS.find((m) => m.id === grWhisperId()) || WHISPER_MODELS[1];
  $('#gr-hint').textContent = G.asrMode === 'web'
    ? (SR ? 'Bộ nhận dạng của trình duyệt: nhanh, nhưng Chrome gửi âm thanh lên máy chủ Google. Không đọc thông tin định danh người bệnh.' : 'Trình duyệt này không có nhận dạng giọng nói — dùng Whisper.')
    : `Whisper chạy trên máy (${w.name}) — không gửi âm thanh đi đâu; mỗi câu hiện ra sau khi bạn ngừng nói ~0,6 giây. Nói “cát xét A1”, “xuống dòng”, “xoá câu”… — bấm “Lệnh giọng nói” để xem đủ.`;
}
const grTargetLabel = () => (G.doc.target < 0 ? 'Mô tả' : 'Cát xét ' + cassetteLabel(G.doc.cassettes[G.doc.target]) + (G.doc.oneShot ? ' (ghi chú xong quay lại mô tả)' : ''));
const setGrStatus = (t) => { $('#gr-status').textContent = t; };
function grListening() { setGrStatus((G.paused ? 'Tạm dừng — nói “tiếp tục ghi” hoặc bấm ▶' : `Đang nghe · ${grTargetLabel()}`) + (G.heard ? ` · Nghe: “${G.heard.slice(-80)}”` : '')); }

function renderGross() {
  const d = G.doc;
  const live = (i) => (G.running && d.target === i ? `<span class="gr-live${G.paused ? ' paused' : ''}"></span>` : '');
  const vol = (i) => (d.target === i && !G.paused ? esc(G.volatile) : '');
  const block = (i, head, text, ph) => `<div class="gr-block${d.target === i ? ' active' : ''}" data-gi="${i}">
    <div class="gr-head">${head}${live(i)}<span class="grow"></span>${d.target === i ? '' : '<button class="btn ghost tiny" data-gr-target>Ghi vào đây</button>'}${i >= 0 ? '<button class="btn ghost tiny" data-gr-del title="Xoá cát xét">✕</button>' : ''}</div>
    <textarea rows="${i < 0 ? 4 : 2}" placeholder="${ph}" data-gr-text>${esc(text)}</textarea><div class="gr-vol">${vol(i)}</div></div>`;
  $('#gr-doc').innerHTML = block(-1, 'MÔ TẢ ĐẠI THỂ', d.body, 'Bấm micro rồi đọc: “Bệnh phẩm gồm ba mảnh, kích thước…”')
    + d.cassettes.map((c, i) => block(i, `<span class="gr-code">${c.pathcode ? `<span class="gr-pc">${esc(c.pathcode)}</span> · ` : ''}${esc(c.code)}</span>`, c.text, 'Vị trí lấy mẫu…')).join('')
    + (d.cassettes.length ? '' : '<div class="note">Cát xét: nói “cát xét A1”, “cát xét tiếp theo”… hoặc bấm Cát xét +. Danh sách cát xét được ghép vào cuối mô tả.</div>');
  $('#gr-undo').disabled = !d.history.length;
  if (document.activeElement !== $('#gr-label')) $('#gr-label').value = d.pathcode || '';
  const act = $('#gr-doc .gr-block.active');
  if (act && G.running) act.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}
function renderGrossVolatile() {
  const el = $(`#gr-doc .gr-block[data-gi="${G.doc.target}"] .gr-vol`);
  if (el) el.textContent = G.paused ? '' : G.volatile;
}
$('#gr-doc').addEventListener('input', (e) => {
  const ta = e.target.closest('[data-gr-text]'); if (!ta) return;
  const i = +ta.closest('[data-gi]').dataset.gi;
  if (i < 0) G.doc.body = ta.value; else G.doc.cassettes[i].text = ta.value;
});
$('#gr-doc').addEventListener('click', (e) => {
  const blk = e.target.closest('[data-gi]'); if (!blk) return;
  const i = +blk.dataset.gi;
  if (e.target.closest('[data-gr-target]')) { G.doc.target = i; G.doc.oneShot = false; renderGross(); if (G.running) grListening(); }
  if (e.target.closest('[data-gr-del]')) {
    G.doc.history.push({ body: G.doc.body, cassettes: G.doc.cassettes.map((c) => ({ ...c })), target: G.doc.target });
    G.doc.cassettes.splice(i, 1);
    if (G.doc.target >= G.doc.cassettes.length || G.doc.target === i) { G.doc.target = -1; G.doc.oneShot = false; } else if (G.doc.target > i) G.doc.target--;
    renderGross();
  }
});
$('#gr-undo').addEventListener('click', () => { applyDictation(G.doc, [{ type: 'undo' }]); renderGross(); });
$('#gr-next').addEventListener('click', () => { addCassette(G.doc, grOpts()); renderGross(); if (G.running) grListening(); });
$('#gr-to-body').addEventListener('click', () => { G.doc.target = -1; G.doc.oneShot = false; renderGross(); if (G.running) grListening(); });
$('#gr-pause').addEventListener('click', () => { if (!G.running) return; G.paused = !G.paused; G.volatile = ''; grPauseUI(); renderGross(); grListening(); });
function grPauseUI() {
  $('#gr-pause').disabled = !G.running;
  $('#gr-pause span').textContent = G.paused ? 'Tiếp tục' : 'Tạm dừng';
}
$('#gr-mic').addEventListener('click', () => (G.running ? stopGross() : startGross()));

/** Một câu đọc đã chốt từ bộ nhận dạng. */
function grossFinal(text) {
  const t = (text || '').replace(/\[[^\]]*\]|\([^)]*\)/g, ' ').trim();   // Whisper: bỏ [Music]…
  if (!t) return;
  G.heard = t;   // hiện câu máy nghe được (để biết lệnh có được nhận không)
  const signals = applyDictation(G.doc, parseDictation(t), { paused: G.paused, ...grOpts() });
  for (const s of signals) { if (s === 'pause') G.paused = true; if (s === 'resume') G.paused = false; }
  G.volatile = '';
  grPauseUI(); renderGross();
  if (signals.includes('stop')) stopGross(); else if (G.running) grListening();
}

async function startGross() {
  if (G.running) return;
  G.running = true; G.paused = false; G.volatile = ''; G.queue = [];
  $('#gr-mic').classList.add('on'); $('#gr-mic').setAttribute('aria-label', 'Dừng ghi'); grPauseUI();
  try { G.wake = await navigator.wakeLock?.request('screen'); } catch { /* không bắt buộc */ }
  try {
    if (G.asrMode === 'web') {
      if (!SR) throw new Error('Trình duyệt này không có nhận dạng giọng nói — chọn Whisper.');
      const rec = new SR();
      rec.lang = G.lang === 'vi' ? 'vi-VN' : 'en-US'; rec.continuous = true; rec.interimResults = true;
      rec.onresult = (e) => {
        let interim = '';
        for (let i = e.resultIndex; i < e.results.length; i++) {
          const r = e.results[i];
          if (r.isFinal) grossFinal(r[0].transcript); else interim += r[0].transcript;
        }
        G.volatile = interim; renderGrossVolatile();
      };
      rec.onerror = (e) => { if (e.error === 'not-allowed' || e.error === 'service-not-allowed') { setGrStatus('Chưa cấp quyền micro / nhận dạng giọng nói'); stopGross(); } };
      rec.onend = () => { if (G.running && G.rec === rec) { try { rec.start(); } catch { /* */ } } };
      G.rec = rec; rec.start();
      G.engine = 'Nhận dạng của trình duyệt';
    } else {
      setGrStatus('Đang nạp Whisper…');
      await getASR(grWhisperId(), (p, t) => setGrStatus(`Nạp Whisper ${Math.round(p * 100)}% · ${t}`));
      if (!G.running) return;
      G.chunk = []; G.chunkLen = 0; G.silence = 0; G.speech = 0;
      G.capture = await startCapture('mic', onGrossSamples);
      G.engine = (WHISPER_MODELS.find((m) => m.id === grWhisperId()) || {}).name || 'Whisper';
    }
    grListening(); renderGross();
  } catch (e) {
    setGrStatus(e.message || String(e));
    G.running = false; $('#gr-mic').classList.remove('on'); grPauseUI();
  }
}
async function stopGross() {
  if (!G.running) return;
  G.running = false;
  try { G.rec?.stop(); } catch { /* */ }
  G.rec = null;
  G.capture?.stop(); G.capture = null;
  if (G.chunkLen > 16000) pushGrossChunk();
  try { await G.wake?.release(); } catch { /* */ }
  G.volatile = ''; G.paused = false;
  $('#gr-mic').classList.remove('on'); $('#gr-mic').setAttribute('aria-label', 'Bắt đầu ghi'); grPauseUI();
  setGrStatus(G.queue.length || G.busy ? 'Đang nhận dạng nốt…' : 'Đã dừng');
  renderGross();
}
// Whisper: cắt câu khi ngừng nói ≥ 0,6 s (giống tab Phụ đề), câu dài tối đa 12 s
function onGrossSamples(y) {
  if (!G.running) return;
  G.chunk.push(y); G.chunkLen += y.length;
  const loud = rms(y) > 0.012;
  if (loud) { G.speech += y.length; G.silence = 0; } else G.silence += y.length;
  if ((G.silence > 9600 && G.chunkLen > 16000 && G.speech > 3200) || G.chunkLen > 16000 * 12) pushGrossChunk();
  else if (G.silence > 16000 * 2 && G.speech < 3200) { G.chunk = []; G.chunkLen = 0; G.speech = 0; }
  G.volatile = G.speech > 3200 && !G.paused ? '🎙 …' : G.volatile;
}
function pushGrossChunk() {
  const a = new Float32Array(G.chunkLen);
  let o = 0; for (const c of G.chunk) { a.set(c, o); o += c.length; }
  G.chunk = []; G.chunkLen = 0; G.silence = 0; G.speech = 0;
  G.queue.push(a); runGrossQueue();
}
async function runGrossQueue() {
  if (G.busy) return;
  G.busy = true;
  while (G.queue.length) {
    const a = G.queue.shift();
    G.volatile = G.paused ? '' : '…đang nhận dạng'; renderGrossVolatile();
    try {
      const out = await asr.pipe(a, { language: whisperLang(G.lang), task: 'transcribe' });
      grossFinal(out.text || '');
    } catch (e) { setGrStatus('Lỗi Whisper: ' + (e.message || e)); }
    G.volatile = ''; renderGrossVolatile();
  }
  G.busy = false;
  if (!G.running) setGrStatus('Đã dừng');
}

const grossReport = () => grossReportText(G.doc, G.lang);
$('#gr-copy').addEventListener('click', () => copyText(grossReport()));
$('#gr-save').addEventListener('click', saveGross);
async function saveGross() {
  const text = grossReport();
  if (!text) { toast('Chưa có nội dung'); return; }
  const label = G.doc.pathcode;
  const item = { id: G.savedId || 'g' + Date.now(), kind: 'gross', createdAt: Date.now(), pathcode: label,
    title: 'Đại thể · ' + (label || autoTitle(G.doc.body || text)), dir: G.lang === 'vi' ? 'viToEn' : 'enToVi', engine: G.engine || 'Đọc chính tả',
    source: text, translation: '' };
  G.savedId = item.id;
  if (await idb.put('saved', item)) toast('Đã lưu vào tab Đã lưu');
}
$('#gr-translate').addEventListener('click', () => {
  const text = grossReport();
  if (!text) return;
  const dir = G.lang === 'vi' ? 'viToEn' : 'enToVi';
  T.dirMode = dir; store.set('dirMode', dir); setPressed($('#dir-mode'), dir);
  input.value = text; input.dispatchEvent(new Event('input'));
  showTab('translate');
  if (llm.engine) translateInput(); else toast('Nạp mô hình dịch trong Cài đặt rồi bấm Dịch');
});
$('#gr-clear').addEventListener('click', (e) => {
  if (G.running) return;
  const b = e.currentTarget;
  if (b.dataset.confirm !== '1') { b.dataset.confirm = '1'; b.textContent = 'Bấm lần nữa để xoá'; setTimeout(() => { b.dataset.confirm = ''; b.textContent = 'Xoá trang'; }, 3000); return; }
  b.dataset.confirm = ''; b.textContent = 'Xoá trang';
  G.doc = newGrossDoc(G.doc.pathcode); G.savedId = null; renderGross(); setGrStatus('');
});
$('#gr-help').addEventListener('click', () => modal(`<h3>Lệnh giọng nói</h3>
  <div class="kv small">
    <span>“mã ca G P B hai bốn gạch …”</span><span>Đặt pathcode cho ca (gõ tay chính xác hơn)</span>
    <span>“… mực xanh, cát xét A1 diện cắt gần”</span><span>Chèn (A1) vào mô tả, ghi “diện cắt gần” vào A1, rồi tự quay lại mô tả</span>
    <span>“cát xét A1”, “mẫu bê hai”, “cát xét số 3”</span><span>Mở cát xét — câu kế tiếp là ghi chú của cát xét đó</span>
    <span>“cát xét tiếp theo”, “khối tiếp”</span><span>Cát xét kế tiếp (A1 → A2)</span>
    <span>“quay lại mô tả”</span><span>Ghi tiếp vào phần mô tả</span>
    <span>“xuống dòng”, “đoạn mới”, “gạch đầu dòng”</span><span>Định dạng</span>
    <span>“dấu chấm”, “dấu phẩy”, “dấu hai chấm”, “mở / đóng ngoặc”</span><span>Dấu câu</span>
    <span>“xoá câu”, “hoàn tác”</span><span>Bỏ câu vừa đọc</span>
    <span>“tạm dừng” / “tiếp tục ghi”</span><span>Ngừng nghe khi trao đổi với KTV</span>
    <span>“dừng ghi”</span><span>Kết thúc</span>
  </div>
  <h3 style="margin-top:14px">Số đo tự chuẩn hoá</h3>
  <div class="kv small">
    <span>bốn nhân ba nhân hai xăng ti mét</span><span class="mono">4 x 3 x 2 cm</span>
    <span>hai phẩy năm phân / hai phân rưỡi</span><span class="mono">2,5 cm</span>
    <span>từ hai đến năm mi li mét</span><span class="mono">từ 2 đến 5 mm</span>
    <span>nặng hai mươi lăm gam</span><span class="mono">nặng 25 g</span>
    <span>ba mảnh, mười hai hạch</span><span class="mono">3 mảnh, 12 hạch</span>
  </div>
  <div class="note" style="margin-top:12px">Chỉ đổi chữ số khi đứng cạnh đơn vị, “nhân” hoặc danh từ đếm — “một đoạn đại tràng” giữ nguyên. Đeo tai nghe Bluetooth để đứng xa máy; màn hình được giữ sáng khi đang ghi.</div>
  <div class="foot"><button class="btn primary" data-close>Đóng</button></div>`));
$('#gr-fix').addEventListener('click', () => {
  const row = (c, k) => `<div class="row" data-k="${k}"><input value="${esc(c.from)}" data-f style="flex:1;min-width:120px"><span class="muted">→</span><input value="${esc(c.to)}" data-t style="flex:1;min-width:120px"><button class="btn ghost" data-x>✕</button></div>`;
  const m = modal(`<h3>Sửa lỗi nhận dạng</h3><div class="small muted">Máy nghe thành → sửa thành. Áp dụng cho các câu đọc sau.</div>
    <div class="stack" id="gf-list">${G.corrections.map(row).join('')}</div>
    <div class="row"><button class="btn" id="gf-add">Thêm dòng</button><button class="btn ghost" id="gf-reset">Khôi phục mặc định</button></div>
    <div class="foot"><button class="btn primary" id="gf-save">Lưu</button></div>`);
  const list = $('#gf-list', m.el);
  $('#gf-add', m.el).addEventListener('click', () => list.insertAdjacentHTML('afterbegin', row({ from: '', to: '' }, Date.now())));
  $('#gf-reset', m.el).addEventListener('click', () => { list.innerHTML = GROSS_DEFAULT_CORRECTIONS.map(row).join(''); });
  list.addEventListener('click', (e) => { if (e.target.closest('[data-x]')) e.target.closest('[data-k]').remove(); });
  $('#gf-save', m.el).addEventListener('click', () => {
    G.corrections = $$('[data-k]', list).map((r) => ({ from: $('[data-f]', r).value.trim(), to: $('[data-t]', r).value.trim() })).filter((c) => c.from && c.to);
    store.set('grCorrections', G.corrections); m.close(); toast('Đã lưu');
  });
});
updateGrossHint();

// ============================================================================
// Tab CHÉP LỜI
// ============================================================================
const R = { lang: store.get('trLang', 'en'), display: 'source', segs: [], file: null, url: null, run: 0, busy: false, translating: false, trRun: 0, duration: 0, elapsed: 0, savedId: null };
setPressed($('#tr-lang'), R.lang);
onSeg($('#tr-lang'), (v) => { R.lang = v; store.set('trLang', v); });
onSeg($('#tr-display'), (v) => { R.display = v; renderTimeline(); });
$('#tr-model').innerHTML = WHISPER_MODELS.map((m) => `<option value="${m.id}">${m.name} · ${m.size} — ${m.note}</option>`).join('');
$('#tr-model').value = store.get('trWhisper', device.mobile ? 'onnx-community/whisper-small' : WHISPER_MODELS[0].id);
$('#tr-model').addEventListener('change', (e) => store.set('trWhisper', e.target.value));
$('#tr-file').addEventListener('change', (e) => { const f = e.target.files?.[0]; if (f) transcribeFile(f); e.target.value = ''; });
for (const [zone, handler] of [['#tr-drop', (files) => files[0] && transcribeFile(files[0])], ['#ocr-drop', (files) => addOcrFiles(files)]]) {
  const z = $(zone);
  z.addEventListener('dragover', (e) => { e.preventDefault(); z.classList.add('over'); });
  z.addEventListener('dragleave', () => z.classList.remove('over'));
  z.addEventListener('drop', (e) => { e.preventDefault(); z.classList.remove('over'); handler([...e.dataTransfer.files]); });
}
$('#tr-cancel').addEventListener('click', () => { R.run++; R.busy = false; $('#tr-progress').hidden = true; });

async function decodeTo16k(file) {
  const buf = await file.arrayBuffer();
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  let audio;
  try { audio = await ctx.decodeAudioData(buf); } finally { try { ctx.close(); } catch { /* */ } }
  const off = new OfflineAudioContext(1, Math.max(1, Math.ceil(audio.duration * 16000)), 16000);
  const src = off.createBufferSource(); src.buffer = audio; src.connect(off.destination); src.start();
  const out = await off.startRendering();
  return out.getChannelData(0);
}
function quietestCut(s, from, to) {
  const frame = 1600; let best = to, bestE = Infinity;
  for (let i = Math.max(from, to - 48000); i + frame <= to; i += 800) {
    let e = 0; for (let j = i; j < i + frame; j++) e += s[j] * s[j];
    if (e < bestE) { bestE = e; best = i + 800; }
  }
  return best;
}
async function transcribeFile(file) {
  const run = ++R.run;
  const live = () => run === R.run;
  R.busy = true; R.segs = []; R.file = file; R.savedId = null;
  if (R.url) URL.revokeObjectURL(R.url);
  R.url = URL.createObjectURL(file);
  $('#tr-error').hidden = true; $('#tr-result').hidden = true; $('#tr-progress').hidden = false;
  const setP = (p, s) => { $('#tr-bar').value = p; $('#tr-pct').textContent = Math.round(p * 100) + '%'; if (s) $('#tr-status').textContent = s; };
  const t0 = performance.now();
  try {
    setP(0, `Đang trích âm thanh từ ${file.name}…`);
    const audio = await decodeTo16k(file);
    if (!live()) return;
    R.duration = audio.length / 16000;
    const modelId = $('#tr-model').value;
    const pipe = await getASR(modelId, (p, t) => setP(0.05 * p, `Đang tải ${WHISPER_MODELS.find((m) => m.id === modelId)?.name} · ${t} (chỉ lần đầu)`));
    if (!live()) return;
    setP(0.05, 'Đang chép lời…');
    $('#tr-result').hidden = false;
    renderTimeline();
    const win = 28 * 16000;
    let pos = 0;
    while (pos < audio.length) {
      if (!live()) return;
      let end = Math.min(audio.length, pos + win);
      if (end < audio.length) end = quietestCut(audio, pos + 16000, end);
      const slice = audio.subarray(pos, end);
      if (rms(slice) > 0.003) {
        const out = await pipe(slice, { language: whisperLang(R.lang), task: 'transcribe', return_timestamps: true });
        if (!live()) return;
        let segs = whisperChunksToSegments(out.chunks, pos / 16000, end / 16000);
        if (!segs.length && out.text?.trim()) segs = [{ start: pos / 16000, end: end / 16000, text: out.text.trim() }];
        for (const s of segs) R.segs.push({ id: R.segs.length, ...s, translation: '', isFast: false });
        renderTimeline();
        if (fast.enabled() && fastActive(trDir())) fastTranslateSegs(segs.map((s) => R.segs.find((x) => x.start === s.start && x.text === s.text)).filter(Boolean));
      }
      pos = end;
      setP(0.05 + 0.95 * (pos / audio.length), 'Đang chép lời…');
    }
    R.elapsed = (performance.now() - t0) / 1000;
    $('#tr-status').textContent = 'Chép lời hoàn tất';
    $('#tr-progress').hidden = true;
  } catch (e) {
    if (!live()) return;
    $('#tr-progress').hidden = true;
    $('#tr-error').textContent = (e.message || String(e)) + (String(e).includes('decode') ? ' — trình duyệt không giải mã được tệp này; thử chuyển sang m4a/mp3.' : '');
    $('#tr-error').hidden = false;
  } finally { if (live()) { R.busy = false; renderTimeline(); } }
}
const trDir = () => (R.lang === 'vi' ? DIR.viToEn : DIR.enToVi);
async function fastTranslateSegs(segs) {
  const dir = trDir();
  for (const s of segs) {
    if (s.translation) continue;
    const t = await fastTranslate(s.text, dir);
    if (t && !s.translation) { s.translation = t; s.isFast = true; }
  }
  renderTimeline();
}
$('#tr-fast').addEventListener('click', async () => {
  const dir = trDir();
  try { await fastInstance(dir, true, (p) => { $('#tr-summary').textContent = `Tải gói ${dir.label} ${Math.round(p * 100)}%`; }); } catch { /* */ }
  if (!fastActive(dir)) { toast(fast.supported ? 'Chưa tải được gói ngôn ngữ dịch nhanh' : 'Dịch nhanh cần Chrome bản mới trên máy tính'); return; }
  fastTranslateSegs(R.segs);
});
$('#tr-translate').addEventListener('click', translateTranscript);
$('#tr-stop-translate').addEventListener('click', () => { R.trRun++; R.translating = false; renderTimeline(); });
async function translateTranscript() {
  if (!llm.engine) { toast('Nạp mô hình dịch trong Cài đặt trước'); openSettings(); return; }
  const run = ++R.trRun;
  R.translating = true; renderTimeline();
  const dir = trDir();
  const tried = new Set();
  while (run === R.trRun) {
    const s = R.segs.find((x) => (!x.translation || x.isFast) && !tried.has(x.id));
    if (!s) { if (R.busy) { await sleep(400); continue; } break; }
    tried.add(s.id);
    const stream = !s.translation;
    s.working = true; renderTimeline();
    try {
      const st = await translateLLM(s.text, hitsFor(s.text, dir), dir, (t) => { if (stream && run === R.trRun) { s.translation = t; renderTlRow(s); } }, () => run !== R.trRun);
      if (st.text) { s.translation = st.text; s.isFast = false; }
    } catch (e) { if (!(e instanceof Cancelled)) toast(e.message); break; } finally { s.working = false; }
    renderTlRow(s);
  }
  if (run === R.trRun) { R.translating = false; renderTimeline(); }
}
function tlRowHTML(s) {
  const showSrc = R.display !== 'translation' || !s.translation;
  const showTr = R.display !== 'source' && s.translation;
  return `<div class="tl-row" id="tl-${s.id}" data-id="${s.id}">
    <button class="tl-time" data-seek="${s.start}">${clock(s.start)}</button>
    <div class="tl-text">
      ${showSrc ? `<div class="${R.display === 'bilingual' && s.translation ? 't2' : ''}" contenteditable="true" data-edit="text">${esc(s.text)}</div>` : ''}
      ${showTr ? `<div class="${s.isFast ? 'fast' : ''}" contenteditable="true" data-edit="translation">${esc(s.translation)}</div>` : ''}
      ${s.working ? '<div class="tiny muted">đang dịch…</div>' : ''}
    </div></div>`;
}
function renderTlRow(s) { const el = $(`#tl-${s.id}`); if (el) el.outerHTML = tlRowHTML(s); }
function renderTimeline() {
  $('#tr-list').innerHTML = R.segs.map(tlRowHTML).join('') || '<div class="muted small" style="padding:8px">Các đoạn có mốc giờ sẽ hiện dần ở đây.</div>';
  const refined = R.segs.filter((s) => s.translation && !s.isFast).length;
  $('#tr-summary').textContent = `${R.segs.length} đoạn${R.duration ? ' · ' + clock(R.duration) : ''}${R.elapsed ? ' · ' + R.elapsed.toFixed(0) + ' s' : ''} · ${R.lang === 'vi' ? 'Tiếng Việt' : 'English'}`;
  $('#tr-translate').hidden = R.translating; $('#tr-stop-translate').hidden = !R.translating;
  $('#tr-translate').textContent = refined === 0 ? `Dịch chuẩn sang ${trDir().target.replace('Tiếng', 'tiếng')} (glossary)` : refined < R.segs.length ? `Dịch tiếp ${refined}/${R.segs.length}` : `Đã dịch ${R.segs.length} đoạn`;
  $('#tr-translate').disabled = !R.segs.length || refined === R.segs.length;
  $('#tr-fast').hidden = !fast.supported;
  const pl = $('#tr-player');
  if (R.url && pl.dataset.url !== R.url) { pl.innerHTML = `<audio controls preload="metadata" src="${R.url}"></audio>`; pl.dataset.url = R.url; }
  pl.hidden = !R.url;
}
$('#tr-list').addEventListener('click', (e) => {
  const b = e.target.closest('[data-seek]');
  if (!b) return;
  const a = $('#tr-player audio');
  if (a) { a.currentTime = Number(b.dataset.seek); a.play().catch(() => {}); }
});
$('#tr-list').addEventListener('focusout', (e) => {
  const f = e.target.closest('[data-edit]');
  if (!f) return;
  const s = R.segs.find((x) => x.id === Number(f.closest('.tl-row').dataset.id));
  if (!s) return;
  const v = f.innerText.trim();
  if (f.dataset.edit === 'text') s.text = v; else if (v !== s.translation) { s.translation = v; s.isFast = false; }
});
$('#tr-player').addEventListener('timeupdate', (e) => {
  const t = e.target.currentTime;
  const cur = [...R.segs].reverse().find((s) => s.start <= t + 0.05);
  $$('.tl-row.now').forEach((r) => r.classList.remove('now'));
  if (cur) { const el = $(`#tl-${cur.id}`); el?.classList.add('now'); if (!e.target.paused) el?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); }
}, true);
$('#tr-copy').addEventListener('change', (e) => {
  const v = e.target.value; e.target.value = '';
  if (!v) return;
  const [content, t] = v.split('-');
  copyText(t ? renderSubtitles(R.segs, 'txt', content) : plainSubtitles(R.segs, content));
});
$('#tr-export').addEventListener('change', (e) => {
  const v = e.target.value; e.target.value = '';
  if (!v) return;
  const [fmt, content] = v.split(':');
  const base = (R.file?.name || 'phude').replace(/\.[^.]+$/, '');
  const suffix = content === 'source' ? R.lang : content === 'translation' ? trDir().tgt : `${R.lang}-${trDir().tgt}`;
  downloadText(`${base}.${suffix}.${fmt}`, renderSubtitles(R.segs, fmt, content));
});
$('#tr-save').addEventListener('click', async () => {
  if (!R.segs.length) return;
  const item = { id: R.savedId || 't' + Date.now(), kind: 'transcript', createdAt: Date.now(), title: `Chép lời — ${R.file?.name || ''}`, dir: trDir().id,
    engine: (WHISPER_MODELS.find((m) => m.id === asr.id)?.name || 'Whisper') + (llm.engine ? ' · ' + llmName() : ''),
    pairs: R.segs.map((s) => ({ source: s.text, translation: s.translation, start: s.start, end: s.end })), duration: R.duration };
  R.savedId = item.id;
  toast((await idb.put('saved', item)) ? 'Đã lưu vào tab Đã lưu' : 'Không lưu được');
});

// ============================================================================
// Tab ẢNH (Tesseract.js + pdf.js)
// ============================================================================
const TESSERACT_URL = 'https://cdn.jsdelivr.net/npm/tesseract.js@6.0.1/dist/tesseract.min.js';
const PDFJS_URL = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.min.mjs';
const PDFJS_WORKER = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.worker.min.mjs';
const O = { lang: store.get('ocrLang', 'vie+eng'), pages: [], worker: null, workerLang: null, busy: false };
setPressed($('#ocr-lang'), O.lang);
onSeg($('#ocr-lang'), async (v) => { O.lang = v; store.set('ocrLang', v); if (O.pages.length) { for (const p of O.pages) if (!p.pdfText) p.text = null; await runOcr(); } });
$('#ocr-join').checked = store.get('ocrJoin', true);
$('#ocr-join').addEventListener('change', (e) => { store.set('ocrJoin', e.target.checked); rebuildOcrText(); });
$('#ocr-file').addEventListener('change', (e) => { addOcrFiles([...e.target.files]); e.target.value = ''; });
document.addEventListener('paste', (e) => {
  if (currentTab !== 'image') return;
  const files = [...(e.clipboardData?.items || [])].filter((i) => i.type.startsWith('image/')).map((i) => i.getAsFile()).filter(Boolean);
  if (files.length) { e.preventDefault(); addOcrFiles(files); }
});
const ocrStatus = (s) => { $('#ocr-status').textContent = s; };

async function getOcrWorker() {
  if (O.worker && O.workerLang === O.lang) return O.worker;
  await loadScript(TESSERACT_URL);
  if (O.worker) { try { await O.worker.terminate(); } catch { /* */ } }
  ocrStatus('Đang tải bộ nhận dạng chữ (lần đầu ~20 MB)…');
  O.worker = await window.Tesseract.createWorker(O.lang.split('+'), 1, {
    logger: (m) => { if (m.status && typeof m.progress === 'number') ocrStatus(`${m.status} ${Math.round(m.progress * 100)}%`); },
  });
  O.workerLang = O.lang;
  return O.worker;
}
async function addOcrFiles(files) {
  for (const f of files) {
    if (f.type === 'application/pdf' || /\.pdf$/i.test(f.name)) await addPdf(f);
    else if (f.type.startsWith('image/')) O.pages.push({ id: Math.random(), label: f.name || 'Ảnh dán', url: URL.createObjectURL(f), src: f, text: null });
  }
  renderThumbs();
  await runOcr();
}
async function addPdf(file) {
  ocrStatus('Đang mở PDF…');
  const pdfjs = await import(PDFJS_URL);
  if (!pdfjs.GlobalWorkerOptions.workerPort) {
    const blob = new Blob([`import "${PDFJS_WORKER}";`], { type: 'text/javascript' });
    pdfjs.GlobalWorkerOptions.workerPort = new Worker(URL.createObjectURL(blob), { type: 'module' });
  }
  const doc = await pdfjs.getDocument({ data: await file.arrayBuffer() }).promise;
  const n = Math.min(doc.numPages, 60);
  for (let i = 1; i <= n; i++) {
    ocrStatus(`Đang đọc trang ${i}/${doc.numPages}…`);
    const page = await doc.getPage(i);
    const tc = await page.getTextContent();
    const raw = tc.items.map((it) => it.str + (it.hasEOL ? '\n' : ' ')).join('').replace(/[ \t]+\n/g, '\n').trim();
    const vp = page.getViewport({ scale: 2 });
    const canvas = document.createElement('canvas');
    canvas.width = vp.width; canvas.height = vp.height;
    await page.render({ canvasContext: canvas.getContext('2d'), viewport: vp }).promise;
    const blob = await new Promise((r) => canvas.toBlob(r, 'image/png'));
    const usable = (raw.match(/\p{L}/gu) || []).length >= 20 ? raw : null;
    O.pages.push({ id: Math.random(), label: `${file.name} · tr. ${i}`, url: URL.createObjectURL(blob), src: blob, text: usable, pdfText: !!usable });
  }
  if (doc.numPages > 60) toast('Chỉ đọc 60 trang đầu của PDF');
}
async function runOcr() {
  if (O.busy) return;
  O.busy = true;
  try {
    const todo = O.pages.filter((p) => p.text == null);
    if (todo.length) {
      const w = await getOcrWorker();
      for (const [i, p] of todo.entries()) {
        ocrStatus(`Đang nhận dạng ${i + 1}/${todo.length}…`);
        const { data } = await w.recognize(p.src);
        p.text = (data.text || '').trim(); p.conf = data.confidence; renderThumbs();
      }
    }
    const confs = O.pages.filter((p) => p.conf != null).map((p) => p.conf);
    ocrStatus(confs.length ? `${O.pages.length} ảnh/trang · độ tin cậy trung bình ${Math.round(confs.reduce((a, b) => a + b, 0) / confs.length)}%` : O.pages.length ? `${O.pages.length} trang` : '');
  } catch (e) { ocrStatus('Lỗi: ' + (e.message || e)); } finally { O.busy = false; }
  rebuildOcrText();
}
function joinWrapped(text) {
  if (!$('#ocr-join').checked) return text;
  return text.replace(/([^\n.:;!?…)])\n(?=[\p{Ll},])/gu, '$1 ').replace(/,\n/g, ', ');
}
function rebuildOcrText() {
  const text = O.pages.map((p) => (p.pdfText ? p.text : joinWrapped(p.text || ''))).filter(Boolean).join('\n\n');
  $('#ocr-text').value = text;
  $('#ocr-result').hidden = !O.pages.length;
  $('#ocr-count').textContent = `${text.length} ký tự`;
}
function renderThumbs() {
  $('#ocr-thumbs').innerHTML = O.pages.map((p) => `<div class="thumb"><img src="${p.url}" alt=""><span>${p.text == null ? 'đang đọc…' : p.pdfText ? 'lớp chữ PDF' : (p.text.split('\n').length + ' dòng')}</span>
    <button class="btn ghost tiny" data-rm="${p.id}">Bỏ</button></div>`).join('');
}
$('#ocr-thumbs').addEventListener('click', (e) => {
  const b = e.target.closest('[data-rm]');
  if (!b || O.busy) return;
  O.pages = O.pages.filter((p) => String(p.id) !== b.dataset.rm); renderThumbs(); rebuildOcrText();
});
$('#ocr-copy').addEventListener('click', () => copyText($('#ocr-text').value));
$$('[data-ocr-dir]').forEach((b) => b.addEventListener('click', () => {
  const text = $('#ocr-text').value.trim();
  if (!text) return;
  stopTranslate();
  input.value = text;
  T.dirMode = b.dataset.ocrDir; store.set('dirMode', T.dirMode); setPressed($('#dir-mode'), T.dirMode);
  showTab('translate'); refreshInputMeta();
  if (llm.engine) translateInput(); else toast('Văn bản đã ở ô nhập — nạp mô hình (Cài đặt) để dịch');
}));

// ============================================================================
// Tab THUẬT NGỮ
// ============================================================================
async function renderGlossary() {
  const q = $('#gl-search').value.trim().toLowerCase();
  const rows = [...userEntries.slice().reverse(), ...GL.entries].filter((e) => !q || e.en.toLowerCase().includes(q) || e.vi.toLowerCase().includes(q));
  $('#gl-title').textContent = q ? `Kết quả (${rows.length})` : `Glossary · ${GL.entries.length} mục Vitranslate + ${userEntries.length} của bạn`;
  $('#gl-body').innerHTML = rows.slice(0, 400).map((e) => `<tr><td><b>${esc(e.en)}</b>${e.isUser ? '<span class="user">CỦA TÔI</span>' : ''}</td><td>${esc(e.vi)}</td><td class="small muted">${esc(e.note)}</td>
    <td>${e.isUser ? `<button class="btn ghost tiny" data-del-term="${e.id}">Xoá</button>` : ''}</td></tr>`).join('')
    + (rows.length > 400 ? `<tr><td colspan="4" class="muted small">… còn ${rows.length - 400} mục, hãy tìm cụ thể hơn</td></tr>` : '');
  const sugg = (await idb.all('sugg')).sort((a, b) => a.createdAt - b.createdAt);
  $('#review-card').hidden = !sugg.length;
  $('#learned-count').textContent = `Đã học ${store.get('learned', 0)} thuật ngữ`;
  $('#review-list').innerHTML = sugg.map((s) => `
    <div class="seg-out" data-sugg="${s.id}">
      <div class="grid-2" style="gap:8px"><input type="text" value="${esc(s.english)}" data-f="en"><input type="text" value="${esc(s.vietnamese)}" data-f="vi"></div>
      ${s.existingVi ? `<div class="tiny warn">Glossary hiện có: ${esc(s.existingVi)} — duyệt sẽ thay bằng bản mới</div>` : ''}
      ${s.note ? `<div class="small muted">${esc(s.note)}</div>` : ''}
      <div class="row"><span class="tiny muted">${esc(s.model)}</span><div style="flex:1"></div><button class="btn ghost" data-act="reject">Bỏ qua</button><button class="btn primary" data-act="approve">Duyệt</button></div>
    </div>`).join('');
}
$('#gl-search').addEventListener('input', renderGlossary);
$('#gl-body').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-del-term]');
  if (!b) return;
  await idb.del('user', Number(b.dataset.delTerm));
  userEntries = await idb.all('user'); rebuildMatchers(); renderGlossary(); refreshInputMeta();
});
$('#btn-add-term').addEventListener('click', async () => {
  const ok = await addUserEntry($('#add-en').value, $('#add-vi').value, $('#add-note').value.trim());
  if (!ok) { toast('Nhập đủ tiếng Anh và tiếng Việt'); return; }
  $('#add-en').value = ''; $('#add-vi').value = ''; $('#add-note').value = '';
  toast('Đã thêm thuật ngữ'); renderGlossary(); refreshInputMeta();
});
$('#review-list').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-act]');
  if (!b) return;
  const card = b.closest('[data-sugg]');
  const s = (await idb.all('sugg')).find((x) => x.id === card.dataset.sugg);
  if (!s) return;
  if (b.dataset.act === 'approve') {
    const en = $('[data-f="en"]', card).value.trim(), vi = $('[data-f="vi"]', card).value.trim();
    const date = new Date().toLocaleDateString('vi-VN');
    await addUserEntry(en, vi, `Claude đề xuất · BS duyệt ${date}${s.note ? ' · ' + s.note : ''}`);
    store.set('learned', store.get('learned', 0) + 1);
  } else {
    const meta = (await idb.get('meta', 'rejected')) || { id: 'rejected', keys: [] };
    meta.keys.push(`${s.english.toLowerCase()}→${s.vietnamese.toLowerCase()}`);
    await idb.put('meta', meta);
  }
  await idb.del('sugg', s.id);
  await refreshBadge(); renderGlossary(); refreshInputMeta();
});

// ============================================================================
// Tab ĐÃ LƯU
// ============================================================================
let svFilter = 'all';
onSeg($('#sv-filter'), (v) => { svFilter = v; renderSaved(); });
$('#sv-search').addEventListener('input', renderSaved);
async function renderSaved() {
  const q = $('#sv-search').value.trim().toLowerCase();
  const items = (await idb.all('saved')).sort((a, b) => b.createdAt - a.createdAt)
    .filter((i) => svFilter === 'all' || (svFilter === 'text' ? i.kind === 'text' : svFilter === 'gross' ? i.kind === 'gross' : !!i.pairs))
    .filter((i) => !q || JSON.stringify(i).toLowerCase().includes(q));
  $('#sv-empty').hidden = items.length > 0;
  $('#sv-list').innerHTML = items.map((i) => `<button class="item" data-sv="${i.id}"><span class="t">${esc(i.title)}</span>
    <span class="small muted">${new Date(i.createdAt).toLocaleString('vi-VN')} · ${i.kind === 'text' ? 'Văn bản' : i.kind === 'gross' ? 'Đại thể' : i.kind === 'captions' ? 'Phụ đề' : 'Chép lời'} · ${esc(DIR[i.dir]?.label || '')}${i.pairs ? ' · ' + i.pairs.length + ' đoạn' : ''}${i.claude ? ' · Claude' : ''}</span></button>`).join('');
}
function savedExport(i) {
  const d = DIR[i.dir] || DIR.enToVi;
  let out = `${i.title}\n${new Date(i.createdAt).toLocaleString('vi-VN')} · ${d.label} · ${i.engine}\n`;
  if (i.kind === 'gross') {
    out += `\n— Mô tả đại thể —\n${i.source}\n`;
    if (i.translation) out += `\n— ${d.target} —\n${i.translation}\n`;
  } else if (i.kind === 'text') {
    out += `\n— ${d.source} —\n${i.source}\n\n— ${d.target} (offline) —\n${i.translation}\n`;
    if (i.claude) out += `\n— ${d.target} (${i.claudeModel || 'Claude'}) —\n${i.claude}\n`;
  } else for (const p of i.pairs) out += `\n[${clock(p.start)}]\n${p.source}\n${p.translation}\n`;
  return out;
}
const savedSegs = (i) => i.pairs.map((p, k) => ({ start: p.start, end: p.end ?? Math.min((i.pairs[k + 1]?.start ?? p.start + 4), p.start + 8), text: p.source, translation: p.translation }));
$('#sv-list').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-sv]');
  if (!b) return;
  const i = (await idb.all('saved')).find((x) => x.id === b.dataset.sv);
  if (!i) return;
  const d = DIR[i.dir] || DIR.enToVi;
  const body = i.kind === 'gross'
    ? `<div class="preview" style="white-space:pre-wrap">${esc(i.source)}</div>`
    : i.kind === 'text'
    ? `<div class="stack"><div class="tiny muted">${d.source}</div><div class="preview">${esc(i.source)}</div>
       ${i.translation ? `<div class="tiny muted">${d.target} · offline</div><div class="preview">${esc(i.translation)}</div>` : ''}
       ${i.claude ? `<div class="tiny muted">${d.target} · ${esc(i.claudeModel || 'Claude')}</div><div class="preview">${esc(i.claude)}</div>` : ''}</div>`
    : `<div class="preview" style="max-height:420px">${i.pairs.map((p) => `<div style="margin-bottom:10px"><span class="mono" style="color:var(--eosin)">${clock(p.start)}</span><br>${esc(p.source)}<br><b>${esc(p.translation)}</b></div>`).join('')}</div>`;
  const m = modal(`<h3>${esc(i.title)}</h3><div class="small muted">${new Date(i.createdAt).toLocaleString('vi-VN')} · ${d.label} · ${esc(i.engine)}</div>${body}
    <div class="foot"><button class="btn danger" id="sv-del">Xoá</button><div style="flex:1"></div>
    ${i.pairs ? '<button class="btn" id="sv-srt">Tải SRT song ngữ</button>' : ''}
    <button class="btn" id="sv-dl">Tải .txt</button><button class="btn" id="sv-copy">Chép tất cả</button><button class="btn primary" data-close>Đóng</button></div>`);
  $('#sv-copy', m.el).addEventListener('click', () => copyText(savedExport(i)));
  $('#sv-dl', m.el).addEventListener('click', () => downloadText(i.title + '.txt', savedExport(i)));
  $('#sv-srt', m.el)?.addEventListener('click', () => downloadText(i.title + '.srt', renderSubtitles(savedSegs(i), 'srt', 'bilingual')));
  $('#sv-del', m.el).addEventListener('click', async () => {
    const btn = $('#sv-del', m.el);
    if (btn.dataset.confirm !== '1') { btn.dataset.confirm = '1'; btn.textContent = 'Bấm lần nữa để xoá'; return; }
    await idb.del('saved', i.id); m.close(); renderSaved();
  });
});

// ============================================================================
// Cài đặt
// ============================================================================
let settingsModal = null;
function refreshSettingsProgress() {
  if (!settingsModal) return;
  const p = $('#st-llm-progress', settingsModal.el);
  if (!p) return;
  p.hidden = !llm.loading;
  $('progress', p).value = llm.progress;
  $('.small', p).textContent = llm.progressText;
  $('#st-llm-status', settingsModal.el).innerHTML = llm.engine ? `<span class="ok">Đã nạp ${esc(llmName())}${llm.engine.local ? '' : ' · chạy trên máy'}</span>` : llm.error ? `<span class="danger">${esc(llm.error)}</span>` : 'Chưa nạp';
  $('#st-llm-load', settingsModal.el).disabled = llm.loading;
}
async function openSettings(focus) {
  await checkDevice();
  const savedLLM = store.get('llmModel', device.mobile ? 'Qwen3.5-2B-q4f16_1-MLC' : 'Qwen3.5-4B-q4f16_1-MLC');
  const fastStates = fast.supported ? await Promise.all([fastAvailability(DIR.enToVi), fastAvailability(DIR.viToEn)]) : [];
  const fastLabel = (s) => ({ available: '<span class="ok">sẵn sàng</span>', downloadable: 'cần tải gói', downloading: 'đang tải…', unavailable: 'không hỗ trợ', unknown: 'chưa rõ — bấm Tải gói' }[s] || 'không hỗ trợ');
  const voices = ('speechSynthesis' in window ? speechSynthesis.getVoices() : []).filter((v) => v.lang?.toLowerCase().startsWith('vi'));
  settingsModal = modal(`
    <h3>Cài đặt</h3>
    <div class="note small">Thiết bị: WebGPU ${device.webgpu ? '<b class="ok">có</b>' : '<b class="danger">không có</b>'}${device.webgpu ? ` · fp16 ${device.f16 ? 'có' : 'không'}` : ''}.
      ${location.protocol === 'file:' ? ' Đang mở trực tiếp từ tệp: nên mở qua máy chủ cục bộ (xem README) để trình duyệt giữ mô hình đã tải.' : ''}
      ${device.webgpu ? '' : ' Không có WebGPU: mô hình dịch không chạy được; Whisper chạy chậm bằng CPU. Dùng Chrome / Edge mới trên máy tính hoặc Safari iOS 26+.'}</div>

    <div class="card" style="box-shadow:none">
      <div class="card-head"><h2>Mô hình dịch offline</h2></div>
      <select id="st-llm">${LLM_MODELS.map((m) => `<option value="${m.id}" ${m.id === savedLLM ? 'selected' : ''}>${m.name} · ${m.size} — ${m.note}</option>`).join('')}
        <option value="local" ${savedLLM === 'local' ? 'selected' : ''}>Máy chủ cục bộ (Ollama / LM Studio) — TranslateGemma 12B/27B, Hunyuan-MT-7B…</option></select>
      <div class="stack" id="st-local" ${savedLLM === 'local' ? '' : 'hidden'}>
        <div class="row"><input id="st-local-url" value="${esc(localCfg.url())}" placeholder="${LOCAL_DEFAULT_URL}" style="flex:1;min-width:200px">
          <button class="btn ghost" id="st-local-list">Liệt kê mô hình</button></div>
        <div class="row"><input id="st-local-model" list="st-local-models" value="${esc(localCfg.model())}" placeholder="translategemma:27b" style="flex:1;min-width:200px"><datalist id="st-local-models"></datalist></div>
        <div class="tiny muted">Chạy mô hình lớn trên PC/Mac của bạn rồi app gọi qua mạng nội bộ — văn bản không ra Internet.
          Ollama: <span class="mono">ollama pull translategemma:27b</span> (17 GB, cần GPU ≥ 20 GB hoặc Mac ≥ 32 GB) hoặc <span class="mono">translategemma:12b</span> (8 GB);
          đặt <span class="mono">OLLAMA_ORIGINS=*</span> để trình duyệt gọi được. LM Studio: tải bản GGUF (vd. Hunyuan-MT-7B, translategemma-27b), Developer → Enable CORS → Start Server, địa chỉ <span class="mono">http://localhost:1234/v1</span>.
          Mở app từ máy khác trong mạng LAN: thay localhost bằng IP của máy chạy mô hình.</div>
      </div>
      <div class="row"><button class="btn primary" id="st-llm-load">Nạp mô hình</button><span class="small" id="st-llm-status"></span></div>
      <div class="stack" id="st-llm-progress" hidden><progress max="1" value="0"></progress><span class="small muted"></span></div>
      <div class="tiny muted">Lần đầu tải từ Hugging Face rồi lưu trong trình duyệt; sau đó dịch offline, văn bản không rời khỏi máy.</div>
    </div>

    <div class="card" style="box-shadow:none">
      <div class="card-head"><h2>Whisper cho phụ đề trực tiếp</h2></div>
      <select id="st-cap-whisper">${WHISPER_MODELS.map((m) => `<option value="${m.id}" ${m.id === store.get('capWhisper', 'onnx-community/whisper-small') ? 'selected' : ''}>${m.name} · ${m.size}</option>`).join('')}</select>
      <label class="check"><input type="checkbox" id="st-cap-autosave" ${store.get('capAutoSave', true) ? 'checked' : ''}> Tự lưu phiên phụ đề khi dừng</label>
    </div>

    <div class="card" style="box-shadow:none" id="st-claude">
      <div class="card-head"><h2>Claude (tuỳ chọn, cần Internet)</h2></div>
      <label class="check"><input type="checkbox" id="st-cl-on" ${claude.enabled() ? 'checked' : ''}> Kết nối Claude</label>
      <div class="small">${claude.key() ? `Key đang lưu: <span class="mono">…${esc(claude.key().slice(-4))}</span>` : 'Chưa có API key.'}</div>
      <div class="row"><input type="password" id="st-cl-key" placeholder="sk-ant-…" autocomplete="off" style="flex:1;min-width:200px"><button class="btn" id="st-cl-save">Lưu key</button></div>
      <label class="check"><input type="checkbox" id="st-cl-remember" ${store.get('rememberKey', false) ? 'checked' : ''}> Nhớ key trên trình duyệt này (nếu tắt: xoá khi đóng tab)</label>
      <select id="st-cl-model">${CLAUDE_MODELS.map((m) => `<option value="${m.id}" ${m.id === claude.model() ? 'selected' : ''}>${m.name} — ${m.note}</option>`).join('')}</select>
      <div class="row"><button class="btn" id="st-cl-test" ${claude.key() ? '' : 'disabled'}>Kiểm tra key</button><button class="btn ghost" id="st-cl-del" ${claude.key() ? '' : 'disabled'}>Xoá key</button><span class="small" id="st-cl-result"></span></div>
      <div class="tiny muted">Key do bạn tự tạo tại console.anthropic.com và chỉ lưu trong trình duyệt này; trình duyệt gọi thẳng api.anthropic.com. Trước mỗi lần gửi, họ tên, PID, mã bệnh phẩm, ngày sinh, CCCD/hộ chiếu, SĐT, email, địa chỉ được che và bạn phải xác nhận.</div>
    </div>

    <div class="card" style="box-shadow:none">
      <div class="card-head"><h2>⚡ Dịch nhanh</h2></div>
      ${fast.supported ? `<label class="check"><input type="checkbox" id="st-fast" ${fast.enabled() ? 'checked' : ''}> Bật dịch nhanh (Translator tích hợp trong Chrome, chạy trên máy)</label>
        <div class="kv small"><span>Anh → Việt</span><span>${fastLabel(fastStates[0])} <button class="btn ghost tiny" data-fast-dl="enToVi">Tải gói</button></span>
        <span>Việt → Anh</span><span>${fastLabel(fastStates[1])} <button class="btn ghost tiny" data-fast-dl="viToEn">Tải gói</button></span></div>`
        : '<div class="small muted">Trình duyệt này chưa có Translator tích hợp (cần Chrome 138+ trên máy tính). Phụ đề vẫn dùng mô hình offline.</div>'}
    </div>

    <div class="card" style="box-shadow:none">
      <div class="card-head"><h2>Đọc tiếng Việt</h2></div>
      ${voices.length ? `<select id="st-voice">${voices.map((v) => `<option ${v.name === store.get('ttsVoice', '') ? 'selected' : ''}>${esc(v.name)}</option>`).join('')}</select>
        <button class="btn" id="st-voice-test">Nghe thử</button>` : '<div class="small muted">Chưa thấy giọng tiếng Việt trong hệ điều hành. macOS / iOS: Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt.</div>'}
    </div>
    <div class="foot"><button class="btn primary" data-close>Xong</button></div>`, { onClose: () => { settingsModal = null; updateChips(); renderClaudeRow(); updateCapHint(); } });
  const el = settingsModal.el;
  refreshSettingsProgress();
  $('#st-llm', el).addEventListener('change', (e) => { $('#st-local', el).hidden = e.target.value !== 'local'; });
  $('#st-local-list', el).addEventListener('click', async () => {
    const b = $('#st-local-list', el); b.textContent = 'Đang hỏi…';
    try {
      const ids = await localListModels($('#st-local-url', el).value);
      $('#st-local-models', el).innerHTML = ids.map((i) => `<option value="${esc(i)}">`).join('');
      toast(ids.length ? `Máy chủ có ${ids.length} mô hình: ${ids.slice(0, 6).join(', ')}${ids.length > 6 ? '…' : ''}` : 'Máy chủ chưa có mô hình nào');
    } catch (e) { toast(e.message || String(e)); }
    b.textContent = 'Liệt kê mô hình';
  });
  $('#st-llm-load', el).addEventListener('click', async () => {
    const v = $('#st-llm', el).value;
    try {
      if (v === 'local') await loadLocal($('#st-local-url', el).value, $('#st-local-model', el).value.trim());
      else await loadLLM(v);
      toast('Đã nạp mô hình'); T.liveCache.clear();
    } catch (e) { toast(e.message || String(e)); }
    refreshSettingsProgress();
  });
  $('#st-cap-whisper', el).addEventListener('change', (e) => store.set('capWhisper', e.target.value));
  $('#st-cap-autosave', el).addEventListener('change', (e) => store.set('capAutoSave', e.target.checked));
  $('#st-cl-on', el).addEventListener('change', (e) => store.set('claudeEnabled', e.target.checked));
  $('#st-cl-model', el).addEventListener('change', (e) => store.set('claudeModel', e.target.value));
  $('#st-cl-remember', el).addEventListener('change', (e) => { store.set('rememberKey', e.target.checked); if (claude.key()) claude.setKey(claude.key(), e.target.checked); });
  $('#st-cl-save', el).addEventListener('click', () => {
    const k = $('#st-cl-key', el).value.trim();
    if (k.length < 20) { toast('Key không hợp lệ'); return; }
    claude.setKey(k, $('#st-cl-remember', el).checked); store.set('claudeEnabled', true);
    settingsModal.close(); openSettings('claude'); toast('Đã lưu key');
  });
  $('#st-cl-del', el).addEventListener('click', () => { claude.clearKey(); store.set('claudeEnabled', false); settingsModal.close(); openSettings('claude'); });
  $('#st-cl-test', el).addEventListener('click', async () => {
    const r = $('#st-cl-result', el); r.textContent = 'Đang kiểm tra…';
    try { await claudeVerify(); r.innerHTML = '<span class="ok">Key hợp lệ</span>'; } catch (e) { r.innerHTML = `<span class="danger">${esc(e.message)}</span>`; }
  });
  $('#st-fast', el)?.addEventListener('change', (e) => store.set('fastEnabled', e.target.checked));
  $$('[data-fast-dl]', el).forEach((b) => b.addEventListener('click', async () => {
    const dir = DIR[b.dataset.fastDl];
    b.textContent = 'Đang tải…';
    try { await fastInstance(dir, true, (p) => { b.textContent = `${Math.round(p * 100)}%`; }); b.textContent = 'Sẵn sàng'; }
    catch (err) { b.textContent = 'Lỗi'; toast(err.message || String(err)); }
  }));
  $('#st-voice', el)?.addEventListener('change', (e) => store.set('ttsVoice', e.target.value));
  $('#st-voice-test', el)?.addEventListener('click', () => tts.speak('Hoá mô miễn dịch: CD20 dương tính, Ki-67 khoảng 80%. Đột biến IDH1 p.R132H.'));
  if (focus === 'claude') $('#st-claude', el).scrollIntoView({ block: 'start' });
}

// ============================================================================
// Khởi động
// ============================================================================
(async function boot() {
  userEntries = await idb.all('user');
  rebuildMatchers();
  await refreshBadge();
  await checkDevice();
  updateChips(); refreshInputMeta(); renderOutput(); renderCaps(); updateCapHint();
  if (fast.supported) Promise.all([fastAvailability(DIR.enToVi), fastAvailability(DIR.viToEn)]).then(updateCapHint);
  if ('speechSynthesis' in window) speechSynthesis.onvoiceschanged = () => {};
  showTab((location.hash || '#translate').slice(1));
})();
