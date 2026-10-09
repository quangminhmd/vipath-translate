import Foundation
import Observation

/// Một bản dịch hoặc một phiên phụ đề đã lưu trên máy.
struct SavedItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case text, captions, transcript }

    struct Pair: Codable, Hashable, Sendable {
        var source: String
        var translation: String
        /// Giây kể từ đầu phiên phụ đề / đầu tệp
        var offset: Double
        /// Mốc kết thúc (chép lời từ tệp)
        var end: Double?
    }

    var id = UUID()
    var kind: Kind
    var createdAt = Date()
    var title: String
    var direction: TranslationDirection
    /// Mô hình offline đã dùng (vd. "Qwen3.5 4B")
    var engine: String
    var source: String
    var translation: String
    /// Bản dịch / hiệu đính của Claude (đã khôi phục định danh trên máy)
    var claudeTranslation: String?
    var claudeModel: String?
    var pairs: [Pair]?
    var duration: Double?

    static func autoTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(60)) + "…" : (t.isEmpty ? "Không tiêu đề" : t)
    }

    /// Văn bản để chia sẻ / chép.
    var exportText: String {
        var out = "\(title)\n\(createdAt.formatted(date: .abbreviated, time: .shortened)) · \(direction.label) · \(engine)\n"
        switch kind {
        case .text:
            out += "\n— \(direction.sourceName) —\n\(source)\n\n— \(direction.targetName) (offline) —\n\(translation)\n"
            if let c = claudeTranslation, !c.isEmpty {
                out += "\n— \(direction.targetName) (\(claudeModel ?? "Claude")) —\n\(c)\n"
            }
        case .captions, .transcript:
            for p in pairs ?? [] {
                out += "\n[\(Self.timestamp(p.offset))]\n\(p.source)\n\(p.translation)\n"
            }
        }
        return out
    }

    /// Chỉ phần dịch (phụ đề tiếng Việt liền mạch).
    var translationOnly: String {
        switch kind {
        case .text: claudeTranslation?.isEmpty == false ? claudeTranslation! : translation
        case .captions, .transcript: (pairs ?? []).map(\.translation).joined(separator: "\n")
        }
    }

    /// Các đoạn có mốc thời gian (để xuất SRT / VTT); thiếu mốc kết thúc thì lấy mốc đầu của đoạn sau.
    var segments: [TranscriptSegment] {
        let ps = pairs ?? []
        return ps.enumerated().map { i, p in
            let next = i + 1 < ps.count ? ps[i + 1].offset : p.offset + 4
            return TranscriptSegment(start: p.offset, end: p.end ?? max(p.offset + 1, min(next, p.offset + 8)),
                                     text: p.source, translation: p.translation)
        }
    }

    static func timestamp(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// Lưu mỗi mục thành một tệp JSON trong Documents/Saved, mã hoá khi máy khoá (completeFileProtection).
@MainActor
@Observable
final class SavedStore {
    static let shared = SavedStore()

    private(set) var items: [SavedItem] = []

    private let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saved", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        items = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(SavedItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func file(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    @discardableResult
    func save(_ item: SavedItem) -> Bool {
        guard let data = try? JSONEncoder().encode(item) else { return false }
        do {
            try data.write(to: file(item.id), options: [.atomic, .completeFileProtection])
        } catch { return false }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
        return true
    }

    func delete(_ item: SavedItem) {
        try? FileManager.default.removeItem(at: file(item.id))
        items.removeAll { $0.id == item.id }
    }

    func rename(_ item: SavedItem, to title: String) {
        var it = item
        it.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? item.title : title
        save(it)
    }
}
