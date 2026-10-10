import Foundation
import Observation
import UIKit

/// Một đoạn trong phiên dịch: nguồn, thuật ngữ khớp, bản dịch, cảnh báo glossary.
struct TranslatedSegment: Identifiable {
    let id: Int
    let source: String
    let passthrough: Bool
    var hits: [GlossaryHit] = []
    var output: String = ""
    var missing: [GlossaryHit] = []
    var isDone = false
}

/// Chế độ chọn chiều dịch trong tab Dịch.
enum DirectionMode: String, CaseIterable, Identifiable, Sendable {
    case auto, enToVi, viToEn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Tự động"
        case .enToVi: "Anh → Việt"
        case .viToEn: "Việt → Anh"
        }
    }
}

/// Đoán ngôn ngữ nguồn: tỉ lệ chữ cái mang dấu tiếng Việt (ă â đ ê ô ơ ư + thanh điệu).
/// Văn bản GPB tiếng Việt chứa nhiều thuật ngữ / dấu ấn tiếng Anh nhưng vẫn có ≥ 3% chữ có dấu.
enum LanguageGuess {
    private static let vietnamese = Set(
        "ăâđêôơưàáảãạằắẳẵặầấẩẫậèéẻẽẹềếểễệìíỉĩịòóỏõọồốổỗộờớởỡợùúủũụừứửữựỳýỷỹỵ"
        + "ĂÂĐÊÔƠƯÀÁẢÃẠẰẮẲẴẶẦẤẨẪẬÈÉẺẼẸỀẾỂỄỆÌÍỈĨỊÒÓỎÕỌỒỐỔỖỘỜỚỞỠỢÙÚỦŨỤỪỨỬỮỰỲÝỶỸỴ")

    static func direction(for text: String) -> TranslationDirection? {
        var letters = 0, vi = 0
        for ch in text.precomposedStringWithCanonicalMapping.prefix(4000) where ch.isLetter {
            letters += 1
            if vietnamese.contains(ch) { vi += 1 }
        }
        guard letters >= 3 else { return nil }
        return Double(vi) / Double(letters) >= 0.03 ? .viToEn : .enToVi
    }
}

/// Gói dữ liệu chờ xác nhận trước khi gửi Claude: văn bản gốc + bản đã che định danh.
struct ClaudeRequest: Identifiable {
    let id = UUID()
    let direction: TranslationDirection
    let source: String
    let draft: String?
    let hits: [GlossaryHit]
    private(set) var extraTerms: [String] = []
    private(set) var redaction: PHIRedactor.Result
    private(set) var redactedSource: String
    private(set) var redactedDraft: String?

    private static let separator = "\n\n<<<DRAFT>>>\n\n"

    init(source: String, draft: String?, direction: TranslationDirection, hits: [GlossaryHit]) {
        self.source = source
        self.draft = draft
        self.direction = direction
        self.hits = hits
        redaction = PHIRedactor.redact(source)
        redactedSource = redaction.text
        redactedDraft = nil
        redo()
    }

    /// Che cùng lúc nguồn và bản nháp để cùng một giá trị nhận cùng nhãn ở cả hai.
    mutating func redo() {
        let combined = draft.map { source + Self.separator + $0 } ?? source
        redaction = PHIRedactor.redact(combined, extraTerms: extraTerms)
        let parts = redaction.text.components(separatedBy: Self.separator)
        redactedSource = parts[0]
        redactedDraft = parts.count > 1 ? parts.dropFirst().joined(separator: Self.separator) : nil
    }

    mutating func setExtraTerms(_ terms: [String]) {
        extraTerms = terms
        redo()
    }
}

@MainActor
@Observable
final class TranslatorViewModel {
    // Đầu vào / đầu ra
    var input = ""
    var segments: [TranslatedSegment] = []
    var outputText: String {
        segments.map { $0.passthrough ? $0.source : $0.output }.joined(separator: "\n")
    }

