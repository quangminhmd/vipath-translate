import Foundation

// Đọc mô tả đại thể (phẫu tích – cắt lọc bệnh phẩm) bằng giọng nói: lệnh rảnh tay, chuẩn hoá số đo,
// danh sách cát xét. Logic thuần, không phụ thuộc giao diện.
// Bản JavaScript tương ứng: Web/src/logic.js (mục "Đọc mô tả đại thể") — giữ hai bản giống nhau;
// bộ ca kiểm thử chung nằm trong Web/test/test_logic.mjs.

// MARK: - Kiểu dữ liệu

nonisolated enum GrossOp: Equatable, Sendable {
    case text(String)
    case punct(String)
    case newline, para, bullet, undo
    case cassette(String)
    case nextCassette, body
    case pause, resume, stop
}

nonisolated enum GrossSignal: Equatable, Sendable { case pause, resume, stop }

nonisolated struct GrossCassette: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var code: String
    var text: String
}

nonisolated struct GrossCorrection: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var from: String
    var to: String
}

/// Văn bản đại thể đang đọc: phần mô tả + các cát xét. `target` = -1 → đang ghi vào phần mô tả.
nonisolated struct GrossDoc: Sendable {
    struct Snapshot: Sendable {
        var body: String
        var cassettes: [GrossCassette]
        var target: Int
    }

    var body = ""
    var cassettes: [GrossCassette] = []
    var target = -1
    var history: [Snapshot] = []

    var snapshot: Snapshot { Snapshot(body: body, cassettes: cassettes, target: target) }
    mutating func restore(_ s: Snapshot) { body = s.body; cassettes = s.cassettes; target = s.target }

    var current: String {
        get { target < 0 || target >= cassettes.count ? body : cassettes[target].text }
        set { if target < 0 || target >= cassettes.count { body = newValue } else { cassettes[target].text = newValue } }
    }

    var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cassettes.isEmpty }
}

// MARK: - Bộ phân tích

