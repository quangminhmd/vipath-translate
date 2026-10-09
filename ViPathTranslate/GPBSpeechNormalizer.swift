import Foundation

/// Chuẩn hoá ký hiệu giải phẫu bệnh trước khi đọc thành tiếng (dùng cho cả giọng iOS lẫn VieNeu).
/// Bộ chuẩn hoá chung của sea-g2p đọc sai vài ký hiệu GPB (đã kiểm tra trực tiếp với sea-g2p):
///   "CD20"    → "xê đê hai không"      ⇒ "xê đê 20"        → "xê đê hai mươi"
///   "1p/19q"  → "một phút … qui"       ⇒ "1 pê, 19 quy"    → "một pê, mười chín quy"
///   "pT1aN1b" → "pt một an một bê"     ⇒ "pê tê 1 a, nờ 1 bê"
///   "p.R132H" → (sea-g2p tách lỗi)      ⇒ "pê chấm rờ 132 hát" → "pê chấm rờ một trăm ba mươi hai hát"
///   "V600E"   → "vê sáu không không e" ⇒ "vê 600 e"        → "vê sáu trăm e"
/// Chữ cái được viết sẵn bằng tên tiếng Việt để sea-g2p không đọc thành đơn vị ("p" = phút)
/// hay đánh vần kiểu tiếng Anh.
///
/// Dùng NSRegularExpression (ICU) với ranh giới ASCII tường minh `(?<![A-Za-z0-9])` thay cho `\b`:
/// `\b` của Swift Regex theo Unicode TR29 coi "p.R132H" là MỘT từ nên không tách được "p.".
/// Bản Python tương đương để kiểm thử: Tools/test_speech_normalizer.py
enum GPBSpeechNormalizer {

    private static let letterNames: [Character: String] = [
        "A": "a", "B": "bê", "C": "xê", "D": "đê", "E": "e", "F": "ép", "G": "giê", "H": "hát",
        "I": "i", "J": "gi", "K": "ca", "L": "lờ", "M": "mờ", "N": "nờ", "O": "o", "P": "pê",
        "Q": "quy", "R": "rờ", "S": "ét", "T": "tê", "U": "u", "V": "vê", "W": "vê kép",
        "X": "ích", "Y": "i", "Z": "dét",
    ]

    /// "CD" → "xê đê"
    static func spell(_ s: String) -> String {
        s.map { letterNames[Character($0.uppercased())] ?? String($0) }.joined(separator: " ")
    }

    private static let L = "(?<![A-Za-z0-9])"   // ranh giới trái
    private static let R = "(?![A-Za-z0-9])"    // ranh giới phải

    private struct Rule {
        let regex: NSRegularExpression
        let transform: ([String?]) -> String    // nhóm bắt 1…n (nil nếu không khớp)
    }

    // Chỉ đọc sau khi khởi tạo; NSRegularExpression không đổi trạng thái → dùng chung an toàn.
    nonisolated(unsafe) private static let rules: [Rule] = {
        func rule(_ p: String, _ t: @escaping ([String?]) -> String) -> Rule {
            Rule(regex: try! NSRegularExpression(pattern: p), transform: t)
        }
        return [
            // 1p/19q, 11q/22q: đồng mất đoạn nhánh nhiễm sắc thể
            rule(L + #"(\d{1,2})([pq])/(\d{1,2})([pq])"# + R) { g in
                "\(g[0]!) \(spell(g[1]!)), \(g[2]!) \(spell(g[3]!))"
            },
            // HGVS protein: p.R132H, p.V600E, p.G12D, p.Q61*
            rule(L + #"p\.([A-Z])(\d+)([A-Z*])"#) { g in
                "pê chấm \(spell(g[0]!)) \(g[1]!) \(g[2]! == "*" ? "dừng" : spell(g[2]!))"
            },
            // TNM: pT1aN1bM0, ypT2N0, cT3N1M1a, pTis
            rule(L + #"(y?[pc]?)T(is|[0-4x][a-d]?)(N[0-3x][a-c]?)?(M[01x][a-c]?)?"# + R) { g in
                var head: [String] = []
                if let pre = g[0], !pre.isEmpty { head.append(spell(pre)) }
                head.append("tê")
                head.append(spaced(g[1]!))
                var parts = [head.joined(separator: " ")]
                if let n = g[2] { parts.append("nờ " + spaced(String(n.dropFirst()))) }
                if let m = g[3] { parts.append("mờ " + spaced(String(m.dropFirst()))) }
                return parts.joined(separator: ", ")
            },
            // Biến thể V600E, G12D, T790M (không có "p."): đọc số nguyên
            rule(L + #"([A-Z])(\d{2,4})([A-Z])"# + R) { g in
                "\(spell(g[0]!)) \(g[1]!) \(spell(g[2]!))"
            },
            // Dấu ấn / gen có số ≥ 2 chữ số: CD20, CK20, CD117, SOX10 → "hai mươi", không "hai không"
            rule(L + #"([A-Z]{2,5})(\d{2,3})"# + R) { g in
                "\(spell(g[0]!)) \(g[1]!)"
            },
        ]
    }()

    static func normalize(_ input: String) -> String {
        var s = input
        for rule in rules {
            let ns = s as NSString
            let matches = rule.regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let out = NSMutableString(string: s)
            for m in matches.reversed() {
                let groups: [String?] = (1..<m.numberOfRanges).map { i in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                }
                out.replaceCharacters(in: m.range, with: rule.transform(groups))
            }
            s = out as String
        }
        return s.replacingOccurrences(of: "×", with: " nhân ")
            .replacingOccurrences(of: "↑", with: " tăng ")
            .replacingOccurrences(of: "↓", with: " giảm ")
    }

    /// "1a" → "1 a", "is" → "i ét", "x" → "ích"
    private static func spaced(_ s: String) -> String {
        if s == "is" { return "i ét" }
        var groups: [String] = []
        var buf = ""
        for ch in s {
            if let last = buf.last, last.isNumber != ch.isNumber {
                groups.append(buf)
                buf = ""
            }
            buf.append(ch)
        }
        if !buf.isEmpty { groups.append(buf) }
        return groups.map { $0.first?.isNumber == true ? $0 : ($0 == "x" ? "ích" : $0) }
            .joined(separator: " ")
    }
}