    // Mô hình
    var selectedModel: ModelChoice = .qwen35_4b
    var loadedModel: ModelChoice?
    var isLoading = false
    var loadProgress: Double = 0
    enum LoadStage { case download, weights, warmup }
    var loadStage: LoadStage = .download
    @ObservationIgnored private var weightsStart: Date?
    /// "Đang tải 45%" / "Đang nạp…" / "Đang làm nóng…"
    var loadStageText: String {
        switch loadStage {
        case .download: loadProgress > 0 && loadProgress < 1 ? "Đang tải \(Int(loadProgress * 100))%" : "Đang nạp…"
        case .weights: "Đang nạp…"
        case .warmup: "Đang làm nóng…"
        }
    }

    // Trạng thái dịch
    var isTranslating = false
    var currentSegment: Int?
    var tokensPerSecond: Double = 0
    var errorText: String?
    /// Cảnh báo RAM sát giới hạn sau khi nạp (vẫn dùng được).
    var memoryWarning: String?

    // Chiều dịch
    var directionMode: DirectionMode = .auto {
        didSet { UserDefaults.standard.set(directionMode.rawValue, forKey: "directionMode") }
    }
    /// Chiều dịch áp dụng cho nội dung đang nhập.
    var direction: TranslationDirection {
        switch directionMode {
        case .enToVi: .enToVi
        case .viToEn: .viToEn
        case .auto: LanguageGuess.direction(for: input) ?? .enToVi
        }
    }
    /// Chiều dịch của kết quả đang hiển thị.
    private(set) var outputDirection: TranslationDirection = .enToVi
    /// Thời gian đọc prompt (prefill) và tổng thời gian lượt dịch gần nhất.
    private(set) var promptSeconds: Double = 0
    private(set) var lastRunSeconds: Double = 0

    // Claude
    var claudeRequest: ClaudeRequest?
    private(set) var claudeOutput = ""
    private(set) var claudeInfo = ""
    private(set) var claudeError: String?
    private(set) var claudeNewTerms = 0
    /// Nhãn che định danh Claude làm mất (cần kiểm tra lại bản dịch).
    private(set) var claudeLostPlaceholders: [String] = []
    private var claudeTask: Task<Void, Never>?
    private var claudeOutputDirection: TranslationDirection = .enToVi

    let glossary = GlossaryStore()
    /// Dùng chung cho chế độ dịch khi gõ và phụ đề trực tiếp.
    let engine = TranslationEngine()
    private var task: Task<Void, Never>?
    /// Tăng mỗi lần bắt đầu / dừng một lượt dịch; task cũ thấy lệch token thì không ghi vào `segments`
    /// (tránh index out of range khi `segments` bị thay hoặc xoá trong lúc task cũ còn chạy).
    private var runToken = 0

    /// Thuật ngữ nhận diện được ngay khi gõ / dán (chưa cần nạp mô hình).
    var liveHits: [GlossaryHit] { glossary.hits(in: input, direction: direction) }

    var allHits: [GlossaryHit] {
        var seen = Set<String>()
        return segments.flatMap(\.hits).filter { seen.insert($0.id).inserted }
    }
    var allMissing: [GlossaryHit] {
        var seen = Set<String>()
        return segments.flatMap(\.missing).filter { seen.insert($0.id).inserted }
    }

    init() {
        glossary.load()
        if let raw = UserDefaults.standard.string(forKey: "model"),
           let m = ModelChoice(rawValue: raw), m.deviceFit != .tooBig { selectedModel = m }
        if let raw = UserDefaults.standard.string(forKey: "directionMode"),
           let d = DirectionMode(rawValue: raw) { directionMode = d }
    }

