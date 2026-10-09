import Foundation
import Observation

/// iOS không cho app ở nền gửi lệnh GPU (iPhone không có background GPU),
/// nên mọi lượt sinh văn bản MLX phải dừng khi app rời tiền cảnh và chờ quay lại.
@MainActor
@Observable
final class AppActivity {
    static let shared = AppActivity()
    var isActive = true

    func waitUntilActive() async {
        while !isActive, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// Kiểu 1 — dịch khi gõ: chờ người dùng ngừng gõ ~0,7 s, tách câu,
/// chỉ dịch các câu mới / đã sửa, câu cũ lấy từ bộ nhớ đệm.
@MainActor
@Observable
final class LiveTypingTranslator {
    struct Line: Identifiable {
        let id: Int
        let source: String
        var output: String
        var hits: [GlossaryHit]
        var missing: [GlossaryHit]
        var isDone: Bool
    }

    var lines: [Line] = []
    var isWorking = false
    var outputText: String { lines.map(\.output).joined(separator: " ") }
    var allMissing: [GlossaryHit] {
        var seen = Set<String>()
        return lines.flatMap(\.missing).filter { seen.insert($0.id).inserted }
    }

    private let vm: TranslatorViewModel
    private struct Cached { let text: String; let missing: [GlossaryHit] }
    private var cache: [String: Cached] = [:]
    private var debounce: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var generation = 0

    init(vm: TranslatorViewModel) { self.vm = vm }

    /// Gọi mỗi khi nội dung ô nhập thay đổi.
    func textChanged(_ text: String) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            schedule(text)
        }
    }

    func cancel() {
        debounce?.cancel()
        work?.cancel()
        generation += 1
        isWorking = false
    }

    func reset() {
        cancel()
        lines = []
    }

    /// Xoá bộ nhớ đệm (khi đổi mô hình hoặc sửa glossary).
    func invalidateCache() { cache.removeAll() }

    /// Chiều dịch của lượt gần nhất (để hiển thị nhãn ngôn ngữ đích).
    private(set) var direction: TranslationDirection = .enToVi

    private func cacheKey(_ s: String) -> String { "\(vm.loadedModel?.rawValue ?? "")|\(direction.rawValue)|\(s)" }

    private func schedule(_ text: String) {
        guard vm.loadedModel != nil else { return }
        let dir = vm.direction
        if dir != direction { lines = [] }      // đổi chiều → không giữ bản dịch cũ trên màn hình
        direction = dir
        let glossary = vm.glossary
        let sentences = SentenceSplitter.split(text).filter { $0.contains(where: \.isLetter) }
        lines = sentences.enumerated().map { i, s in
            if let c = cache[cacheKey(s)] {
                return Line(id: i, source: s, output: c.text, hits: glossary.hits(in: s, direction: dir), missing: c.missing, isDone: true)
            }
            // giữ bản dịch cũ của câu cùng vị trí (đang gõ dở) để màn hình không nhấp nháy
            let old = (i < lines.count) ? lines[i].output : ""
            return Line(id: i, source: s, output: old, hits: glossary.hits(in: s, direction: dir), missing: [], isDone: false)
        }

        generation += 1
        let gen = generation
        let previous = work
        previous?.cancel()
        let style = vm.glossary.styleGuide
        let engine = vm.engine
        isWorking = lines.contains { !$0.isDone }

        work = Task {
            await previous?.value              // không cho hai lượt sinh chồng nhau
            for i in lines.indices {
                guard gen == generation, !Task.isCancelled, i < lines.count else { return }
                if lines[i].isDone { continue }
                await AppActivity.shared.waitUntilActive()
                // waitUntilActive cũng trả về khi bị huỷ → không được bắt đầu sinh (GPU) lúc app ra nền
                guard gen == generation, !Task.isCancelled, i < lines.count else { return }
                let line = lines[i]
                do {
                    let stats = try await engine.translate(line.source, hits: line.hits, styleGuide: style,
                                                           direction: dir) { t in
                        Task { @MainActor in
                            if gen == self.generation, i < self.lines.count, !self.lines[i].isDone {
                                self.lines[i].output = t
                            }
                        }
                    }
                    guard gen == generation, i < lines.count, !Task.isCancelled else { return }
                    let missing = GlossaryQA.missing(hits: line.hits, source: line.source, output: stats.text)
                    lines[i].output = stats.text
                    lines[i].missing = missing
                    lines[i].isDone = true
                    cache[cacheKey(line.source)] = Cached(text: stats.text, missing: missing)
                    vm.tokensPerSecond = stats.tokensPerSecond
                } catch {
                    if gen == generation { isWorking = false }   // lỗi thật: không quay "đang dịch" mãi
                    return
                }
            }
            if gen == generation { isWorking = false }
        }
    }
}
