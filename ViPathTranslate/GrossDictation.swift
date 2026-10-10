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
    case pathcode(String)
    /// Lưu ca đang đọc và mở ca mới (kèm pathcode nếu có đọc)
    case newCase(String)
    case pause, resume, stop
}

nonisolated enum GrossSignal: Equatable, Sendable {
    case pause, resume, stop
    /// Ca vừa kết thúc bằng lệnh "ca mới" — bộ điều khiển lưu ca này.
    case newCase(GrossDoc.Snapshot)
}

nonisolated struct GrossCassette: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var code: String
    var text: String
    /// Pathcode của ca chứa cát xét này
    var pathcode: String = ""

    /// "GPB-24-012345-A1" (có pathcode) hoặc "A1"
    var label: String { pathcode.isEmpty ? code : "\(pathcode)-\(code)" }
}

nonisolated struct GrossCorrection: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var from: String
    var to: String
}

/// Văn bản đại thể đang đọc: phần mô tả + các cát xét. `target` = -1 → đang ghi vào phần mô tả.
nonisolated struct GrossDoc: Sendable {
    struct Snapshot: Sendable, Equatable {
        var body: String
        var cassettes: [GrossCassette]
        var target: Int
        var pathcode: String
        var oneShot: Bool
    }

    init(pathcode: String = "") { self.pathcode = pathcode }

    var body = ""
    var cassettes: [GrossCassette] = []
    var target = -1
    var history: [Snapshot] = []
    /// Pathcode của ca đang đọc
    var pathcode = ""
    /// Cát xét đang mở chỉ để ghi một ghi chú — có nội dung xong thì quay lại phần mô tả
    var oneShot = false

    var snapshot: Snapshot { Snapshot(body: body, cassettes: cassettes, target: target, pathcode: pathcode, oneShot: oneShot) }
    mutating func restore(_ s: Snapshot) {
        body = s.body; cassettes = s.cassettes; target = s.target; pathcode = s.pathcode; oneShot = s.oneShot
    }

    /// Đổi pathcode của ca: cát xét đang mang pathcode cũ (hoặc chưa có) đổi theo.
    mutating func setPathcode(_ code: String) {
        let old = pathcode
        pathcode = code
        for i in cassettes.indices where cassettes[i].pathcode.isEmpty || cassettes[i].pathcode == old {
            cassettes[i].pathcode = code
        }
    }

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
        // biến thể bộ nhận dạng hay viết: "Á 1", "à một", "bi hai" (đọc kiểu Anh)…
        "á": "A", "à": "A", "ả": "A", "ã": "A", "ạ": "A", "â": "A", "ă": "A", "ây": "A",
        "bi": "B", "si": "C", "xi": "C", "đi": "D",
    ]
    /// "cát xét" và các cách bộ nhận dạng hay viết sai: các xét, cát sét, ca-xét, cassette, khối nến…
    // Whisper/PhoWhisper còn viết: "cắt xét", "cách xét", "cắt xe,", "khắc sét"… (quan sát thực tế)
    private static let cassRx = "(?:(?:c|k|kh)[aáàảãạăắằẳẵặâấầẩẫậ](?:t|c|ch)?[\\s,-]*[xs][eéèẻẽẹêếềểễệ](?:t|c)?|cass?ett?e|khối\\s+nến|khuôn\\s+nến|block|blốc)"
    private static let letRx = letters.keys.sorted { $0.count > $1.count }
        .map { $0.replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")
    private static let numWRx = "(?:một|mốt|hai|ba|bà|bá|bả|bốn|tư|năm|lăm|sáu|bảy|bẩy|tám|chín|mười|mươi|linh|lẻ|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
    private static let numRx = "([0-9]{1,2}|\(numWRx)(?:\\s+\(numWRx))*)"
    private static let enNum: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                               "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]

    /// Whisper hay viết "a bà" cho "a ba"
    private static let numFix: [String: String] = ["bà": "ba", "bá": "ba", "bả": "ba"]

    static func cassetteNumber(_ s: String) -> Int {
        let w = s.lowercased().split(whereSeparator: \.isWhitespace).map { numFix[String($0)] ?? String($0) }
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
        // "ca mới" / "chuyển ca" / "ca tiếp theo" [, mã ca …] → lưu ca đang đọc, mở ca mới
        (cmd("(?:(?:(?:chuyển|sang|bắt\\s+đầu|mở)\\s+)?ca\\s+(?:mới|tiếp(?:\\s+theo)?|kế(?:\\s+tiếp)?)|chuyển\\s+ca|new\\s+case|next\\s+case)"
             + "(?:[\\s,.:]+(?:mã\\s+ca|mã\\s+bệnh\\s+phẩm|mã\\s+giải\\s+phẫu\\s+bệnh|pathcode|path\\s+code|case\\s+number)(?:\\s+là)?[\\s:]+(.+)$)?"),
         { g in .newCase(spokenCode(g[1] ?? "")) }),
        (cmd("(?:mã\\s+ca|mã\\s+bệnh\\s+phẩm|mã\\s+giải\\s+phẫu\\s+bệnh|pathcode|path\\s+code|case\\s+number)(?:\\s+là)?[\\s:]+(.+)$"),
         { g in .pathcode(spokenCode(g[1] ?? "")) }),
        (cmd("\(cassRx)[\\s,]+(?:số\\s+|number\\s+)?(?:(\(letRx))[\\s,-]*)?\(numRx)(?:[\\s,]+là(?=\\s|$))?"),
         { g in .cassette((g[1].map(letter) ?? "") + String(cassetteNumber(g[2] ?? ""))) }),
        (cmd("mẫu\\s+(\(letRx))\\s*-?\\s*\(numRx)(?:\\s+là(?=\\s|$))?"),
         { g in .cassette(letter(g[1] ?? "") + String(cassetteNumber(g[2] ?? ""))) }),
        (cmd("(?:\(cassRx)|khối|mẫu)\\s+(?:tiếp(?:\\s+theo)?|kế\\s+tiếp|next)|next\\s+(?:cassette|block)"),
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
        // "XXX ne ne Ex Ex Ex": cách bộ nhận dạng iPhone đã viết "xuống dòng" (quan sát thực tế)
        (cmd("xuống\\s+(?:dòng|giòng|ròng)|xxx(?:\\s+(?:ne|ex))*|new\\s+line"), { _ in .newline }),
        (cmd("đoạn\\s+mới|sang\\s+đoạn(?:\\s+mới)?|new\\s+paragraph"), { _ in .para }),
        (cmd("(?:xoá|xóa)\\s+câu(?:\\s+(?:cuối|vừa\\s+rồi|trước))?|hoàn\\s+tác|scratch\\s+that|undo\\s+that"), { _ in .undo }),
        (cmd("tạm\\s+dừng(?:\\s+ghi)?|pause\\s+dictation"), { _ in .pause }),
        (cmd("tiếp\\s+tục\\s+ghi|ghi\\s+tiếp|resume\\s+dictation"), { _ in .resume }),
        (cmd("(?:dừng|kết\\s+thúc)\\s+ghi(?:\\s+âm)?|stop\\s+dictation"), { _ in .stop }),
    ]

    // MARK: Pathcode đọc bằng giọng: "gê pê bê hai bốn gạch không một hai" → "GPB24-012"

    private static let codeLetters: [String: String] = letters.merging([
        "gê": "G", "pê": "P", "pờ": "P", "ét": "S", "ét xì": "S", "xờ": "S", "en": "N", "nờ": "N", "em": "M", "mờ": "M",
        "o": "O", "ô": "O", "quy": "Q", "rờ": "R", "e rờ": "R", "tê": "T", "tờ": "T", "u": "U", "vê": "V", "vờ": "V",
        "ích": "X", "ích xì": "X", "i dài": "Y", "dét": "Z", "ka": "K", "lờ": "L", "e lờ": "L", "gi": "J",
    ]) { _, b in b }
    private static let codeDigits: [String: String] = [
        "không": "0", "linh": "0", "một": "1", "mốt": "1", "hai": "2", "ba": "3", "bốn": "4", "tư": "4", "năm": "5", "lăm": "5",
        "sáu": "6", "bảy": "7", "bẩy": "7", "tám": "8", "chín": "9",
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9",
    ]
    private static let codeTrailRx = rx("[.,;:!?]+$", [])

    static func spokenCode(_ raw: String) -> String {
        let cleaned = replace(raw.precomposedStringWithCanonicalMapping.lowercased(), codeTrailRx, "")
        let w = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        var out = ""
        var i = 0
        while i < w.count {
            let two: String? = i + 1 < w.count ? w[i] + " " + w[i + 1] : nil
            if let two, let l = codeLetters[two] { out += l; i += 2; continue }
            let t = w[i]
            if ["gạch", "ngang", "dash", "-"].contains(t) {
                out += "-"
                i += (two == "gạch ngang") ? 2 : 1
                continue
            }
            if ["mươi", "mười", "trăm"].contains(t) { i += 1; continue }   // pathcode đọc từng chữ số
            if let d = codeDigits[t] { out += d }
            else if let l = codeLetters[t] { out += l }
            else { out += String(t.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" }).uppercased() }
            i += 1
        }
        return out
    }

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
            let b = replace(before, leadingPunctRx, "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !b.isEmpty { ops.append(.text(b)) }
            ops.append(op)
            // dấu câu tự thêm ngay sau lệnh → bỏ
            rest = replace(ns.substring(from: m.range.location + m.range.length), leadingPunctRx, "")
        }
        let r = replace(rest, leadingPunctRx, "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Ghi chú "(A1)" vào mô tả tại chỗ đang đọc; câu mô tả kết thúc ở đó → "… xanh (A1)."
    static func appendMarker(_ prev: String, _ code: String) -> String {
        var t = prev
        while let l = t.last, l.isWhitespace { t.removeLast() }
        guard !t.isEmpty else { return prev }
        let tail = String(prev.dropFirst(t.count))     // giữ xuống dòng phía sau
        var mark = "."
        if let l = t.last, ".,;:!?".contains(l) {
            if l != "," && l != ";" { mark = String(l) }
            t.removeLast()
        }
        return t + " (\(code))" + mark + tail
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
                      corrections: [GrossCorrection] = [],
                      cassetteReturn: Bool = true, inlineMarker: Bool = true) -> [GrossSignal] {
        var signals: [GrossSignal] = []
        var paused = paused
        var snap = doc.snapshot
        var pushed = false
        var textSnap: GrossDoc.Snapshot?
        var gotNote = false
        // Mở cát xét khi đang đọc mô tả: ghi chú cát xét tách riêng, xong câu thì quay lại mô tả
        func openCassette(_ code: String) {
            // đang ở mô tả, hoặc vừa ghi chú một cát xét khác trong cùng mạch → mã vẫn vào mô tả
            if doc.target >= 0, doc.target < doc.cassettes.count {      // khép ghi chú cát xét trước: "…," → "…."
                var t = doc.cassettes[doc.target].text
                while let l = t.last, l.isWhitespace { t.removeLast() }
                if let l = t.last, l == "," || l == ";" { t.removeLast(); t += "." }
                doc.cassettes[doc.target].text = t
            }
            if (doc.target < 0 || doc.oneShot) && inlineMarker { doc.body = appendMarker(doc.body, code) }
            let pc = doc.pathcode
            if let k = doc.cassettes.firstIndex(where: { $0.code == code && $0.pathcode == pc }) { doc.target = k }
            else {
                doc.cassettes.append(GrossCassette(code: code, text: "", pathcode: pc))
                doc.target = doc.cassettes.count - 1
            }
            doc.oneShot = cassetteReturn
            gotNote = false
        }
        // ghi chú cát xét đã có chữ → khép lại, quay về mô tả
        func closeNote() {
            guard doc.oneShot, doc.target >= 0, doc.target < doc.cassettes.count,
                  !doc.cassettes[doc.target].text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            doc.target = -1; doc.oneShot = false; gotNote = false
        }
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
            case .text(let raw):
                remember()
                textSnap = doc.snapshot
                var t = normalizeMeasurements(applyCorrections(raw, corrections))
                // ghi chú cát xét đến ở lượt nói sau, bắt đầu bằng "Là …" → bỏ chữ "là"
                if doc.target >= 0, doc.target < doc.cassettes.count, doc.oneShot,
                   doc.cassettes[doc.target].text.trimmingCharacters(in: .whitespaces).isEmpty {
                    t = replace(t, leadingLaRx, "")
                }
                // ghi chú cát xét chỉ kéo dài tới hết câu đầu tiên; phần còn lại của lượt nói về mô tả
                if doc.target >= 0, doc.oneShot, let end = firstSentenceEnd(t) {
                    doc.current = appendText(doc.current, String(t[..<end]).trimmingCharacters(in: .whitespaces))
                    doc.target = -1; doc.oneShot = false; gotNote = false
                    let rest = String(t[end...]).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { doc.current = appendText(doc.current, rest) }
                } else {
                    doc.current = appendText(doc.current, t)
                    if doc.target >= 0 { gotNote = true }
                }
            case .punct(let m):
                remember(); doc.current = appendPunct(doc.current, m)
                if m == "." || m == "?" || m == "!" { closeNote() }
            case .newline:
                remember()
                closeNote()
                var t = doc.current
                while let l = t.last, l == " " || l == "\t" { t.removeLast() }
                doc.current = t + "\n"
            case .para:
                remember()
                closeNote()
                var t = doc.current
                while let l = t.last, l.isWhitespace { t.removeLast() }
                doc.current = t + "\n\n"
            case .bullet:
                remember()
                closeNote()
                var t = doc.current
                while let l = t.last, l == " " || l == "\t" { t.removeLast() }
                if let l = t.last, l != "\n" { t += "\n" }
                doc.current = t + "- "
            case .cassette(let code):
                remember(); openCassette(code)
            case .nextCassette:
                remember(); openCassette(nextCode(doc))
            case .body:
                remember(); doc.target = -1; doc.oneShot = false
            case .pathcode(let code):
                remember()
                if !code.isEmpty { doc.setPathcode(code) }
            case .newCase(let code):
                closeNote()
                let finished = doc.snapshot
                doc = GrossDoc(pathcode: code)          // lịch sử hoàn tác cũng bắt đầu lại
                signals.append(.newCase(finished))
                snap = doc.snapshot; pushed = false; textSnap = nil; gotNote = false
            case .undo:
                // có chữ đọc trước lệnh trong cùng câu → chỉ xoá đoạn chữ đó; lệnh đứng riêng → xoá câu đọc trước
                if let ts = textSnap { doc.restore(ts); textSnap = nil; gotNote = false }
                else if let prev = doc.history.popLast() { doc.restore(prev); snap = doc.snapshot; pushed = false }
            case .pause: paused = true; signals.append(.pause)
            case .resume: signals.append(.resume)
            case .stop: signals.append(.stop)
            }
        }
        // ghi chú cát xét đã có nội dung → các câu sau quay lại phần mô tả
        if doc.oneShot && gotNote && doc.target >= 0 { doc.target = -1; doc.oneShot = false }
        return signals
    }

    private static let leadingLaRx = rx("^là\\s+")
    private static let sentenceEndRx = rx("[.!?](?=\\s|$)", [])

    /// Vị trí ngay sau dấu kết câu đầu tiên ("2,5" / "Ki-67" không bị tính).
    static func firstSentenceEnd(_ t: String) -> String.Index? {
        guard let m = sentenceEndRx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range, in: t) else { return nil }
        return r.upperBound
    }

    /// Nút "Cát xét +": thêm cát xét kế tiếp (và mã "(A2)" vào mô tả) nhưng KHÔNG đổi chỗ đang ghi —
    /// lời đọc vẫn vào phần mô tả; chạm "Ghi vào đây" trên thẻ để đọc vào cát xét.
    @discardableResult
    static func addCassette(to doc: inout GrossDoc, inlineMarker: Bool = true) -> Int {
        doc.history.append(doc.snapshot)
        if doc.history.count > 50 { doc.history.removeFirst() }
        let code = nextCode(doc)
        if doc.target >= 0, doc.target < doc.cassettes.count {
            var t = doc.cassettes[doc.target].text
            while let l = t.last, l.isWhitespace { t.removeLast() }
            if let l = t.last, l == "," || l == ";" { t.removeLast(); t += "." }
            doc.cassettes[doc.target].text = t
        }
        if (doc.target < 0 || doc.oneShot) && inlineMarker { doc.body = appendMarker(doc.body, code) }
        doc.cassettes.append(GrossCassette(code: code, text: "", pathcode: doc.pathcode))
        if doc.oneShot { doc.target = -1; doc.oneShot = false }
        return doc.cassettes.count - 1
    }

    /// Xem trước tức thì: áp phần đang nghe (chưa chốt) lên bản sao — không đụng văn bản thật.
    static func preview(_ doc: GrossDoc, volatile: String, corrections: [GrossCorrection],
                        cassetteReturn: Bool, inlineMarker: Bool) -> GrossDoc {
        var d = doc
        d.history = []
        apply(parse(volatile), to: &d, corrections: corrections,
              cassetteReturn: cassetteReturn, inlineMarker: inlineMarker)
        return d
    }

    static func reportText(_ doc: GrossDoc, english: Bool = false) -> String {
        let pc = doc.pathcode.trimmingCharacters(in: .whitespaces)
        let header = pc.isEmpty ? "" : "Pathcode: \(pc)\n"
        let body = doc.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !doc.cassettes.isEmpty else { return (header + body).trimmingCharacters(in: .whitespacesAndNewlines) }
        let head = english ? "SECTIONS / CASSETTES:" : "CẮT LỌC – CÁT XÉT:"
        let list = doc.cassettes.map { "\($0.label): \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
        return header + (body.isEmpty ? "" : body + "\n\n") + head + "\n" + list
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
