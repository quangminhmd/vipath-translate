import Foundation

/// Tách câu tiếng Anh cho dịch thời gian thực. Tránh cắt sai ở viết tắt y khoa / học thuật
/// (e.g., i.e., et al., Fig., Dr., vs., approx.), số thập phân (3.5 cm) và ký hiệu như p.R132H.
/// Bản Python tương đương để kiểm thử: Tools/test_sentences.py
enum SentenceSplitter {

    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "al", "etc", "fig", "figs", "dr", "drs", "prof", "mr", "mrs", "ms",
        "vs", "approx", "no", "nos", "cf", "st", "ca", "resp", "vol", "ref", "refs",
        "tab", "eq", "dept", "univ", "inc", "ltd", "jr", "sr", "mt", "min", "max", "pt", "pts",
    ]

    /// Tách toàn bộ văn bản thành câu (xuống dòng luôn là ranh giới).
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).flatMap { line -> [String] in
            let (complete, rest) = completeSentences(in: line)
            let tail = rest.trimmingCharacters(in: .whitespaces)
            return complete + (tail.isEmpty ? [] : [tail])
        }
    }

    /// Lấy các câu đã kết thúc; phần còn lại (câu đang nói / đang gõ dở) trả về riêng.
    static func completeSentences(in text: String) -> (complete: [String], remainder: String) {
        let chars = Array(text)
        var sentences: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" {
                // gom dấu kết thúc liên tiếp và dấu đóng ngoặc / nháy
                var end = i + 1
                while end < chars.count, ".!?)]\"”’'".contains(chars[end]) { end += 1 }
                let atEnd = end >= chars.count
                let followedBySpace = !atEnd && chars[end].isWhitespace
                if (atEnd || followedBySpace) && isBoundary(chars: chars, dot: i, start: start, next: end) {
                    let s = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { sentences.append(s) }
                    start = end
                }
                i = end
                continue
            }
            i += 1
        }
        let rest = start < chars.count ? String(chars[start...]) : ""
        return (sentences, rest)
    }

    private static func isBoundary(chars: [Character], dot: Int, start: Int, next: Int) -> Bool {
        guard chars[dot] == "." else { return true }   // ! và ? luôn là ranh giới
        // từ đứng ngay trước dấu chấm
        var j = dot - 1
        while j >= start, !chars[j].isWhitespace, chars[j] != "(" { j -= 1 }
        let word = String(chars[(j + 1)..<dot]).lowercased()
        if abbreviations.contains(word) { return false }
        if word.count == 1, word.first?.isLetter == true { return false }  // viết tắt tên: "J. Smith"
        // câu tiếp theo phải bắt đầu bằng chữ hoa, số, hoặc ngoặc / nháy
        var k = next
        while k < chars.count, chars[k].isWhitespace { k += 1 }
        guard k < chars.count else { return true }
        let n = chars[k]
        return n.isUppercase || n.isNumber || "(\"“'[".contains(n)
    }
}
