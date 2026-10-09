import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

// MARK: - Bộ nhận dạng đọc chính tả (Anh / Việt) trên máy

/// SpeechAnalyzer cho đọc chính tả: SpeechTranscriber nếu hệ thống hỗ trợ ngôn ngữ, nếu không dùng
/// DictationTranscriber (có tự thêm dấu câu). Kèm từ vựng đại thể làm "contextual strings" để nhận đúng thuật ngữ.
nonisolated final class LiveDictationRecognizer: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private let lock = NSLock()
    private var _continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation? {
        get { lock.withLock { _continuation } }
        set { lock.withLock { _continuation = newValue } }
    }
    private var resultsTask: Task<Void, Never>?
    private var analyzerStarted = false
    private(set) var analyzerFormat: AVAudioFormat?
    private(set) var engineLabel = ""
    /// Câu máy vừa nghe được (để biết lệnh giọng nói có được nhận đúng không)
    private(set) var lastHeard = ""

    enum RecognizerError: LocalizedError {
        case unsupported(String), noFormat
        var errorDescription: String? {
            switch self {
            case .unsupported(let l): "iPhone chưa hỗ trợ nhận dạng \(l) trên máy."
            case .noFormat: "Không xác định được định dạng âm thanh cho bộ nhận dạng."
            }
        }
    }

    private static func pick(_ list: [Locale], _ language: TranscriptLanguage) -> Locale? {
        let match = list.filter { $0.language.languageCode?.identifier == language.languageCode }
        let preferred = language == .en ? "en-US" : "vi-VN"
        return match.first { $0.identifier(.bcp47) == preferred } ?? match.first
    }

    private static func install(_ module: any SpeechModule, _ locale: Locale, installed: [Locale],
                                status: @Sendable (String) -> Void) async throws {
        guard !Set(installed.map { $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else { return }
        status("Đang tải mô hình nhận dạng \(locale.identifier(.bcp47)) (một lần)…")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// `onResult(text, isFinal)` được gọi trên luồng nền.
    func start(language: TranscriptLanguage, vocabulary: [String],
               status: @Sendable @escaping (String) -> Void,
               onResult: @Sendable @escaping (String, Bool) -> Void) async throws {
        let module: any SpeechModule
        if let locale = Self.pick(await SpeechTranscriber.supportedLocales, language) {
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: [.volatileResults], attributeOptions: [])
            try await Self.install(t, locale, installed: await SpeechTranscriber.installedLocales, status: status)
            module = t
            engineLabel = "Apple Speech \(locale.identifier(.bcp47))"
            resultsTask = Task.detached {
                do {
                    for try await r in t.results { onResult(String(r.text.characters), r.isFinal) }
                } catch {
                    if !Task.isCancelled { status("Nhận dạng dừng: \(error.localizedDescription)") }
                }
            }
        } else if let locale = Self.pick(await DictationTranscriber.supportedLocales, language) {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults], attributeOptions: [])
            try await Self.install(t, locale, installed: await DictationTranscriber.installedLocales, status: status)
            module = t
            engineLabel = "Apple Dictation \(locale.identifier(.bcp47))"
            resultsTask = Task.detached {
                do {
                    for try await r in t.results { onResult(String(r.text.characters), r.isFinal) }
                } catch {
                    if !Task.isCancelled { status("Nhận dạng dừng: \(error.localizedDescription)") }
                }
            }
        } else {
            throw RecognizerError.unsupported(language.label.lowercased())
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            resultsTask?.cancel()
            throw RecognizerError.noFormat
        }
        analyzerFormat = format
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer

        // Từ vựng đại thể giúp bộ nhận dạng viết đúng thuật ngữ; không hỗ trợ thì bỏ qua.
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try await analyzer.start(inputSequence: stream)
        analyzerStarted = true
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async {
        let c = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in
            defer { _continuation = nil }
            return _continuation
        }
        c?.finish()
        if analyzerStarted, let analyzer, let results = resultsTask,
           (try? await analyzer.finalizeAndFinishThroughEndOfInput()) != nil {
            let timeout = Task.detached {
                try? await Task.sleep(for: .seconds(2))
                results.cancel()
            }
            await results.value
            timeout.cancel()
        } else {
            resultsTask?.cancel()
        }
        resultsTask = nil
        analyzerStarted = false
        analyzer = nil
    }
}

// MARK: - Micro cho phòng cắt lọc

