import AVFoundation
import Foundation
import Observation
import UIKit

/// Bộ nhận dạng giọng nói cho tab Chép lời.
enum ASREngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case apple, phoWhisper, whisperTurbo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple Speech"
        case .phoWhisper: "PhoWhisper-medium"
        case .whisperTurbo: "Whisper large-v3 turbo"
        }
    }
    var whisper: WhisperModelChoice? {
        switch self {
        case .apple: nil
        case .phoWhisper: .phoWhisperMedium
        case .whisperTurbo: .largeV3Turbo
        }
    }
    static func options(for language: TranscriptLanguage) -> [ASREngine] {
        language == .en ? [.apple, .whisperTurbo] : [.phoWhisper, .whisperTurbo, .apple]
    }
}

/// Chép lời tệp ghi âm / video: trích âm thanh → nhận dạng có mốc thời gian → (tuỳ chọn) dịch từng đoạn
/// → chép / xuất SRT, VTT / nghe lại theo timeline / lưu. Tất cả chạy trên máy.
@MainActor
@Observable
final class TranscribeController {
    enum Phase: Equatable { case idle, extracting, preparing, transcribing, done, failed }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var status = ""
    var errorText: String?
    private(set) var fileName = ""
    private(set) var duration: Double = 0
    private(set) var elapsed: Double = 0
    var segments: [TranscriptSegment] = []

