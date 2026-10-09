import Foundation
import Observation

/// Một đề xuất thuật ngữ từ Claude chờ bác sĩ duyệt.
struct TermSuggestion: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var english: String
    var vietnamese: String
    var note: String
    /// Bản dịch hiện có trong glossary (nếu đề xuất là SỬA một mục đã có).
    var existingVi: String?
    var model: String
    var createdAt = Date()
}

/// Vòng học thuật ngữ (giống bước learner của Vitranslate):
/// Claude sửa thuật ngữ hiếm → đề xuất vào đây → bác sĩ duyệt → thêm vào glossary người dùng
/// → các lần sau mô hình offline nhận đúng thuật ngữ qua prompt, ít phải gọi Claude hơn.
@MainActor
@Observable
final class TermSuggestionStore {
    static let shared = TermSuggestionStore()

    private(set) var pending: [TermSuggestion] = []
    private(set) var approvedCount = 0
    private var rejected: Set<String> = []

    private struct FileData: Codable {
        var pending: [TermSuggestion]
        var rejected: [String]
        var approvedCount: Int
    }

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("term_suggestions.json")
    }

    private init() {
        if let data = try? Data(contentsOf: url),
           let f = try? JSONDecoder().decode(FileData.self, from: data) {
            pending = f.pending
            rejected = Set(f.rejected)
            approvedCount = f.approvedCount
        }
    }

    private static func key(_ en: String, _ vi: String) -> String {
        en.lowercased().trimmingCharacters(in: .whitespaces) + "→" + vi.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Nhận đề xuất mới từ Claude; trả về số đề xuất thật sự mới (đã lọc trùng / đã có / đã từ chối).
    @discardableResult
    func ingest(_ suggestions: [ClaudeTermSuggestion], glossary: GlossaryStore, model: ClaudeModel) -> Int {
        var added = 0
        for s in suggestions {
            let en = s.english.trimmingCharacters(in: .whitespacesAndNewlines)
            let vi = s.vietnamese.trimmingCharacters(in: .whitespacesAndNewlines)
            guard en.count >= 2, vi.count >= 2, en.count <= 80, vi.count <= 120,
                  !en.contains("["), !vi.contains("["),                    // không bao giờ học nhãn che PHI
                  en.lowercased() != vi.lowercased(),                       // thuật ngữ giữ nguyên → không cần
                  en.contains(where: \.isLetter),
                  !rejected.contains(Self.key(en, vi)),
                  !glossary.contains(en: en, vi: vi) else { continue }
            let existing = glossary.entry(forEnglish: en)?.vi
            let item = TermSuggestion(english: en, vietnamese: vi, note: s.note ?? "",
                                      existingVi: existing, model: model.shortName)
            if let i = pending.firstIndex(where: { $0.english.lowercased() == en.lowercased() }) {
                pending[i] = item
            } else {
                pending.append(item)
                added += 1
            }
        }
        save()
        return added
    }

    /// Bác sĩ duyệt (có thể đã sửa lại en / vi).
    func approve(_ s: TermSuggestion, english: String, vietnamese: String, note: String, glossary: GlossaryStore) {
        let date = Date().formatted(date: .numeric, time: .omitted)
        var n = "Claude đề xuất · BS duyệt \(date)"
        if !note.trimmingCharacters(in: .whitespaces).isEmpty { n += " · \(note)" }
        glossary.addUserEntry(en: english, vi: vietnamese, note: n)
        pending.removeAll { $0.id == s.id }
        approvedCount += 1
        save()
    }

    func reject(_ s: TermSuggestion) {
        rejected.insert(Self.key(s.english, s.vietnamese))
        pending.removeAll { $0.id == s.id }
        save()
    }

    private func save() {
        let f = FileData(pending: pending, rejected: Array(rejected), approvedCount: approvedCount)
        if let data = try? JSONEncoder().encode(f) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
