import Foundation

/// Che thông tin định danh bệnh nhân trước khi gửi văn bản ra ngoài (Claude API).
/// Thay mỗi giá trị bằng nhãn giữ chỗ như [TÊN_1], [PID_1]…; cùng giá trị → cùng nhãn.
/// Sau khi nhận bản dịch, `restore` đặt lại giá trị gốc ngay trên máy — giá trị thật không rời khỏi iPhone.
///
/// Quy tắc (ICU regex, không phân biệt hoa thường với nhãn trường):
///  • Trường có nhãn: Họ tên / Bệnh nhân / Patient / Name; PID / Mã BN / MRN / Số hồ sơ;
///    Mã bệnh phẩm / Số GPB / Specimen / Accession; Ngày sinh / Năm sinh / DOB; Địa chỉ; SĐT; CCCD / CMND / Hộ chiếu.
///  • Nhãn và danh xưng phải đứng đầu từ ("Không" không chứa danh xưng "ông", "Mucoepidermoid" không chứa nhãn "PID").
///  • Không nhãn: họ tên tiếng Việt bắt đầu bằng họ phổ biến (Nguyễn Văn A…; họ trùng từ thường như Cao, Mai, Hà
///    cần đủ 3 chữ), tên không vắt qua dòng, danh xưng + tên (Ông/Bà/Mr./Mrs.),
///    mã bệnh phẩm dạng GPB-24-12345 / S24-01234, dãy 9–12 chữ số (CCCD, CMND, SĐT), hộ chiếu (C1234567),
///    email, ngày đầy đủ (12/03/1965, 1965-03-12).
/// Bản Python tương đương để kiểm thử: Tools/test_redactor.py
enum PHIRedactor {

    enum Kind: String, CaseIterable, Sendable {
        case name = "TÊN", pid = "PID", specimen = "MÃ_BP", dob = "NGÀY_SINH", date = "NGÀY"
        case idDoc = "GIẤY_TỜ", phone = "SĐT", email = "EMAIL", address = "ĐỊA_CHỈ", custom = "ẨN"

        var label: String {
            switch self {
            case .name: "Họ tên"
            case .pid: "Mã bệnh nhân / hồ sơ"
            case .specimen: "Mã bệnh phẩm"
            case .dob: "Ngày sinh"
            case .date: "Ngày tháng"
            case .idDoc: "CCCD / CMND / hộ chiếu"
            case .phone: "Số điện thoại"
            case .email: "Email"
            case .address: "Địa chỉ"
            case .custom: "Cụm tự che"
            }
        }
    }

    struct Replacement: Identifiable, Hashable, Sendable {
        var id: String { placeholder }
        let placeholder: String
        let original: String
        let kind: Kind
    }

    struct Result: Sendable {
        let text: String
        let replacements: [Replacement]
        struct KindCount: Identifiable, Sendable {
            var id: String { kind.rawValue }
            let kind: Kind
            let count: Int
        }
        var counts: [KindCount] {
            Kind.allCases.compactMap { k in
                let n = replacements.filter { $0.kind == k }.count
                return n > 0 ? KindCount(kind: k, count: n) : nil
            }
        }
    }

    // MARK: Quy tắc

    private struct Rule {
        let kind: Kind
        let regex: NSRegularExpression
        /// Nhóm bắt chứa giá trị cần che (0 = cả chuỗi khớp)
        let group: Int
    }

    private static let familyNames = [
        "Nguyễn", "Trần", "Lê", "Phạm", "Hoàng", "Huỳnh", "Phan", "Vũ", "Võ", "Đặng", "Bùi", "Đỗ",
        "Hồ", "Ngô", "Dương", "Lý", "Đinh", "Đoàn", "Lâm", "Trương", "Mai", "Tô", "Trịnh", "Hà",
        "Cao", "Lưu", "Châu", "Tạ", "Quách", "Thái", "Lương", "Tăng", "Kiều", "Triệu",
    ]

    /// Địa danh / cụm thường gặp bắt đầu bằng họ — không coi là tên người.
    private static let notNames = [
        "Hà Nội", "Hà Tĩnh", "Hà Giang", "Hà Nam", "Châu Âu", "Châu Á", "Châu Phi", "Châu Mỹ",
        "Cao Bằng", "Thái Bình", "Thái Nguyên", "Hồ Chí Minh", "Lâm Đồng", "Đồng Nai",
    ]