    /// Đảo chiều: bản dịch hiện có thành văn bản nguồn mới.
    func swapDirection() {
        let newDirection = direction.reversed
        let out = claudeOutput.isEmpty ? outputText : claudeOutput
        if !isTranslating, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stop()
            input = out
            segments = []
            resetClaude()
        }
        directionMode = newDirection == .enToVi ? .enToVi : .viToEn
    }

    func loadModel() async {
        isLoading = true
        errorText = nil
        memoryWarning = nil
        loadProgress = 0
        loadedModel = nil   // engine bỏ container cũ ngay khi bắt đầu nạp
        UserDefaults.standard.set(selectedModel.rawValue, forKey: "model")
        loadStage = .download
        let model = selectedModel
        let started = Date()
        weightsStart = nil           // bỏ phần thời gian tải về (chỉ đo thời gian nạp)
        do {
            memoryWarning = try await engine.load(model) { p in
                Task { @MainActor in
                    self.loadProgress = p
                    if p >= 1, self.weightsStart == nil { self.weightsStart = Date(); self.loadStage = .weights }
                }
            }
            let loadSeconds = Date().timeIntervalSince(weightsStart ?? started)
            loadStage = .warmup
            let warm = await engine.warmUp()
            loadedModel = model
            LoadTimings.shared.record(LoadTimings.key(model), load: loadSeconds, warm: warm)
        } catch {
            loadedModel = nil
            errorText = "Không nạp được mô hình: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Trả bộ đệm GPU của mô hình dịch (gọi khi iOS báo sắp hết bộ nhớ).
    func releaseGPUCache() async {
        await engine.releaseCache()
    }

    func pasteFromClipboard() {
        if let s = UIPasteboard.general.string { input = s }
    }

    func copyOutput() {
        UIPasteboard.general.string = outputText
    }

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, loadedModel != nil, !isTranslating else { return }
        errorText = nil
        resetClaude()
        let dir = direction
        outputDirection = dir
        let style = glossary.styleGuide
        // Mô hình lớn: đoạn ngắn hơn → prompt + KV cache nhỏ hơn, ít nguy cơ bị iOS đóng app.
        let maxChars = (loadedModel?.isLarge ?? false) ? 600 : 900
        segments = Segmenter.split(text, maxChars: maxChars).map {
            TranslatedSegment(id: $0.id, source: $0.text, passthrough: $0.passthrough,
                              hits: $0.passthrough ? [] : glossary.hits(in: $0.text, direction: dir))
        }
        promptSeconds = 0
        let started = Date()
        isTranslating = true
        runToken += 1
        let token = runToken
        let count = segments.count
        let previous = task   // chờ lượt cũ (đã huỷ) thoát khỏi engine trước khi sinh tiếp

        task = Task {
            await previous?.value
            for i in 0..<count {
                guard !Task.isCancelled, token == runToken, i < segments.count else { break }
                if segments[i].passthrough { continue }
                currentSegment = i
                await run(index: i, style: style, token: token)
            }
            guard token == runToken else { return }
            lastRunSeconds = Date().timeIntervalSince(started)
            currentSegment = nil
            isTranslating = false
        }
    }

    /// Dịch lại một đoạn (vd. khi có cảnh báo thiếu thuật ngữ).
    func retranslate(_ id: Int) {
        guard !isTranslating, loadedModel != nil,
              let i = segments.firstIndex(where: { $0.id == id }) else { return }
        isTranslating = true
        runToken += 1
        let token = runToken
        let style = glossary.styleGuide
        segments[i].hits = glossary.hits(in: segments[i].source, direction: outputDirection)
        let previous = task
        task = Task {
            await previous?.value
            currentSegment = i
            await run(index: i, style: style, token: token)
            guard token == runToken else { return }
            currentSegment = nil
            isTranslating = false
        }
    }

    private func run(index i: Int, style: String, token: Int) async {
        guard token == runToken, i < segments.count else { return }
        let seg = segments[i]
        segments[i].output = ""
        segments[i].isDone = false
        do {
            let stats = try await engine.translate(seg.source, hits: seg.hits, styleGuide: style,
                                                   direction: outputDirection) { text in
                Task { @MainActor in
                    // bỏ qua cập nhật trễ sau khi đoạn đã hoàn tất / lượt dịch đã bị dừng hoặc thay
                    if token == self.runToken, i < self.segments.count, !self.segments[i].isDone {
                        self.segments[i].output = text
                    }
                }
            }
            // segments có thể đã bị thay / xoá trong lúc await
            guard token == runToken, i < segments.count else { return }
            segments[i].isDone = true
            segments[i].output = stats.text
            tokensPerSecond = stats.tokensPerSecond
            promptSeconds += stats.promptSeconds
            segments[i].missing = GlossaryQA.missing(hits: seg.hits, source: seg.source,
                                                     output: segments[i].output)
        } catch {
            guard token == runToken else { return }   // lỗi do bị dừng → bỏ qua
            errorText = "Lỗi khi dịch đoạn \(i + 1): \(error.localizedDescription)"
        }
    }

    func stop() {
        task?.cancel()
        runToken += 1
        isTranslating = false
        currentSegment = nil
    }

    func clear() {
        stop()
        input = ""
        segments = []
        resetClaude()
    }

    // MARK: Claude

    /// Bước 1: che định danh và mở màn hình xác nhận (chưa gửi gì).
    func prepareClaude() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Có bản dịch offline của đúng văn bản này → Claude hiệu đính; nếu không → Claude dịch trực tiếp.
        let hasDraft = !segments.isEmpty && !isTranslating && segments.allSatisfy { $0.passthrough || $0.isDone }
        let dir = hasDraft ? outputDirection : direction
        let draft = hasDraft ? outputText : nil
        claudeRequest = ClaudeRequest(source: text, draft: draft, direction: dir,
                                      hits: glossary.hits(in: text, direction: dir))
    }

    /// Bước 2: chỉ gọi sau khi bác sĩ đã xác nhận bản che.
    func sendClaude(_ req: ClaudeRequest) {
        claudeRequest = nil
        claudeTask?.cancel()
        claudeOutput = ""
        claudeError = nil
        claudeInfo = ""
        claudeNewTerms = 0
        claudeLostPlaceholders = []
        claudeOutputDirection = req.direction
        claudeTask = Task {
            do {
                let r = try await ClaudeService.shared.translate(source: req.redactedSource, draft: req.redactedDraft,
                                                                  direction: req.direction, hits: req.hits)
                guard !Task.isCancelled else { return }
                claudeLostPlaceholders = req.redaction.replacements.map(\.placeholder)
                    .filter { req.redactedSource.contains($0) && !r.text.contains($0) }
                claudeOutput = PHIRedactor.restore(r.text, using: req.redaction.replacements)
                claudeInfo = String(format: "%@ · %.1f s · %d→%d token", r.model.shortName, r.seconds,
                                    r.inputTokens, r.outputTokens)
                claudeNewTerms = TermSuggestionStore.shared.ingest(r.suggestions, glossary: glossary, model: r.model)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { claudeError = error.localizedDescription }
            }
        }
    }

    func cancelClaude() {
        claudeTask?.cancel()
        claudeTask = nil
    }

    private func resetClaude() {
        cancelClaude()
        claudeOutput = ""
        claudeInfo = ""
        claudeError = nil
        claudeNewTerms = 0
        claudeLostPlaceholders = []
    }

    var claudeDirection: TranslationDirection { claudeOutputDirection }

    // MARK: Lưu

    var canSave: Bool {
        !isTranslating && (!outputText.isEmpty || !claudeOutput.isEmpty)
    }

    @discardableResult
    func saveCurrent() -> Bool {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !source.isEmpty else { return false }
        let dir = segments.isEmpty ? claudeOutputDirection : outputDirection
        let item = SavedItem(kind: .text, title: SavedItem.autoTitle(source), direction: dir,
                             engine: loadedModel?.shortName ?? "—", source: source, translation: outputText,
                             claudeTranslation: claudeOutput.isEmpty ? nil : claudeOutput,
                             claudeModel: claudeOutput.isEmpty ? nil : ClaudeService.shared.model.shortName)
        return SavedStore.shared.save(item)
    }
}