    var language: TranscriptLanguage = .en {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "transcribeLanguage") }
    }
    var display: SubtitleContent = .source

    /// Bộ nhận dạng riêng cho từng ngôn ngữ: tiếng Anh mặc định Apple Speech, tiếng Việt mặc định PhoWhisper.
    var engineEN: ASREngine = ASREngine(rawValue: UserDefaults.standard.string(forKey: "asrEngineEN") ?? "") ?? .apple {
        didSet { UserDefaults.standard.set(engineEN.rawValue, forKey: "asrEngineEN") }
    }
    var engineVI: ASREngine = ASREngine(rawValue: UserDefaults.standard.string(forKey: "asrEngineVI") ?? "") ?? .phoWhisper {
        didSet { UserDefaults.standard.set(engineVI.rawValue, forKey: "asrEngineVI") }
    }
    var engine: ASREngine {
        get { language == .en ? engineEN : engineVI }
        set { if language == .en { engineEN = newValue } else { engineVI = newValue } }
    }
    /// Gợi ý thuật ngữ GPB cho Whisper (initial prompt) để viết đúng chính tả chuyên ngành.
    var useTermPrompt: Bool = UserDefaults.standard.bool(forKey: "asrTermPrompt") {
        didSet { UserDefaults.standard.set(useTermPrompt, forKey: "asrTermPrompt") }
    }
    private(set) var usedEngine: ASREngine = .apple
    /// Phần cứng chạy Whisper (Neural Engine / GPU)
    var whisperCompute: WhisperRunner.Compute = WhisperRunner.Compute(
        rawValue: UserDefaults.standard.string(forKey: "whisperCompute") ?? "") ?? .neuralEngine {
        didSet { UserDefaults.standard.set(whisperCompute.rawValue, forKey: "whisperCompute") }
    }
    /// Thời điểm bắt đầu nạp Whisper (để hiện thời gian đã chờ)
    private(set) var loadStartedAt: Date?
    private(set) var isPreloading = false
    private var preloadTask: Task<Void, Never>?
    /// Tăng mỗi lần bắt đầu chép lời; lượt cũ (bị huỷ nhưng còn kẹt trong lúc nạp mô hình) không được ghi đè trạng thái.
    private var runID = 0

    func isWhisperLoaded(_ m: WhisperModelChoice) -> Bool { WhisperRunner.shared.isLoaded(m, whisperCompute) }

    /// Nạp sẵn Whisper trước khi chọn tệp (lần đầu trên Neural Engine có thể lâu).
    func preloadWhisper() {
        guard let wm = engine.whisper, WhisperModelStore.isComplete(wm), !isPreloading, !isBusy else { return }
        let compute = whisperCompute
        isPreloading = true
        loadStartedAt = Date()
        errorText = nil
        UIApplication.shared.isIdleTimerDisabled = true
        preloadTask = Task {
            defer {
                isPreloading = false
                loadStartedAt = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                try await WhisperRunner.shared.load(wm, compute: compute)
            } catch is CancellationError {
            } catch {
                errorText = "Không nạp được \(wm.title): \(error.localizedDescription)"
            }
        }
    }

    /// Nạp Neural Engine quá lâu → huỷ, chuyển sang GPU và chạy lại.
    func switchToGPUAndRetry() {
        preloadTask?.cancel()
        isPreloading = false
        loadStartedAt = nil
        whisperCompute = .gpu
        if sourceURL != nil { rerun() }
    }
    /// Dịch ngay khi có đoạn mới (cần đã nạp mô hình).
    var autoTranslate: Bool = UserDefaults.standard.bool(forKey: "transcribeAutoTranslate") {
        didSet { UserDefaults.standard.set(autoTranslate, forKey: "transcribeAutoTranslate") }
    }

    // Dịch
    private(set) var isTranslating = false
    private(set) var translatingID: UUID?
    var translatedCount: Int { segments.filter { !$0.translation.isEmpty }.count }
    /// Số đoạn đã dịch chuẩn (mô hình + glossary), không tính bản nhanh
    var refinedCount: Int { segments.filter { !$0.translation.isEmpty && !$0.isFast }.count }
    private(set) var isFastTranslating = false

    // Nghe lại
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var audioURL: URL?
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    var isBusy: Bool { phase == .extracting || phase == .preparing || phase == .transcribing }
    var currentSegmentID: UUID? {
        guard player != nil, currentTime > 0 else { return nil }
        return segments.last { $0.start <= currentTime + 0.05 }?.id
    }
    /// Tên mô tả để hiện ở phần đầu: "171 đoạn · 84,9 s · English"
    var summary: String {
        "\(segments.count) đoạn · " + String(format: "%.1f s", elapsed) + " · \(language.shortLabel) · \(usedEngine.title)"
    }

    private let vm: TranslatorViewModel
    private var task: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var sourceURL: URL?
    private var savedID: UUID?

    init(vm: TranslatorViewModel) {
        self.vm = vm
        if let raw = UserDefaults.standard.string(forKey: "transcribeLanguage"),
           let l = TranscriptLanguage(rawValue: raw) { language = l }
    }

    // MARK: Nhập tệp

    /// Tệp từ ứng dụng Tệp (security-scoped) → chép vào thư mục tạm rồi chép lời.
    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let local = try Self.copyToTemp(url)
            start(local, name: url.lastPathComponent)
        } catch {
            errorText = "Không mở được tệp: \(error.localizedDescription)"
        }
    }

    nonisolated static func copyToTemp(_ url: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Transcribe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// Chép lời lại tệp hiện tại (vd. sau khi đổi ngôn ngữ).
    func rerun() {
        guard let src = sourceURL else { return }
        start(src, name: fileName)
    }

    func start(_ url: URL, name: String) {
        cancel()
        stopPlayback()
        player = nil
        sourceURL = url
        fileName = name
        segments = []
        savedID = nil
        errorText = nil
        progress = 0
        elapsed = 0
        duration = 0
        currentTime = 0
        phase = .extracting
        status = "Đang trích âm thanh…"
        let language = self.language
        let engine = self.engine
        usedEngine = engine
        let prompt = useTermPrompt ? termPrompt(for: language) : nil
        let began = Date()

        UIApplication.shared.isIdleTimerDisabled = true      // không khoá màn hình khi đang xử lý
        runID += 1
        let myRun = runID
        task = Task {
            defer {
                if myRun == runID {
                    loadStartedAt = nil
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
            do {
                if engine.whisper == nil, !(await EnglishTranscriber.requestAuthorization()) {
                    throw NSError(domain: "ViPath", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Chưa cấp quyền nhận dạng giọng nói (Cài đặt → ViPath)."])
                }
                let (caf, dur) = try await MediaAudioExtractor.extract(from: url) { p in
                    Task { @MainActor in self.progress = p * 0.1 }
                }
                try Task.checkCancellation()
                audioURL = caf
                duration = dur
                phase = .preparing
                status = "Đang chuẩn bị bộ nhận dạng…"
                if let wm = engine.whisper {
                    guard WhisperModelStore.isComplete(wm) else {
                        throw NSError(domain: "ViPath", code: 2, userInfo: [NSLocalizedDescriptionKey:
                            "Chưa tải mô hình \(wm.title). Bấm Tải ở phần Bộ nhận dạng (cần Wi-Fi, \(wm.sizeLabel))."])
                    }
                    let compute = whisperCompute
                    if !WhisperRunner.shared.isLoaded(wm, compute) {
                        status = compute == .neuralEngine
                            ? "Đang tối ưu \(wm.title) cho Neural Engine — chỉ lần đầu, có thể mất vài phút. Giữ app mở…"
                            : "Đang nạp \(wm.title) lên GPU…"
                        loadStartedAt = Date()
                        await preloadTask?.value            // đang nạp sẵn → chờ lượt đó thay vì nạp lần hai
                        try await WhisperRunner.shared.load(wm, compute: compute)
                        loadStartedAt = nil
                    }
                    try Task.checkCancellation()
                    phase = .transcribing
                    status = "Đang chép lời…"
                    try await WhisperRunner.shared.transcribe(
                        audioURL: caf, model: wm, language: language, promptText: prompt,
                        onProgress: { p in Task { @MainActor in self.progress = 0.1 + 0.9 * p } },
                        onSegments: { segs in Task { @MainActor in self.append(segs) } })
                } else {
                try await FileTranscriber.transcribe(
                    audioURL: caf, duration: dur, language: language,
                    onStatus: { s in Task { @MainActor in
                        self.status = s
                        if s.hasPrefix("Đang chép") { self.phase = .transcribing }
                    } },
                    onProgress: { p in Task { @MainActor in self.progress = 0.1 + 0.9 * p } },
                    onSegments: { segs in Task { @MainActor in self.append(segs) } })
                }
                try Task.checkCancellation()
                // các Task cập nhật giao diện ở trên có thể chưa chạy xong → nhường một nhịp
                await Task.yield()
                elapsed = Date().timeIntervalSince(began)
                phase = .done
                progress = 1
                status = "Chép lời hoàn tất"
                preparePlayer()
            } catch is CancellationError {
                guard myRun == runID else { return }
                phase = segments.isEmpty ? .idle : .done
                status = "Đã huỷ"
            } catch {
                guard myRun == runID else { return }
                errorText = error.localizedDescription
                phase = .failed
                status = "Lỗi"
            }
        }
    }

    /// Danh sách thuật ngữ ngắn từ glossary làm gợi ý chính tả cho Whisper.
    private func termPrompt(for language: TranscriptLanguage) -> String {
        let entries = vm.glossary.allEntries
        let terms: [String] = entries.compactMap { e in
            let raw = language == .vi ? e.vi : e.en
            let first = raw.components(separatedBy: " / ").first?
                .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) ?? ""
            return first.isEmpty || first.lowercased().hasPrefix("giữ nguyên") || first.count > 40 ? nil : first
        }
        var seen = Set<String>()
        let unique = terms.filter { seen.insert($0.lowercased()).inserted }
        let head = language == .vi ? "Giải phẫu bệnh: " : "Pathology: "
        return head + unique.prefix(60).joined(separator: ", ") + "."
    }

    private func append(_ segs: [TranscriptSegment]) {
        segments.append(contentsOf: segs)
        segments.sort { $0.start < $1.start }
        if FastTranslator.shared.isActive(language.direction) { fastTranslate(ids: segs.map(\.id)) }
        if autoTranslate, vm.loadedModel != nil, !isTranslating { translateAll() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopTranslating()
        if isBusy {
            // lượt đang kẹt trong lúc nạp mô hình không dừng ngay được → cập nhật giao diện luôn
            runID += 1
            phase = segments.isEmpty ? .idle : .done
            status = "Đã huỷ"
            loadStartedAt = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func clear() {
        cancel()
        stopPlayback()
        player = nil
        audioURL = nil
        sourceURL = nil
        segments = []
        fileName = ""
        phase = .idle
        status = ""
        errorText = nil
        progress = 0
        savedID = nil
    }

    // MARK: Dịch nhanh (Apple Translation)

    /// Dịch nhanh các đoạn chưa có bản dịch (mặc định: tất cả).
    func fastTranslateAll() {
        fastTranslate(ids: segments.filter { $0.translation.isEmpty }.map(\.id))
    }

    private func fastTranslate(ids: [UUID]) {
        let dir = language.direction
        let items = ids.compactMap { id in segments.first { $0.id == id && $0.translation.isEmpty } }
        guard !items.isEmpty else { return }
        isFastTranslating = true
        Task {
            defer { isFastTranslating = false }
            // lô 40 đoạn để kết quả hiện dần với tệp dài
            for start in stride(from: 0, to: items.count, by: 40) {
                let batch = Array(items[start..<min(start + 40, items.count)])
                do {
                    let out = try await FastTranslator.shared.translate(batch: batch.map(\.text), dir)
                    for (seg, t) in zip(batch, out) where !t.isEmpty {
                        // không ghi đè bản chuẩn đã có
                        if let j = segments.firstIndex(where: { $0.id == seg.id }), segments[j].translation.isEmpty {
                            segments[j].translation = t
                            segments[j].isFast = true
                        }
                    }
                } catch {
                    errorText = "Dịch nhanh lỗi: \(error.localizedDescription)"
                    return
                }
            }
        }
    }

    // MARK: Dịch

    func translateAll() {
        guard vm.loadedModel != nil else {
            errorText = "Hãy nạp mô hình dịch ở tab Dịch trước."
            return
        }
        guard translateTask == nil else { return }
        isTranslating = true
        translateTask = Task {
            var attempted = Set<UUID>()
            while !Task.isCancelled {
                guard let seg = segments.first(where: {
                    ($0.translation.isEmpty || $0.isFast) && !attempted.contains($0.id)
                }) else {
                    // đang chép lời → chờ đoạn mới
                    if isBusy {
                        try? await Task.sleep(for: .milliseconds(300))
                        continue
                    }
                    break
                }
                attempted.insert(seg.id)
                if !(await translate(seg)) { break }
            }
            isTranslating = false
            translatingID = nil
            translateTask = nil
        }
    }

    func stopTranslating() {
        translateTask?.cancel()
        translateTask = nil
        isTranslating = false
        translatingID = nil
    }

    /// Dịch lại một đoạn (sau khi sửa văn bản).
    func retranslate(_ id: UUID) {
        guard vm.loadedModel != nil, translateTask == nil,
              let seg = segments.first(where: { $0.id == id }) else { return }
        isTranslating = true
        translateTask = Task {
            _ = await translate(seg)
            isTranslating = false
            translatingID = nil
            translateTask = nil
        }
    }

    /// Trả về false nếu cần dừng cả lượt (lỗi hoặc bị huỷ).
    private func translate(_ seg: TranscriptSegment) async -> Bool {
        await AppActivity.shared.waitUntilActive()
        guard !Task.isCancelled else { return false }
        translatingID = seg.id
        let dir = language.direction
        let hits = vm.glossary.hits(in: seg.text, direction: dir)
        let id = seg.id
        // đoạn đang có bản nhanh: giữ bản nhanh đến khi bản chuẩn xong (không hiện chữ dở dang)
        let stream = seg.translation.isEmpty
        do {
            let stats = try await vm.engine.translate(seg.text, hits: hits, styleGuide: vm.glossary.styleGuide,
                                                      direction: dir) { t in
                Task { @MainActor in
                    if stream, self.translatingID == id, let j = self.segments.firstIndex(where: { $0.id == id }) {
                        self.segments[j].translation = t
                    }
                }
            }
            guard !Task.isCancelled else { return false }
            if let j = segments.firstIndex(where: { $0.id == id }), !stats.text.isEmpty {
                segments[j].translation = stats.text
                segments[j].isFast = false
            }
            vm.tokensPerSecond = stats.tokensPerSecond
            return true
        } catch {
            if !Task.isCancelled { errorText = "Lỗi dịch: \(error.localizedDescription)" }
            return false
        }
    }

    func update(_ id: UUID, text: String, translation: String) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        if segments[i].translation != translation { segments[i].isFast = false }   // bác sĩ đã sửa tay
        segments[i].text = text
        segments[i].translation = translation
    }

    func delete(_ id: UUID) {
        segments.removeAll { $0.id == id }
    }

    // MARK: Nghe lại theo timeline

    private func preparePlayer() {
        guard let audioURL, player == nil else { return }
        player = try? AVAudioPlayer(contentsOf: audioURL)
        player?.prepareToPlay()
    }

    func play(from time: Double? = nil) {
        preparePlayer()
        guard let player else { return }
        Task {
            await VieNeuPlayer.preparePlaybackSession()
            if let time { player.currentTime = max(0, time) }
            player.play()
            isPlaying = true
            currentTime = player.currentTime
            startTicker()
        }
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    func seek(to time: Double) {
        preparePlayer()
        player?.currentTime = max(0, min(time, duration))
        currentTime = player?.currentTime ?? time
    }

    func stopPlayback() {
        player?.stop()
        isPlaying = false
        ticker?.cancel()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled, let p = player {
                currentTime = p.currentTime
                if !p.isPlaying {
                    isPlaying = false
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: Chép / xuất / lưu

    func copy(_ content: SubtitleContent, timestamps: Bool) {
        UIPasteboard.general.string = timestamps
            ? SubtitleWriter.render(segments, format: .txt, content: content)
            : SubtitleWriter.plain(segments, content: content)
    }

    func file(_ format: SubtitleFormat, _ content: SubtitleContent) -> SubtitleFile {
        let base = (fileName as NSString).deletingPathExtension
        let suffix: String = switch content {
        case .source: language.rawValue
        case .translation: language.direction.targetCode
        case .bilingual: "\(language.rawValue)-\(language.direction.targetCode)"
        }
        return SubtitleFile(fileName: "\(base.isEmpty ? "phude" : base).\(suffix).\(format.rawValue)",
                            content: SubtitleWriter.render(segments, format: format, content: content))
    }

    @discardableResult
    func save() -> Bool {
        guard !segments.isEmpty else { return false }
        let id = savedID ?? UUID()
        let existing = SavedStore.shared.items.first { $0.id == id }
        let pairs = segments.map {
            SavedItem.Pair(source: $0.text, translation: $0.translation, offset: $0.start, end: $0.end)
        }
        let item = SavedItem(id: id, kind: .transcript, createdAt: existing?.createdAt ?? Date(),
                             title: existing?.title ?? "Chép lời — \(fileName)",
                             direction: language.direction,
                             engine: usedEngine.title + (translatedCount > 0 ? " · \(vm.loadedModel?.shortName ?? "")" : ""),
                             source: segments.map(\.text).joined(separator: "\n"),
                             translation: segments.map(\.translation).joined(separator: "\n"),
                             pairs: pairs, duration: duration)
        guard SavedStore.shared.save(item) else { return false }
        savedID = id
        return true
    }
}