    // Tên riêng: chữ hoa đầu + chữ thường/dấu (Nguyễn Văn A, Smith)
    private static let capWord = #"\p{Lu}[\p{Ll}\p{M}]*"#

    /// Họ trùng từ thường ("Cao" = cao, "Mai" = ngày mai, "Hà"…) → cần đủ họ + 2 chữ ("Cao Văn Minh"),
    /// tránh che nhầm ô bảng "Cao Lớn". Các họ còn lại: họ + 1–3 chữ.
    private static let ambiguousFamilies: Set<String> = ["Cao", "Mai", "Hà", "Lý", "Lâm", "Thái", "Tô", "Châu", "Tăng",
                                                         "Lương", "Kiều", "Hồ", "Tạ", "Lưu"]

    /// Ngày đứng sau các cụm này là ngày truy cập / cập nhật tài liệu, không phải định danh.
    private static let documentDateCues = ["truy cập", "cập nhật", "ban hành", "phiên bản", "accessed", "updated",
                                           "published", "retrieved", "version"]

    // Chỉ đọc sau khi khởi tạo; NSRegularExpression không đổi trạng thái → dùng chung an toàn.
    private static let rules: [Rule] = {
        func r(_ kind: Kind, _ pattern: String, ci: Bool = true) -> Rule {
            Rule(kind: kind,
                 regex: try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []),
                 group: 1)
        }
        let sep = #"\s*[:：#]?\s*"#
        let stop = #"(?=\s*(?:[\n,;|]|\s{2,}|$|\s-\s|\s(?i:tuổi|giới|nam|nữ|sinh|PID|mã|age|sex|DOB)\b))"#
        let nameValue = #"(\p{Lu}[^\n,;|]{1,59}?)"# + stop
        let code = #"([A-Za-z0-9][A-Za-z0-9\-/\.]{1,23}[A-Za-z0-9])"#
        // Tên người không vắt qua dòng (ô bảng "Tăng / Tăng" trên các dòng liền nhau) → chỉ khoảng trắng ngang.
        let gap = "[ \\t]+"
        let name = "(" + capWord + "(?:" + gap + capWord + "){0,4})"
        let families = familyNames.filter { !ambiguousFamilies.contains($0) }.joined(separator: "|")
        let ambiguous = ambiguousFamilies.sorted().joined(separator: "|")
        return [
            // ---- Trường có nhãn (ưu tiên trước) ----
            r(.name, #"(?<![\p{L}])(?i:họ\s+và\s+tên|họ\s+tên|tên\s+bệnh\s+nhân|tên\s+BN|bệnh\s+nhân|BN|patient(?:'s)?\s+name|patient|name)\s*[:：]\s*"# + nameValue, ci: false),
            r(.pid, #"(?<![\p{L}])(?:PID|mã\s+BN|mã\s+bệnh\s+nhân|mã\s+y\s+tế|mã\s+hồ\s+sơ|số\s+hồ\s+sơ|số\s+bệnh\s+án|số\s+vào\s+viện|MRN|hospital\s+(?:number|no\.?)|medical\s+record\s+(?:number|no\.?))"# + sep + code),
            r(.specimen, #"(?<![\p{L}])(?:mã\s+bệnh\s+phẩm|mã\s+GPB|số\s+GPB|mã\s+tiêu\s+bản|số\s+tiêu\s+bản|mã\s+mẫu|specimen\s+(?:ID|number|no\.?)|accession(?:\s+(?:number|no\.?))?|case\s+(?:ID|number|no\.?)|lab\s+(?:ID|no\.?))"# + sep + code),
            r(.dob, #"(?<![\p{L}])(?:ngày\s+sinh|năm\s+sinh|sinh\s+ngày|sinh\s+năm|NS|DOB|date\s+of\s+birth|born(?:\s+on)?)"# + sep + #"(\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}|\d{4}-\d{2}-\d{2}|(?:19|20)\d{2})"#),
            r(.address, #"(?<![\p{L}])(?:địa\s+chỉ|address)\s*[:：]\s*([^\n]{3,120})"#),
            r(.phone, #"(?<![\p{L}])(?:SĐT|SDT|điện\s+thoại|phone|tel|mobile)"# + sep + #"(\+?\d[\d\s.\-]{7,14}\d)"#),
            r(.idDoc, #"(?<![\p{L}])(?:CCCD|CMND|CMT|căn\s+cước|passport|hộ\s+chiếu|ID\s+card)(?:\s+(?:số|no\.?))?"# + sep + #"([A-Z0-9]{6,12})"#),
            // ---- Không nhãn ----
            r(.name, "(?<![\\p{L}])(?:[Ôô]ng|[Bb]à|anh|[Cc]hị|cô|chú|bác|cháu|Mr\\.?|Mrs\\.?|Ms\\.?|Miss)" + gap + name, ci: false),
            r(.name, "(?<![\\p{L}])((?:" + families + ")(?:" + gap + capWord + "){1,3})(?![\\p{L}])", ci: false),
            r(.name, "(?<![\\p{L}])((?:" + ambiguous + ")(?:" + gap + capWord + "){2,3})(?![\\p{L}])", ci: false),
            r(.email, #"([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})"#),
            r(.specimen, #"(?<![A-Za-z0-9])([A-Z]{1,6}[\-/]?\d{2}[\-/.]\d{3,7})(?![A-Za-z0-9])"#, ci: false),
            r(.idDoc, #"(?<![A-Za-z0-9])([A-Z]\d{7,8})(?![A-Za-z0-9])"#, ci: false),
            r(.phone, #"(?<![\d])(\+84\s?\d{9}|0\d{9})(?![\d])"#),
            r(.idDoc, #"(?<![\d.,])(\d{9}|\d{12})(?![\d.,])"#),
            r(.date, #"(?<![\d/])(\d{1,2}[/\-.]\d{1,2}[/\-.](?:19|20)\d{2}|(?:19|20)\d{2}-\d{2}-\d{2})(?![\d/])"#),
        ]
    }()

    // MARK: Che / khôi phục

    /// `extraTerms`: cụm người dùng tự yêu cầu che thêm.
    static func redact(_ input: String, extraTerms: [String] = []) -> Result {
        var text = input
        var map: [String: Replacement] = [:]          // giá trị gốc → nhãn
        var counters: [Kind: Int] = [:]

        func placeholder(for value: String, kind: Kind) -> String {
            let key = value.trimmingCharacters(in: .whitespaces)
            if let existing = map[key.lowercased()] { return existing.placeholder }
            counters[kind, default: 0] += 1
            let ph = "[\(kind.rawValue)_\(counters[kind]!)]"
            map[key.lowercased()] = Replacement(placeholder: ph, original: key, kind: kind)
            return ph
        }

        // Cụm tự che trước (người dùng biết rõ nhất)
        for term in extraTerms.map({ $0.trimmingCharacters(in: .whitespaces) }) where term.count >= 2 {
            let ph = placeholder(for: term, kind: .custom)
            text = text.replacingOccurrences(of: term, with: ph, options: [.caseInsensitive])
        }

        for rule in rules {
            let ns = text as NSString
            let matches = rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let out = NSMutableString(string: text)
            for m in matches.reversed() {
                let range = m.range(at: rule.group)
                guard range.location != NSNotFound else { continue }
                let value = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
                // không che lại nhãn giữ chỗ đã có, và bỏ giá trị quá ngắn
                guard value.count >= 2, !value.hasPrefix("[") else { continue }
                if rule.kind == .name,
                   notNames.contains(where: { value == $0 || value.hasPrefix($0 + " ") }) { continue }
                if rule.kind == .date {
                    let from = max(0, range.location - 24)
                    let lead = ns.substring(with: NSRange(location: from, length: range.location - from)).lowercased()
                    if documentDateCues.contains(where: lead.contains) { continue }
                }
                out.replaceCharacters(in: range, with: placeholder(for: value, kind: rule.kind))
            }
            text = out as String
        }
        let reps = map.values.sorted { $0.placeholder.localizedStandardCompare($1.placeholder) == .orderedAscending }
        return Result(text: text, replacements: reps)
    }

    /// Đặt lại giá trị gốc vào bản dịch (nhãn giữ chỗ được giữ nguyên khi dịch).
    static func restore(_ text: String, using replacements: [Replacement]) -> String {
        var out = text
        for r in replacements.sorted(by: { $0.placeholder.count > $1.placeholder.count }) {
            out = out.replacingOccurrences(of: r.placeholder, with: r.original)
        }
        return out
    }
}