nonisolated enum GrossParser {

    // Ranh giới từ hỗ trợ chữ có dấu tiếng Việt.
    static let L = "(?<![\\p{L}\\p{N}])", R = "(?![\\p{L}\\p{N}])"

    static func rx(_ p: String, _ opts: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        // Mẫu là hằng số trong mã nguồn → lỗi biên dịch mẫu là lỗi lập trình.
        try! NSRegularExpression(pattern: p, options: opts)
    }

    static func replace(_ s: String, _ r: NSRegularExpression, _ template: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    // MARK: Số đếm tiếng Việt

    static let digit: [String: Int] = [
        "không": 0, "một": 1, "mốt": 1, "hai": 2, "ba": 3, "bốn": 4, "tư": 4, "năm": 5, "lăm": 5,
        "sáu": 6, "bảy": 7, "bẩy": 7, "tám": 8, "chín": 9,
    ]
    static let numWords: Set<String> = Set(digit.keys).union(["mười", "mươi", "linh", "lẻ", "trăm", "rưỡi"])
    static let notFirst: Set<String> = ["mốt", "lăm", "tư", "linh", "lẻ", "mươi", "trăm", "rưỡi"]

    /// "hai mươi lăm" → 25, "một trăm linh năm" → 105, "ba tư" → 34 (cách nói tắt).
    static func viNumber(_ words: [String]) -> Int {
        var group = 0
        var pending: Int?
        for w in words {
            if let d = digit[w] {
                if let p = pending { group += p * 10 + d; pending = nil } else { pending = d }
            } else if w == "mười" { group += 10; pending = nil }
            else if w == "mươi" { group += (pending ?? 1) * 10; pending = nil }
            else if w == "trăm" { group += (pending ?? 1) * 100; pending = nil }
        }
        return group + (pending ?? 0)
    }

    // MARK: Số đo

    static let units: [([String], String)] = [
        (["xăng", "ti", "mét"], "cm"), (["xen", "ti", "mét"], "cm"), (["xăng", "ti"], "cm"), (["xen", "ti"], "cm"),
        (["centimet"], "cm"), (["centimét"], "cm"), (["cm"], "cm"), (["phân"], "cm"),
        (["centimeters"], "cm"), (["centimeter"], "cm"), (["millimeters"], "mm"), (["millimeter"], "mm"),
        (["mi", "li", "mét"], "mm"), (["mi", "li", "lít"], "ml"), (["ki", "lô", "gam"], "kg"),
        (["milimet"], "mm"), (["milimét"], "mm"), (["mm"], "mm"), (["mi", "li"], "mm"), (["li"], "mm"), (["ly"], "mm"),
        (["kilôgam"], "kg"), (["kg"], "kg"), (["ký"], "kg"), (["ki", "lô"], "kg"),
        (["gờ", "ram"], "g"), (["gam"], "g"), (["gram"], "g"), (["grams"], "g"), (["g"], "g"),
        (["ml"], "ml"), (["phần", "trăm"], "%"), (["%"], "%"), (["percent"], "%"),
    ]
    static let countNouns: Set<String> = ["mảnh", "hạch", "lát", "nốt", "khối", "polyp", "sỏi", "viên", "pieces", "fragments", "nodes"]
    static let timesWords: Set<String> = ["nhân", "x", "×", "by"]
    static let rangeWords: Set<String> = ["đến", "tới", "-", "–", "to"]

    private static let tokenRx = rx("[\\p{L}\\p{M}]+|[0-9]+(?:[.,][0-9]+)?|%|[^\\s\\p{L}\\p{M}0-9]", [])
    private static let digitTokRx = rx("^[0-9]+(?:[.,][0-9]+)?$", [])
    private static let hyphenUnitRx = rx("(xăng|xen|mi)-(ti|li)-(mét|lít)")
    private static let hyphenKgRx = rx("ki-lô-gam")
    private static let digitUnitRx = rx("([0-9])(?=(?:cm|mm|kg|ml|g)(?![\\p{L}\\p{N}]))", [])
    private static let digitXRx = rx("([0-9])\\s*[xX](?=\\s*[0-9])", [])

    static func isDigitTok(_ t: String) -> Bool {
        digitTokRx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    static func tokens(_ s: String) -> [String] {
        tokenRx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }

    static func joinTokens(_ toks: [String]) -> String {
        var out = ""
        for t in toks {
            if out.isEmpty { out = t }
            else if let f = t.first, ".,;:!?)%".contains(f) { out += t }
            else if out.hasSuffix("(") { out += t }
            else { out += " " + t }
        }
        return out
    }

    private struct Span {
        var start: Int, end: Int, comma: Int
        var conv = false
        var unit: (len: Int, sym: String)?
        var times = false
    }

    private static func unit(at i: Int, _ lw: [String]) -> (len: Int, sym: String)? {
        for (seq, sym) in units {
            guard i + seq.count <= lw.count else { continue }
            if seq.indices.allSatisfy({ lw[i + $0] == seq[$0] }) { return (seq.count, sym) }
        }
        return nil
    }

    /// "bốn nhân ba nhân hai xăng ti mét" → "4 x 3 x 2 cm", "hai phẩy năm phân" → "2,5 cm", "ba mảnh" → "3 mảnh".
    /// Chỉ đổi chữ số khi đứng cạnh đơn vị / "nhân" / danh từ đếm → "một đoạn đại tràng" vẫn giữ nguyên.
    static func normalizeMeasurements(_ input: String) -> String {
        var s = input.precomposedStringWithCanonicalMapping
        s = replace(s, hyphenUnitRx, "$1 $2 $3")
        s = replace(s, hyphenKgRx, "ki lô gam")
        s = s.replacingOccurrences(of: "×", with: " x ")
        s = replace(s, digitUnitRx, "$1 ")
        s = replace(s, digitXRx, "$1 x ")
        let toks = tokens(s)
        let lw = toks.map { $0.lowercased() }
        func isNum(_ i: Int) -> Bool { i < lw.count && (isDigitTok(lw[i]) || numWords.contains(lw[i])) }

        // 1) Cụm số
        var spans: [Span] = []
        var i = 0
        while i < toks.count {
            if !isNum(i) || notFirst.contains(lw[i]) { i += 1; continue }
            var j = i, comma = -1
            while j < toks.count {
                if isNum(j) { j += 1; continue }
                if lw[j] == "phẩy", comma < 0, isNum(j + 1), !notFirst.contains(lw[j + 1]) { comma = j; j += 1; continue }
                break
            }
            if !(j - i == 1 && lw[i] == "không") { spans.append(Span(start: i, end: j, comma: comma)) }
            i = j
        }
        // 2) Cụm cần đổi
        for k in spans.indices {
            if let u = unit(at: spans[k].end, lw) { spans[k].unit = u; spans[k].conv = true }
            else if spans[k].end < lw.count, countNouns.contains(lw[spans[k].end]) { spans[k].conv = true }
        }
        var changed = true
        while changed {
            changed = false
            for k in 0 ..< max(0, spans.count - 1) {
                let a = spans[k], b = spans[k + 1]
                guard b.start == a.end + 1 else { continue }
                let link = lw[a.end]
                let times = timesWords.contains(link), range = rangeWords.contains(link)
                guard times || range else { continue }
                // "nhân" giữa hai số luôn là kích thước; "đến" chỉ khi một bên đã là số đo
                let want = times ? true : (a.conv || b.conv)
                if want, !a.conv || !b.conv { spans[k].conv = true; spans[k + 1].conv = true; changed = true }
                if times { spans[k].times = true }
            }
        }
        // 3) Dựng lại
        func value(_ words: [String]) -> (str: String, half: Bool) {
            var w = words
            let half = w.last == "rưỡi"
            if half { w.removeLast() }
            if w.count == 1, isDigitTok(w[0]) { return (w[0].replacingOccurrences(of: ".", with: ","), half) }
            return (String(viNumber(w)), half)
        }
        var out: [String] = []
        i = 0
        for sp in spans {
            while i < sp.start { out.append(toks[i]); i += 1 }
            guard sp.conv else {
                while i < sp.end { out.append(toks[i]); i += 1 }
                continue
            }
            let intW = Array(lw[sp.start ..< (sp.comma >= 0 ? sp.comma : sp.end)])
            let iv = value(intW)
            var num = iv.str
            if sp.comma >= 0 { num += "," + value(Array(lw[(sp.comma + 1) ..< sp.end])).str }
            i = sp.end
            var unitSym: String?
            if let u = sp.unit { unitSym = u.sym; i += u.len }
            let halfAfter = unitSym != nil && i < lw.count && lw[i] == "rưỡi"
            if (iv.half || halfAfter), !num.contains(",") {
                num += ",5"
                if halfAfter { i += 1 }
            }
            out.append(num)
            if let unitSym { out.append(unitSym) }
            if sp.times { out.append("x"); i += 1 }
        }
        while i < toks.count { out.append(toks[i]); i += 1 }
        return joinTokens(out)
    }

    // MARK: Sửa lỗi nhận dạng

    static func applyCorrections(_ text: String, _ list: [GrossCorrection]) -> String {
        var s = text.precomposedStringWithCanonicalMapping
        for c in list {
            let f = c.from.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
            guard !f.isEmpty else { continue }
            let body = f.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
            let r = rx(L + body + R)
            s = replace(s, r, NSRegularExpression.escapedTemplate(for: c.to))
        }
        return s
    }

    static let defaultCorrections: [GrossCorrection] = [
        GrossCorrection(from: "các xi nôm", to: "carcinôm"), GrossCorrection(from: "cát xi nôm", to: "carcinôm"),
        GrossCorrection(from: "xa côm", to: "sarcôm"), GrossCorrection(from: "lim phôm", to: "lymphôm"),
        GrossCorrection(from: "pô líp", to: "polyp"), GrossCorrection(from: "pô lyp", to: "polyp"),
    ]

    /// Từ vựng đại thể gợi ý cho bộ nhận dạng của iOS (contextual strings).
    static let vocabulary: [String] = [
        "đại thể", "cắt lọc", "cát xét", "bệnh phẩm", "mảnh mô", "mô mềm", "mô mỡ", "nhu mô", "vỏ bao", "thanh mạc", "niêm mạc",
        "dưới niêm mạc", "lớp cơ", "mạc treo", "mạc nối", "diện cắt", "bờ phẫu thuật", "diện cắt gần", "diện cắt xa", "diện cắt quanh",
        "chấm mực", "mực tàu", "mực xanh", "mực đen", "mực đỏ", "mặt cắt", "mật độ", "chắc", "mềm", "bở", "dai", "xơ", "nhầy", "dạng keo",
        "dạng nang", "dạng nhú", "dạng sùi", "loét", "thâm nhiễm", "xâm nhập", "hoại tử", "xuất huyết", "vôi hoá", "sỏi", "giả mạc",
        "hạch", "hạch bạch huyết", "polyp", "cuống", "không cuống", "u", "khối u", "nốt", "giới hạn rõ", "giới hạn không rõ",
        "màu trắng xám", "màu vàng", "màu nâu", "màu đỏ sẫm", "carcinôm", "sarcôm", "lymphôm", "tuyến giáp", "túi mật", "ruột thừa",
        "đại tràng", "trực tràng", "dạ dày", "tử cung", "cổ tử cung", "nội mạc", "buồng trứng", "vòi trứng", "tuyến vú", "núm vú",
        "hố nách", "thận", "tuyến tiền liệt", "cố định formol", "cắt lọc toàn bộ", "đại diện", "xăng ti mét", "mi li mét", "gam",
    ]

    // MARK: Lệnh giọng nói

    static let letters: [String: String] = [
        "ép phờ": "F", "bê": "B", "bờ": "B", "xê": "C", "cê": "C", "cờ": "C", "đê": "D", "dê": "D", "đờ": "D",
        "giê": "G", "gờ": "G", "hát": "H", "ép": "F", "ca": "K", "a": "A", "b": "B", "c": "C", "d": "D", "e": "E", "ê": "E",
        "f": "F", "g": "G", "h": "H", "i": "I", "k": "K",
    ]
    private static let letRx = letters.keys.sorted { $0.count > $1.count }
        .map { $0.replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")
    private static let numWRx = "(?:một|mốt|hai|ba|bốn|tư|năm|lăm|sáu|bảy|bẩy|tám|chín|mười|mươi|linh|lẻ|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
    private static let numRx = "([0-9]{1,2}|\(numWRx)(?:\\s+\(numWRx))*)"
    private static let enNum: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                               "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]

    static func cassetteNumber(_ s: String) -> Int {
        let w = s.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = w.first else { return 0 }
        if let n = Int(first) { return n }
        if w.count == 1, let n = enNum[first] { return n }
        return viNumber(w)
    }

    private static func letter(_ s: String) -> String {
        let k = s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return letters[k] ?? ""
    }

    private typealias Maker = (_ groups: [String?]) -> GrossOp
    private static func cmd(_ p: String) -> NSRegularExpression { rx(L + p + R) }

    /// Thứ tự quan trọng: cụm dài trước ("dấu hai chấm" trước "dấu chấm").
    /// Chỉ đọc sau khi khởi tạo; NSRegularExpression không đổi trạng thái → dùng chung an toàn.
    nonisolated(unsafe) private static let commands: [(NSRegularExpression, Maker)] = [
        (cmd("(?:cát\\s*-?\\s*xét|cassette|khối\\s+nến|khuôn\\s+nến|block)\\s+(?:số\\s+|number\\s+)?(?:(\(letRx))\\s*)?\(numRx)"),
         { g in .cassette((g[1].map(letter) ?? "") + String(cassetteNumber(g[2] ?? ""))) }),
        (cmd("mẫu\\s+(\(letRx))\\s*\(numRx)"),
         { g in .cassette(letter(g[1] ?? "") + String(cassetteNumber(g[2] ?? ""))) }),
        (cmd("(?:cát\\s*-?\\s*xét|cassette|khối|mẫu|block)\\s+(?:tiếp(?:\\s+theo)?|kế\\s+tiếp|next)|next\\s+(?:cassette|block)"),
         { _ in .nextCassette }),
        (cmd("(?:quay\\s+(?:lại|về)|về|trở\\s+lại)\\s+(?:phần\\s+)?mô\\s+tả|phần\\s+mô\\s+tả|back\\s+to\\s+description"), { _ in .body }),
        (cmd("dấu\\s+chấm\\s+phẩy|semicolon"), { _ in .punct(";") }),
        (cmd("dấu\\s+hai\\s+chấm|colon"), { _ in .punct(":") }),
        (cmd("dấu\\s+chấm\\s+hỏi|question\\s+mark"), { _ in .punct("?") }),
        (cmd("dấu\\s+chấm|chấm\\s+câu|full\\s+stop|period"), { _ in .punct(".") }),
        (cmd("dấu\\s+phẩy|comma"), { _ in .punct(",") }),
        (cmd("mở\\s+ngoặc|open\\s+(?:paren|parenthesis|bracket)"), { _ in .punct("(") }),
        (cmd("đóng\\s+ngoặc|close\\s+(?:paren|parenthesis|bracket)"), { _ in .punct(")") }),
        (cmd("gạch\\s+đầu\\s+dòng|bullet"), { _ in .bullet }),
        (cmd("xuống\\s+dòng|new\\s+line"), { _ in .newline }),
        (cmd("đoạn\\s+mới|sang\\s+đoạn(?:\\s+mới)?|new\\s+paragraph"), { _ in .para }),
        (cmd("(?:xoá|xóa)\\s+câu(?:\\s+(?:cuối|vừa\\s+rồi|trước))?|hoàn\\s+tác|scratch\\s+that|undo\\s+that"), { _ in .undo }),
        (cmd("tạm\\s+dừng(?:\\s+ghi)?|pause\\s+dictation"), { _ in .pause }),
        (cmd("tiếp\\s+tục\\s+ghi|ghi\\s+tiếp|resume\\s+dictation"), { _ in .resume }),
        (cmd("(?:dừng|kết\\s+thúc)\\s+ghi(?:\\s+âm)?|stop\\s+dictation"), { _ in .stop }),
    ]

    private static let trailingPunctRx = rx("[\\s.,;:!?]+$", [])
    private static let leadingPunctRx = rx("^[\\s.,;:!?]+", [])

    /// Tách một câu đọc thành văn bản và lệnh.
    static func parse(_ input: String) -> [GrossOp] {
        var ops: [GrossOp] = []
        var rest = input.precomposedStringWithCanonicalMapping
        while true {
            let ns = rest as NSString
            var best: (m: NSTextCheckingResult, make: Maker)?
            for (r, make) in commands {
                guard let m = r.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) else { continue }
                if let b = best {
                    if m.range.location < b.m.range.location
                        || (m.range.location == b.m.range.location && m.range.length > b.m.range.length) { best = (m, make) }
                } else { best = (m, make) }
            }
            guard let found = best else { break }
            let m = found.m, make = found.make
            let groups: [String?] = (0 ..< m.numberOfRanges).map { k in
                let r = m.range(at: k)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let op = make(groups)
            var before = ns.substring(to: m.range.location)
            // dấu câu tự thêm của bộ nhận dạng ngay trước lệnh dấu câu → bỏ (lệnh thay thế nó)
            if case .punct = op { before = replace(before, trailingPunctRx, "") }
            let b = before.trimmingCharacters(in: .whitespacesAndNewlines)
            if !b.isEmpty { ops.append(.text(b)) }
            ops.append(op)
            // dấu câu tự thêm ngay sau lệnh → bỏ
            rest = replace(ns.substring(from: m.range.location + m.range.length), leadingPunctRx, "")
        }
        let r = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty { ops.append(.text(r)) }
        return ops
    }

    // MARK: Ghép văn bản

    private static func isSentenceEnd(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        guard let last = t.last else { return true }
        return ".!?:\n".contains(last)
    }

    static func appendText(_ prev: String, _ piece: String) -> String {
        guard !piece.isEmpty else { return prev }
        var p = piece
        let chars = Array(p)
        if prev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSentenceEnd(prev) {
            p = chars[0].uppercased() + String(chars.dropFirst())
        } else if chars.count >= 2, chars[0].isUppercase, chars[1].isLowercase {
            // bộ nhận dạng viết hoa đầu mỗi lượt đọc → hạ chữ thường khi đang giữa câu
            p = chars[0].lowercased() + String(chars.dropFirst())
        }
        if prev.isEmpty { return p }
        if let l = prev.last, l.isWhitespace || l == "(" { return prev + p }
        if let f = p.first, ".,;:!?)%".contains(f) { return prev + p }
        return prev + " " + p
    }

    static func appendPunct(_ prev: String, _ mark: String) -> String {
        var t = prev
        while let l = t.last, l.isWhitespace { t.removeLast() }
        if mark == "(" { return t.isEmpty ? "(" : t + " (" }
        if let l = t.last, ".,;:".contains(l), mark != ")" { t.removeLast() }
        return t + mark
    }

    static func nextCode(_ doc: GrossDoc) -> String {
        guard let last = doc.cassettes.last?.code else { return "A1" }
        let letters = last.prefix { $0.isLetter }
        let digits = last.dropFirst(letters.count)
        if let n = Int(digits) { return String(letters) + String(n + 1) }
        return last + "1"
    }

    /// Áp các lệnh của MỘT câu đọc. `paused` = đang tạm dừng → chỉ nhận lệnh "tiếp tục ghi".
    @discardableResult
    static func apply(_ ops: [GrossOp], to doc: inout GrossDoc, paused: Bool = false,
                      corrections: [GrossCorrection] = []) -> [GrossSignal] {
        var signals: [GrossSignal] = []
        var paused = paused
        var snap = doc.snapshot
        var pushed = false
        var textSnap: GrossDoc.Snapshot?
        func remember() {
            guard !pushed else { return }
            doc.history.append(snap)
            if doc.history.count > 50 { doc.history.removeFirst() }
            pushed = true
        }
        for op in ops {
            if paused {
                if op == .resume { paused = false; signals.append(.resume) }
                continue
            }
            switch op {
            case .text(let t):
                remember()
                textSnap = doc.snapshot
                doc.current = appendText(doc.current, normalizeMeasurements(applyCorrections(t, corrections)))
            case .punct(let m):
                remember(); doc.current = appendPunct(doc.current, m)
            case .newline:
                remember()
                var t = doc.current
                while let l = t.last, l == " " || l == "\t" { t.removeLast() }
                doc.current = t + "\n"
            case .para:
                remember()
                var t = doc.current
                while let l = t.last, l.isWhitespace { t.removeLast() }
                doc.current = t + "\n\n"
            case .bullet:
                remember()
                var t = doc.current
                while let l = t.last, l == " " || l == "\t" { t.removeLast() }
                if let l = t.last, l != "\n" { t += "\n" }
                doc.current = t + "- "
            case .cassette(let code):
                remember()
                if let k = doc.cassettes.firstIndex(where: { $0.code == code }) { doc.target = k }
                else { doc.cassettes.append(GrossCassette(code: code, text: "")); doc.target = doc.cassettes.count - 1 }
            case .nextCassette:
                remember()
                doc.cassettes.append(GrossCassette(code: nextCode(doc), text: ""))
                doc.target = doc.cassettes.count - 1
            case .body:
                remember(); doc.target = -1
            case .undo:
                // có chữ đọc trước lệnh trong cùng câu → chỉ xoá đoạn chữ đó; lệnh đứng riêng → xoá câu đọc trước
                if let ts = textSnap { doc.restore(ts); textSnap = nil }
                else if let prev = doc.history.popLast() { doc.restore(prev); snap = doc.snapshot; pushed = false }
            case .pause: paused = true; signals.append(.pause)
            case .resume: signals.append(.resume)
            case .stop: signals.append(.stop)
            }
        }
        return signals
    }

    static func reportText(_ doc: GrossDoc, english: Bool = false) -> String {
        let body = doc.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !doc.cassettes.isEmpty else { return body }
        let head = english ? "SECTIONS / CASSETTES:" : "CẮT LỌC – CÁT XÉT:"
        let list = doc.cassettes.map { "\($0.code): \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
        return (body.isEmpty ? "" : body + "\n\n") + head + "\n" + list
    }
}

// MARK: - Gợi ý cấu trúc mô tả

nonisolated struct GrossTemplate: Identifiable, Sendable {
    let id: String
    let name: String
    let items: [String]

    static let all: [GrossTemplate] = [
        GrossTemplate(id: "biopsy", name: "Sinh thiết nhỏ",
                      items: ["Số mảnh", "Kích thước (mảnh lớn nhất / gộp)", "Màu sắc, mật độ", "Cắt lọc toàn bộ / số cát xét"]),
        GrossTemplate(id: "gallbladder", name: "Túi mật",
                      items: ["Kích thước", "Thanh mạc", "Độ dày thành", "Niêm mạc", "Sỏi: số lượng, kích thước, màu",
                              "Ống túi mật, hạch cổ túi mật", "Cát xét"]),
        GrossTemplate(id: "appendix", name: "Ruột thừa",
                      items: ["Chiều dài × đường kính", "Thanh mạc (giả mạc, thủng)", "Lòng (sỏi phân, mủ)", "Đầu tận",
                              "Diện cắt", "Cát xét"]),
        GrossTemplate(id: "thyroid", name: "Tuyến giáp",
                      items: ["Thuỳ / eo, trọng lượng", "Kích thước", "Vỏ bao",
                              "Nốt: số lượng, vị trí, kích thước, vỏ bao, mặt cắt", "Khoảng cách tới bờ (chấm mực)",
                              "Tuyến cận giáp, hạch", "Cát xét"]),
        GrossTemplate(id: "breast", name: "Vú",
                      items: ["Định hướng (chỉ khâu)", "Kích thước, da, núm vú", "U: vị trí, 3 chiều, bờ, mặt cắt",
                              "Khoảng cách tới từng diện cắt (màu mực)", "Clip / dấu định vị", "Hạch nách: số lượng", "Cát xét"]),
        GrossTemplate(id: "colon", name: "Đại – trực tràng",
                      items: ["Đoạn ruột, chiều dài", "U: kích thước, dạng, % chu vi, mức xâm nhập",
                              "Khoảng cách tới diện cắt gần / xa / quanh (CRM)", "Mạc treo, hạch (số lượng)",
                              "Polyp / tổn thương khác", "Cát xét"]),
        GrossTemplate(id: "uterus", name: "Tử cung",
                      items: ["Trọng lượng", "Kích thước thân / cổ", "Nội mạc: độ dày, tổn thương",
                              "Cơ tử cung: u xơ (số lượng, kích thước)", "Cổ tử cung", "Phần phụ", "Cát xét"]),
    ]
}