/// Micro iPhone hoặc tai nghe Bluetooth (AirPods…) — tiện khi đeo găng, đứng cách máy.
/// Đồng thời ghi âm thanh 16 kHz mono ra tệp để có thể chép lại bằng PhoWhisper.
nonisolated final class DictationMicrophone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var recording = true

    /// Tạm dừng ghi vào tệp (lúc trao đổi với KTV) — bản chép lại bằng Whisper sẽ không có đoạn này.
    func setRecording(_ on: Bool) { lock.withLock { recording = on } }

    static let recordFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false)!

    func start(format: AVAudioFormat, recordTo url: URL?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)

        if let url {
            let f = try AVAudioFile(forWriting: url, settings: Self.recordFormat.settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            lock.withLock { file = f }
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let toRecognizer = BufferConverter(target: format)
        let toFile = BufferConverter(target: Self.recordFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable [weak self] buffer, _ in
            if let out = toRecognizer.convert(buffer) { onBuffer(out) }
            guard let self else { return }
            self.lock.withLock {
                if self.recording, let f = self.file, let rec = toFile.convert(buffer) { try? f.write(from: rec) }
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { file = nil }        // đóng tệp
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Gom các đoạn Whisper trả về từ luồng nền.
nonisolated final class GrossSegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: [String]) { lock.withLock { items += s } }
    var all: [String] { lock.withLock { items } }
}

// MARK: - Điều khiển tab Đại thể

@MainActor
@Observable
final class GrossDictationController {
    var doc = GrossDoc()
    var volatileText = ""
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var isRewriting = false
    var status = ""
    var errorText: String?
    /// Pathcode của ca đang đọc (gõ, quét mã vạch, hoặc nói "mã ca …") — chỉ lưu trên máy.
    var pathcode: String {
        get { doc.pathcode }
        set { doc.setPathcode(newValue.trimmingCharacters(in: .whitespaces).uppercased()) }
    }
    /// Đọc "cát xét A1 …" khi đang mô tả → ghi chú vào A1 rồi tự quay lại mô tả.
    var cassetteReturn: Bool = UserDefaults.standard.object(forKey: "grossCassetteReturn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cassetteReturn, forKey: "grossCassetteReturn") }
    }
    /// Chèn "(A1)" vào phần mô tả tại chỗ gọi cát xét.
    var inlineMarker: Bool = UserDefaults.standard.object(forKey: "grossInlineMarker") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inlineMarker, forKey: "grossInlineMarker") }
    }
    private(set) var engineLabel = ""
    /// Câu máy vừa nghe được (để biết lệnh giọng nói có được nhận đúng không)
    private(set) var lastHeard = ""
    private(set) var audioURL: URL?
    private(set) var savedID: UUID?

    var language: TranscriptLanguage = TranscriptLanguage(
        rawValue: UserDefaults.standard.string(forKey: "grossLanguage") ?? "") ?? .vi {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "grossLanguage") }
    }
    var templateID: String = UserDefaults.standard.string(forKey: "grossTemplate") ?? "biopsy" {
        didSet { UserDefaults.standard.set(templateID, forKey: "grossTemplate") }
    }
    /// Giữ bản ghi âm của phiên để chép lại bằng PhoWhisper (xoá khi Xoá trang).
    var keepAudio: Bool = UserDefaults.standard.object(forKey: "grossKeepAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAudio, forKey: "grossKeepAudio") }
    }
    var corrections: [GrossCorrection] = GrossDictationController.loadCorrections() {
        didSet { Self.storeCorrections(corrections) }
    }

    private var recognizer: LiveDictationRecognizer?
    private var mic: DictationMicrophone?
    private var starting = false
    private var stopping = false

    init() {
        // bản ghi của các lần mở app trước (không còn trang tương ứng) → xoá
        try? FileManager.default.removeItem(at: Self.audioDir)
    }

    var template: GrossTemplate? { GrossTemplate.all.first { $0.id == templateID } }
    var reportText: String { GrossParser.reportText(doc, english: language == .en) }
    var targetLabel: String {
        guard doc.target >= 0, doc.target < doc.cassettes.count else { return "Mô tả" }
        return "Cát xét \(doc.cassettes[doc.target].label)" + (doc.oneShot ? " → xong quay lại mô tả" : "")
    }

    // MARK: Ghi

    func start() async {
        guard !isRunning, !starting, !isRewriting else { return }
        starting = true
        defer { starting = false }
        errorText = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            errorText = "Chưa cấp quyền micro (Cài đặt → ViPath → Micro)."
            return
        }
        guard await EnglishTranscriber.requestAuthorization() else {
            errorText = "Chưa cấp quyền nhận dạng giọng nói (Cài đặt → ViPath)."
            return
        }
        isRunning = true
        isPaused = false
        stopping = false
        volatileText = ""
        status = "Đang chuẩn bị…"
        UIApplication.shared.isIdleTimerDisabled = true      // không khoá màn hình khi đang cắt lọc

        let rec = LiveDictationRecognizer()
        recognizer = rec
        let vocab = GrossParser.vocabulary + corrections.map(\.to)
        do {
            try await rec.start(
                language: language, vocabulary: Array(Set(vocab)),
                status: { s in Task { @MainActor in self.status = s } },
                onResult: { text, isFinal in Task { @MainActor in self.handle(text, isFinal: isFinal) } })
            engineLabel = rec.engineLabel
            guard !stopping else { await teardown(); status = "Đã dừng"; return }
            guard let format = rec.analyzerFormat else { throw LiveDictationRecognizer.RecognizerError.noFormat }
            let url = keepAudio ? newAudioURL() : nil
            let m = DictationMicrophone()
            try m.start(format: format, recordTo: url) { buffer in rec.feed(buffer) }
            mic = m
            if let url { appendAudio(url) }
            status = "Đang nghe · \(targetLabel)"
        } catch {
            errorText = error.localizedDescription
            await teardown()
            status = ""
        }
    }

    func stop() async {
        guard isRunning else { return }
        stopping = true
        if starting { status = "Đang dừng…"; return }
        mic?.stop()
        mic = nil
        await recognizer?.finish()       // nhận nốt câu cuối
        await teardown()
        status = "Đã dừng"
    }

    private func teardown() async {
        mic?.stop()
        mic = nil
        await recognizer?.finish()
        recognizer = nil
        isRunning = false
        isPaused = false
        volatileText = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
        mic?.setRecording(!isPaused)
        volatileText = ""
        status = isPaused ? "Tạm dừng — nói \"tiếp tục ghi\" hoặc bấm ▶︎" : "Đang nghe · \(targetLabel)"
    }

    private func handle(_ text: String, isFinal: Bool) {
        guard isRunning else { return }
        guard isFinal else {
            if !isPaused { volatileText = text }
            return
        }
        volatileText = ""
        lastHeard = text
        let signals = GrossParser.apply(GrossParser.parse(text), to: &doc, paused: isPaused, corrections: corrections,
                                        cassetteReturn: cassetteReturn, inlineMarker: inlineMarker)
        for s in signals {
            switch s {
            case .pause: isPaused = true; mic?.setRecording(false)
            case .resume: isPaused = false; mic?.setRecording(true)
            case .stop: Task { await stop() }
            }
        }
        if isRunning {
            status = isPaused ? "Tạm dừng — nói \"tiếp tục ghi\" hoặc bấm ▶︎" : "Đang nghe · \(targetLabel)"
        }
    }

    // MARK: Chỉnh tay

    func undo() {
        GrossParser.apply([.undo], to: &doc)
    }

    func addCassette() {
        GrossParser.addCassette(to: &doc, inlineMarker: inlineMarker)     // lời đọc vẫn vào phần mô tả
        if isRunning { status = "Đang nghe · \(targetLabel)" }
    }

    func select(target: Int) {
        doc.target = target
        doc.oneShot = false          // chọn tay → ghi tiếp vào đó cho đến khi đổi
        if isRunning { status = "Đang nghe · \(targetLabel)" }
    }

    func deleteCassette(at index: Int) {
        guard doc.cassettes.indices.contains(index) else { return }
        doc.history.append(doc.snapshot)
        doc.cassettes.remove(at: index)
        if doc.target >= doc.cassettes.count || doc.target == index { doc.target = -1; doc.oneShot = false }
        else if doc.target > index { doc.target -= 1 }
    }

    func clear() {
        guard !isRunning, !isRewriting else { return }
        doc = GrossDoc(pathcode: doc.pathcode)     // giữ pathcode của ca
        savedID = nil
        removeAudio()
        status = ""
    }

    /// Ca mới: lưu ca đang đọc (nếu có nội dung) rồi mở trang trống, chờ pathcode mới.
    @discardableResult
    func newCase() -> Bool {
        guard !isRunning, !isRewriting else { return false }
        let saved = doc.isEmpty ? false : save()
        doc = GrossDoc()
        savedID = nil
        removeAudio()
        status = saved ? "Đã lưu ca trước · nhập pathcode ca mới" : ""
        return saved
    }

    // MARK: Lưu

    @discardableResult
    func save() -> Bool {
        let text = reportText
        guard !text.isEmpty else { return false }
        let title = doc.pathcode.isEmpty
            ? "Đại thể · " + SavedItem.autoTitle(doc.body.isEmpty ? text : doc.body)
            : "Đại thể · " + doc.pathcode
        var item = SavedItem(kind: .gross, title: title, direction: language == .vi ? .viToEn : .enToVi,
                             engine: engineLabel.isEmpty ? "Đọc chính tả" : engineLabel,
                             source: text, translation: "")
        if let savedID { item.id = savedID }
        guard SavedStore.shared.save(item) else { return false }
        savedID = item.id
        return true
    }

    // MARK: Chép lại bằng Whisper

    var whisperModel: WhisperModelChoice { language == .vi ? .phoWhisperMedium : .largeV3Turbo }
    var canRewrite: Bool { !audioFiles.isEmpty && !isRunning && !isRewriting }

    /// Nhận dạng lại toàn bộ bản ghi của phiên bằng PhoWhisper (tiếng Việt) / Whisper turbo (tiếng Anh),
    /// rồi phân tích lệnh như lúc đọc trực tiếp. Bản cũ được giữ trong lịch sử (Hoàn tác để quay lại).
    func rewriteWithWhisper() async {
        guard canRewrite else { return }
        let model = whisperModel
        guard WhisperModelStore.shared.isReady(model) else {
            errorText = "Chưa tải \(model.title). Tải ở tab Chép lời → Bộ nhận dạng."
            return
        }
        isRewriting = true
        errorText = nil
        defer { isRewriting = false }
        let compute = WhisperRunner.Compute(rawValue: UserDefaults.standard.string(forKey: "whisperCompute") ?? "") ?? .neuralEngine
        do {
            if !WhisperRunner.shared.isLoaded(model, compute) {
                status = "Đang nạp \(model.title)…"
                try await WhisperRunner.shared.load(model, compute: compute)
            }
            let collector = GrossSegmentCollector()
            let prompt = GrossParser.vocabulary.prefix(40).joined(separator: ", ")
            for (k, url) in audioFiles.enumerated() {
                status = "Đang chép lại bằng \(model.title)… (\(k + 1)/\(audioFiles.count))"
                try await WhisperRunner.shared.transcribe(
                    audioURL: url, model: model, language: language, promptText: prompt,
                    onProgress: { _ in }, onSegments: { segs in collector.add(segs.map(\.text)) })
            }
            // Phân tích lại từ đầu (tôn trọng "tạm dừng" / "tiếp tục ghi"), rồi gắn bản cũ vào lịch sử
            // để MỘT lần Hoàn tác quay về đúng bản trước khi chép lại.
            var fresh = GrossDoc(pathcode: doc.pathcode)
            var paused = false
            for line in collector.all {
                for sig in GrossParser.apply(GrossParser.parse(line), to: &fresh, paused: paused, corrections: corrections,
                                             cassetteReturn: cassetteReturn, inlineMarker: inlineMarker) {
                    if sig == .pause { paused = true } else if sig == .resume { paused = false }
                }
            }
            fresh.target = -1
            fresh.oneShot = false
            fresh.history = Array((doc.history + [doc.snapshot]).suffix(50))
            doc = fresh
            status = "Đã chép lại bằng \(model.title) · bấm Hoàn tác để về bản cũ"
        } catch {
            errorText = "Không chép lại được: \(error.localizedDescription)"
            status = ""
        }
    }

    // MARK: Tệp ghi âm (mỗi lần Bắt đầu một tệp)

    private var audioFiles: [URL] = []

    private static var audioDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrossAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        return d
    }

    private func newAudioURL() -> URL {
        Self.audioDir.appendingPathComponent("\(UUID().uuidString).caf")
    }

    private func appendAudio(_ url: URL) {
        audioFiles.append(url)
        audioURL = url
    }

    private func removeAudio() {
        for u in audioFiles { try? FileManager.default.removeItem(at: u) }
        audioFiles = []
        audioURL = nil
    }

    // MARK: Danh sách sửa lỗi nhận dạng

    private static func loadCorrections() -> [GrossCorrection] {
        guard let data = UserDefaults.standard.data(forKey: "grossCorrections"),
              let list = try? JSONDecoder().decode([GrossCorrection].self, from: data) else {
            return GrossParser.defaultCorrections
        }
        return list
    }

    private static func storeCorrections(_ list: [GrossCorrection]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: "grossCorrections") }
    }
}
