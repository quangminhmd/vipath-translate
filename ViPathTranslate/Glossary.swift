import Foundation
import Observation

// MARK: - Dữ liệu (định dạng do Tools/build_glossary.py sinh ra)

struct GlossaryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var en: String
    var vi: String
    var note: String
    var terms: [String]
    var section: String
    var domain: String
    /// true = do người dùng thêm trong app (ưu tiên hơn glossary gốc).
    var isUser: Bool? = nil
}

struct GlossaryRule: Codable, Hashable {
    var section: String
    var text: String
}

struct GlossaryFile: Codable {
    var source: String
    var domains: [String]
    var profiles: [String: [String: String]]
    var rules: [GlossaryRule]
    var entries: [GlossaryEntry]
}

/// Chiều dịch.
enum TranslationDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case enToVi, viToEn
    var id: String { rawValue }
    var label: String { self == .enToVi ? "Anh → Việt" : "Việt → Anh" }
    var sourceName: String { self == .enToVi ? "Tiếng Anh" : "Tiếng Việt" }
    var targetName: String { self == .enToVi ? "Tiếng Việt" : "Tiếng Anh" }
    var sourceCode: String { self == .enToVi ? "en" : "vi" }
    var targetCode: String { self == .enToVi ? "vi" : "en" }
    var reversed: TranslationDirection { self == .enToVi ? .viToEn : .enToVi }
}

/// Một thuật ngữ tìm thấy trong văn bản nguồn.
struct GlossaryHit: Identifiable, Hashable, Sendable {
    var id: String { matched.lowercased() }
    let matched: String              // chuỗi đúng như trong văn bản
    let entries: [GlossaryEntry]     // ≥2 phần tử nếu glossary có nhiều nghĩa
    /// true = khớp từ phía tiếng Việt (dịch Việt → Anh): bản dịch là cột tiếng Anh.
    var reverse: Bool = false

    /// Các bản dịch khác nhau (loại trùng), bản do người dùng thêm đứng đầu.
    var translations: [String] {
        var seen = Set<String>(), out: [String] = []
        for e in entries.sorted(by: { ($0.isUser ?? false) && !($1.isUser ?? false) }) {
            let t = reverse ? e.en : e.vi
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
    var isAmbiguous: Bool { translations.count > 1 }
    var notes: [String] { entries.map(\.note).filter { !$0.isEmpty } }
}

// MARK: - Kho glossary

@MainActor
@Observable
final class GlossaryStore {
    private(set) var base: GlossaryFile?
    private(set) var userEntries: [GlossaryEntry] = []
    private(set) var matcher = GlossaryMatcher(entries: [])
    private(set) var reverseMatcher = VietnameseGlossaryMatcher(entries: [])
    var loadError: String?

    var allEntries: [GlossaryEntry] { (base?.entries ?? []) + userEntries }

    /// Quy tắc riêng của hồ sơ ngành (chèn vào prompt Anh → Việt).
    var styleGuide: String {
        guard let base else { return "" }
        var lines: [String] = []
        for d in base.domains {
            let p = base.profiles[d] ?? [:]
            // Chỉ lấy mục "Ghi chú" (quy tắc riêng của ngành); giọng văn & quy tắc giữ tiếng Anh
            // đã có sẵn trong prompt hệ thống — prompt ngắn hơn thì mỗi đoạn dịch bắt đầu nhanh hơn.
            if let v = p["Ghi chú"], !v.isEmpty { lines.append("- \(v)") }
        }
        return lines.joined(separator: "\n")
    }

    private var userFileURL: URL {
        URL.documentsDirectory.appending(path: "user_glossary.json")
    }

    func load() {
        do {
            guard let url = Bundle.main.url(forResource: "glossary", withExtension: "json") else {
                loadError = "Không tìm thấy glossary.json trong app bundle."
                return
            }
            base = try JSONDecoder().decode(GlossaryFile.self, from: Data(contentsOf: url))
            if let data = try? Data(contentsOf: userFileURL) {
                userEntries = (try? JSONDecoder().decode([GlossaryEntry].self, from: data)) ?? []
            }
            rebuild()
        } catch {
            loadError = "Lỗi đọc glossary: \(error.localizedDescription)"
        }
    }

    /// Thêm / sửa thuật ngữ riêng. `en` có thể chứa nhiều biến thể ngăn bởi " / ".
    func addUserEntry(en: String, vi: String, note: String) {
        let terms = en.components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        guard !terms.isEmpty, !vi.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        userEntries.removeAll { Set($0.terms.map { $0.lowercased() }) == Set(terms.map { $0.lowercased() }) }
        // id duy nhất kể cả sau khi xoá (không dùng count → tránh trùng id)
        let nextID = max(1_000_000, (userEntries.map(\.id).max() ?? 999_999) + 1)
        userEntries.append(GlossaryEntry(id: nextID, en: en, vi: vi, note: note, terms: terms,
                                         section: "Người dùng", domain: "user", isUser: true))
        persist()
    }

    func deleteUserEntry(_ entry: GlossaryEntry) {
        userEntries.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(userEntries) {
            try? data.write(to: userFileURL, options: .atomic)
        }
        rebuild()
    }

    private func rebuild() {
        matcher = GlossaryMatcher(entries: allEntries)
        reverseMatcher = VietnameseGlossaryMatcher(entries: allEntries)
    }

    /// Thuật ngữ trong văn bản nguồn theo chiều dịch.
    func hits(in text: String, direction: TranslationDirection) -> [GlossaryHit] {
        direction == .enToVi ? matcher.hits(in: text) : reverseMatcher.hits(in: text)
    }

    /// Nếu có mục người dùng (đã duyệt) thì chỉ giữ các mục đó.
    nonisolated static func preferUser(_ entries: [GlossaryEntry]) -> [GlossaryEntry] {
        let user = entries.filter { $0.isUser == true }
        return user.isEmpty ? entries : user
    }

    /// Mục glossary hiện có cho một thuật ngữ tiếng Anh (để biết đề xuất là "thêm mới" hay "sửa").
    func entry(forEnglish en: String) -> GlossaryEntry? {
        let e = en.lowercased().trimmingCharacters(in: .whitespaces)
        let found = allEntries.filter { $0.terms.contains { $0.lowercased() == e } || $0.en.lowercased() == e }
        return Self.preferUser(found).last
    }

    /// Đã có cặp (en, vi) này trong glossary chưa (dùng để lọc đề xuất của Claude).
    func contains(en: String, vi: String) -> Bool {
        let e = en.lowercased().trimmingCharacters(in: .whitespaces)
        let v = vi.lowercased().trimmingCharacters(in: .whitespaces)
        return allEntries.contains { entry in
            (entry.terms.contains { $0.lowercased() == e } || entry.en.lowercased() == e)
                && entry.vi.lowercased().contains(v)
        }
    }
}

// MARK: - Bộ khớp thuật ngữ (bản Swift của Tools/test_matcher.py)

/// Khớp dài nhất trước, phân biệt ranh giới từ, chấp nhận số nhiều (s/es/ies)
/// và coi dấu cách / gạch nối là tương đương ("whole slide" = "whole-slide").
/// Viết tắt (IHC, HPF, DLBCL…) khớp phân biệt hoa thường để tránh nhầm với từ thường.
struct GlossaryMatcher: @unchecked Sendable {   // NSRegularExpression bất biến, an toàn đa luồng
    private let index: [String: [GlossaryEntry]]
    private let caseInsensitive: NSRegularExpression?
    private let caseSensitive: NSRegularExpression?

    init(entries: [GlossaryEntry]) {
        var index: [String: [GlossaryEntry]] = [:]
        var ci = Set<String>(), cs = Set<String>()
        for e in entries {
            for t in e.terms {
                let abbr = Self.isAbbreviation(t)
                index[Self.key(t, abbr: abbr), default: []].append(e)
                if abbr { cs.insert(t) } else { ci.insert(t) }
            }
        }
        // Thuật ngữ bác sĩ đã duyệt (mục người dùng) thay thế mục gốc cùng khoá → không thành "nhiều nghĩa".
        self.index = index.mapValues(GlossaryStore.preferUser)
        caseInsensitive = Self.compile(ci, options: [.caseInsensitive])
        caseSensitive = Self.compile(cs, options: [])
    }

    func hits(in text: String) -> [GlossaryHit] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans: [NSRange] = []
        for rx in [caseSensitive, caseInsensitive].compactMap({ $0 }) {
            for m in rx.matches(in: text, range: full) {
                let r = m.range
                if spans.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                spans.append(r)
            }
        }
        spans.sort { $0.location < $1.location }

        var seen = Set<Int>(), out: [GlossaryHit] = []
        for r in spans {
            let s = ns.substring(with: r)
            let entries = lookup(s).filter { seen.insert($0.id).inserted }
            if !entries.isEmpty { out.append(GlossaryHit(matched: s, entries: entries)) }
        }
        return out
    }

    // MARK: Nội bộ

    private func lookup(_ matched: String) -> [GlossaryEntry] {
        let norm = matched.replacing(#/[\s\-]+/#, with: " ")
        let low = norm.lowercased()
        var candidates = [norm, low]
        if low.hasSuffix("ies") { candidates.append(String(low.dropLast(3)) + "y") }
        if low.hasSuffix("es") { candidates.append(String(low.dropLast(2))) }
        if low.hasSuffix("s") { candidates.append(String(low.dropLast())) }
        for c in candidates {
            if let e = index[c] { return e }
            if let e = index[c.replacingOccurrences(of: " ", with: "-")] { return e }
        }
        // khớp mềm khi glossary viết "whole-slide" còn văn bản viết "whole slide"
        let flat = low.replacing(#/[\s\-]/#, with: "")
        for (k, v) in index where k.replacing(#/[\s\-]/#, with: "").lowercased() == flat
            || k.replacing(#/[\s\-]/#, with: "").lowercased() + "s" == flat {
            return v
        }
        return []
    }

    private static func key(_ t: String, abbr: Bool) -> String {
        let n = t.replacing(#/[\s\-]+/#, with: " ")
        return abbr ? n : n.lowercased()
    }

    static func isAbbreviation(_ t: String) -> Bool {
        guard !t.contains(" ") else { return false }
        let letters = t.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let upper = letters.filter(\.isUppercase).count
        return Double(upper) >= max(2, Double(letters.count) * 0.6)
    }

    private static func pattern(_ t: String) -> String {
        let words = t.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        var body = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "[\\s\\-]+")
        if !isAbbreviation(t), t.count >= 4 {
            let tail = body.suffix(2)
            if body.hasSuffix("y"), !["ay", "ey", "oy", "uy"].contains(String(tail)) {
                body = String(body.dropLast()) + "(?:y|ies)"
            } else if !body.hasSuffix("s") {
                body += "(?:s|es)?"
            }
        }
        return body
    }

    private static func compile(_ terms: Set<String>, options: NSRegularExpression.Options) -> NSRegularExpression? {
        guard !terms.isEmpty else { return nil }
        // Dài trước → NSRegularExpression chọn phương án dài nhất tại mỗi vị trí.
        let alts = terms.sorted { $0.count > $1.count }.map(pattern).joined(separator: "|")
        let p = "(?<![A-Za-z0-9])(?:\(alts))(?![A-Za-z0-9])"
        return try? NSRegularExpression(pattern: p, options: options)
    }
}

// MARK: - Kiểm tra sau dịch (tương tự debug_check.py của Vitranslate)

enum GlossaryQA {
    /// Trả về các thuật ngữ mà bản dịch KHÔNG dùng đúng bản dịch trong glossary.
    static func missing(hits: [GlossaryHit], source: String, output: String) -> [GlossaryHit] {
        let out = output.lowercased()
        return hits.filter { hit in
            if hit.reverse {
                // Việt → Anh: bản dịch phải chứa một trong các dạng tiếng Anh của thuật ngữ
                let options = hit.entries.flatMap { $0.terms + [$0.en] }.map { $0.lowercased() }
                return !options.contains { out.contains($0) }
            }
            let options = hit.translations.flatMap { variants($0, source: hit.matched) }
            if options.isEmpty { return false }
            return !options.contains { out.contains($0.lowercased()) }
        }
    }

    /// "sarcôm / ung thư mô liên kết" → ["sarcôm", "ung thư mô liên kết"];
    /// "vi trường (HPF)" → ["vi trường (HPF)", "vi trường"];
    /// "giữ nguyên ..." → chấp nhận nếu thuật ngữ gốc tiếng Anh còn nguyên trong bản dịch.
    private static func variants(_ vi: String, source: String) -> [String] {
        var out: [String] = []
        for part in vi.components(separatedBy: " / ") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.lowercased().hasPrefix("giữ nguyên") {
                let rest = p.dropFirst("giữ nguyên".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'"))
                out.append(rest.isEmpty ? source : rest)
                continue
            }
            out.append(p)
            let noParen = p.replacing(#/\s*\([^)]*\)/#, with: "").trimmingCharacters(in: .whitespaces)
            if noParen != p, !noParen.isEmpty { out.append(noParen) }
        }
        return out.filter { !$0.isEmpty }
    }
}


// MARK: - Bộ khớp thuật ngữ tiếng Việt (dịch Việt → Anh)

/// Khớp cột tiếng Việt của glossary trong văn bản tiếng Việt.
/// • Không phân biệt hoa thường, ranh giới theo chữ cái Unicode.
/// • Chuẩn hoá vị trí dấu thanh kiểu cũ/mới ("hoá" = "hóa", "thuỷ" = "thủy") — giữ nguyên độ dài
///   chuỗi nên vị trí khớp trỏ đúng vào văn bản gốc.
/// • Bỏ thuật ngữ quá chung (một âm tiết ngắn như "u", "ổ", "đám") để tránh khớp nhầm.
struct VietnameseGlossaryMatcher: @unchecked Sendable {
    private let index: [String: [GlossaryEntry]]
    private let regex: NSRegularExpression?

    init(entries: [GlossaryEntry]) {
        var index: [String: [GlossaryEntry]] = [:]
        for e in entries {
            for term in Self.vietnameseTerms(of: e) {
                index[Self.canonical(term), default: []].append(e)
            }
        }
        self.index = index.mapValues(GlossaryStore.preferUser)
        let alts = index.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        regex = alts.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])(?:\(alts))(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    func hits(in text: String) -> [GlossaryHit] {
        guard let regex else { return [] }
        let canon = Self.canonical(text)
        let ns = canon as NSString
        var seen = Set<Int>(), out: [GlossaryHit] = []
        for m in regex.matches(in: canon, range: NSRange(location: 0, length: ns.length)) {
            let key = Self.canonical(ns.substring(with: m.range)).replacing(#/\s+/#, with: " ")
            let entries = (index[key] ?? []).filter { seen.insert($0.id).inserted }
            guard !entries.isEmpty else { continue }
            let original = (text as NSString).length == ns.length
                ? (text as NSString).substring(with: m.range) : ns.substring(with: m.range)
            out.append(GlossaryHit(matched: original, entries: entries, reverse: true))
        }
        return out
    }

    /// Các dạng tiếng Việt của một mục: tách " / ", bỏ ngoặc chú thích, bỏ "giữ nguyên…".
    static func vietnameseTerms(of e: GlossaryEntry) -> [String] {
        e.vi.components(separatedBy: " / ").compactMap { part in
            let p = part.replacing(#/\s*\([^)]*\)/#, with: "").trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, !p.lowercased().hasPrefix("giữ nguyên") else { return nil }
            let words = p.split(separator: " ")
            // một âm tiết: chỉ giữ từ dài (sarcôm, lymphôm, amyloid…), bỏ "u", "ổ", "đám", "nhân"…
            if words.count == 1 && p.count < 6 { return nil }
            return p
        }
    }

    /// Chữ thường, NFC, dấu thanh đặt theo kiểu cũ (óa, óe, úy) — cùng độ dài UTF-16.
    static func canonical(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping.lowercased()
        for (from, to) in toneMoves { t = t.replacingOccurrences(of: from, with: to) }
        return t
    }

    private static let toneMoves: [(String, String)] = {
        let pairs: [(Character, [Character])] = [
            ("a", ["á", "à", "ả", "ã", "ạ"]),
            ("e", ["é", "è", "ẻ", "ẽ", "ẹ"]),
            ("y", ["ý", "ỳ", "ỷ", "ỹ", "ỵ"]),
        ]
        let leads: [Character: [Character]] = [
            "a": ["ó", "ò", "ỏ", "õ", "ọ"], "e": ["ó", "ò", "ỏ", "õ", "ọ"], "y": ["ú", "ù", "ủ", "ũ", "ụ"],
        ]
        let firsts: [Character: Character] = ["a": "o", "e": "o", "y": "u"]
        var out: [(String, String)] = []
        for (base, toned) in pairs {
            guard let first = firsts[base], let lead = leads[base] else { continue }
            for i in 0..<5 {
                // "oá" → "óa", "uý" → "úy"
                out.append(("\(first)\(toned[i])", "\(lead[i])\(base)"))
            }
        }
        return out
    }()
}
