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

    /// Chuyển sang ghi vào tệp mới (lệnh "ca mới" giữa lúc đang ghi): tệp cũ được đóng.
    func rotate(to url: URL?) {
        let f = url.flatMap {
            try? AVAudioFile(forWriting: $0, settings: Self.recordFormat.settings,
                             commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        lock.withLock { file = f }
    }

    static let recordFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false)!

    func start(format: AVAudioFormat, recordTo url: URL?,
               onLevel: (@Sendable (_ rms: Float, _ seconds: Double) -> Void)? = nil,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        try await AudioSessionControl.activate(.playAndRecord, mode: .default,
                                               options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])

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
            if let onLevel, let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                let n = Int(buffer.frameLength)
                var e: Float = 0
                for i in 0 ..< n { e += ch[i] * ch[i] }
                onLevel((e / Float(n)).squareRoot(), Double(n) / buffer.format.sampleRate)
            }
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
        AudioSessionControl.deactivate()
    }
}

/// Gom các đoạn Whisper trả về từ luồng nền.
nonisolated final class GrossSegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: [String]) { lock.withLock { items += s } }
    var all: [String] { lock.withLock { items } }
}

// MARK: - Bộ nhận dạng cho tab Đại thể

/// Mô hình nhận dạng giọng nói khi đọc mô tả đại thể.
enum GrossEngine: String, CaseIterable, Identifiable, Sendable {
    case apple, phoWhisper, whisperTurbo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple"
        case .phoWhisper: "PhoWhisper"
        case .whisperTurbo: "Whisper turbo"
        }
    }
    var detail: String {
        switch self {
        case .apple: "Tức thì, chữ hiện ngay khi đang nói; hay nghe sai thuật ngữ."
        case .phoWhisper: "Chính xác nhất cho tiếng Việt (VinAI). Chữ hiện ~1–2 s sau mỗi lần ngừng nói."
        case .whisperTurbo: "Viết đúng thuật ngữ tiếng Anh xen trong câu (carcinoma, CD20, Ki-67). Chữ hiện sau mỗi lần ngừng nói."
        }
    }
    /// Mô hình Whisper tương ứng (PhoWhisper chỉ nghe tiếng Việt → tiếng Anh dùng turbo).
    func whisperModel(for language: TranscriptLanguage) -> WhisperModelChoice? {
        switch self {
        case .apple: nil
        case .phoWhisper: language == .vi ? .phoWhisperMedium : .largeV3Turbo
        case .whisperTurbo: .largeV3Turbo
        }
    }
}

/// Ngưỡng lời nói tự thích nghi với tiếng ồn nền (quạt hút, máy lạnh trong phòng cắt lọc).
nonisolated struct NoiseFloor {
    private var floor: Float = 0.004
    /// true nếu mức âm thanh này là lời nói
    mutating func isSpeech(_ rms: Float) -> Bool {
        if rms < floor { floor = rms } else { floor += (rms - floor) * 0.003 }   // hạ nhanh, lên chậm
        return rms > max(0.012, floor * 3)
    }
}

/// Báo mỗi lần người đọc ngừng nói (≥ 0,7 s sau ≥ 0,3 s lời nói) — để chốt chữ ngay, không đợi bấm Dừng.
nonisolated final class SilenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var speech: Double = 0
    private var silence: Double = 0
    private var fired = false
    private var noise = NoiseFloor()
    private let onPause: @Sendable () -> Void

    init(onPause: @escaping @Sendable () -> Void) { self.onPause = onPause }

    func level(_ rms: Float, seconds: Double) {
        let fire: Bool = lock.withLock {
            if noise.isSpeech(rms) {
                speech += seconds; silence = 0; fired = false
                return false
            }
            silence += seconds
            if !fired, speech > 0.3, silence > 0.7 { fired = true; speech = 0; return true }
            return false
        }
        if fire { onPause() }
    }
}

/// Cắt âm thanh micro (16 kHz mono) thành từng đoạn tại chỗ ngừng nói để đưa vào Whisper.
nonisolated final class VoiceChunker: @unchecked Sendable {
    private let lock = NSLock()
    private var buf: [Float] = []
    private var silence = 0
    private var speech = 0
    private var active = true
    private var noise = NoiseFloor()
    private let emit: @Sendable ([Float]) -> Void
    private let sampleRate = 16_000
    private let maxSeconds: Int

    /// - maxSeconds: đoạn dài nhất (không nghe ra chỗ ngừng) — phụ đề dùng 6 s để không trễ.
    init(maxSeconds: Int = 8, emit: @escaping @Sendable ([Float]) -> Void) { self.maxSeconds = maxSeconds; self.emit = emit }

    func feed(_ b: AVAudioPCMBuffer) {
        guard let ch = b.floatChannelData?[0] else { return }
        let n = Int(b.frameLength)
        let arr = Array(UnsafeBufferPointer(start: ch, count: n))
        var energy: Float = 0
        for v in arr { energy += v * v }
        let rms = (energy / Float(max(n, 1))).squareRoot()
        let out: [Float]? = lock.withLock {
            guard active else { return nil }
            buf += arr
            if noise.isSpeech(rms) { speech += n; silence = 0 } else { silence += n }
            // ngừng ≥ 0,6 s sau ≥ 0,2 s lời nói, hoặc đoạn dài 8 s (phòng ồn, không nghe ra chỗ ngừng) → gửi đi
            if (silence > sampleRate * 6 / 10 && buf.count > sampleRate && speech > sampleRate / 5) || buf.count > sampleRate * maxSeconds {
                defer { reset() }
                return buf
            }
            if silence > sampleRate * 2 && speech < sampleRate / 5 { reset() }   // chỉ có im lặng → bỏ
            return nil
        }
        if let out { emit(out) }
    }

    /// Phần còn lại khi dừng ghi.
    func flush() -> [Float]? {
        lock.withLock {
            defer { reset() }
            return speech > sampleRate / 5 ? buf : nil
        }
    }

    func setActive(_ on: Bool) { lock.withLock { active = on; if !on { reset() } } }

    /// Đoạn đang nói dở (để nhận dạng xem trước) kèm số thế hệ — đoạn bị gửi đi / bỏ thì thế hệ tăng.
    func snapshot() -> (samples: [Float], generation: Int)? {
        lock.withLock { speech > sampleRate * 2 / 5 ? (buf, generation) : nil }
    }
    var currentGeneration: Int { lock.withLock { generation } }
    private var generation = 0

    private func reset() { buf = []; silence = 0; speech = 0; generation += 1 }
}

// MARK: - Điều khiển tab Đại thể

@MainActor
@Observable
final class GrossDictationController {
    var doc = GrossDoc()
    var volatileText = "" {
        didSet { if volatileText.isEmpty { preview = nil } }
    }
    /// Bản xem trước: phần đang nghe đã áp lệnh (cát xét, dấu câu…) — hiển thị tức thì, chốt khi câu được chốt.
    private(set) var preview: GrossDoc?
    /// Văn bản đang hiển thị: bản xem trước nếu đang nghe, nếu không là văn bản thật.
    var liveDoc: GrossDoc { preview ?? doc }
    var isPreviewing: Bool { preview != nil }
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
    var engine: GrossEngine = GrossEngine(rawValue: UserDefaults.standard.string(forKey: "grossEngine") ?? "") ?? .apple {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "grossEngine") }
    }
    /// Whisper đang nhận dạng một đoạn vừa nói
    private(set) var whisperBusy = false
    /// Chẩn đoán chế độ Whisper: số đoạn, độ dài, thời gian nhận dạng, kết quả gần nhất
    private(set) var whisperInfo = ""
    private var chunkCount = 0
    private var chunker: VoiceChunker?
    private var chunkQueue: [[Float]] = []
    private var chunkTask: Task<Void, Never>?
    private var liveWhisper: WhisperModelChoice?
    /// Whisper: nhận dạng xem trước đoạn đang nói dở
    private var partialLoop: Task<Void, Never>?
    private var partialTask: Task<Void, Never>?
    /// Apple: số từ của câu "đang nghe" đã được chốt sớm tại chỗ ngừng nói
    private var committedWords = 0
    private var gate: SilenceGate?

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
        let d = liveDoc
        guard d.target >= 0, d.target < d.cassettes.count else { return "Mô tả" }
        return "Cát xét \(d.cassettes[d.target].label)" + (d.oneShot ? " → xong quay lại mô tả" : "")
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
        let whisperModel = engine.whisperModel(for: language)
        if let whisperModel, !WhisperModelStore.shared.isReady(whisperModel) {
            errorText = "Chưa tải \(whisperModel.title). Vào tab Chép lời → chọn \(whisperModel.title) → Tải, rồi quay lại."
            return
        }
        if whisperModel == nil {
            guard await EnglishTranscriber.requestAuthorization() else {
                errorText = "Chưa cấp quyền nhận dạng giọng nói (Cài đặt → ViPath)."
                return
            }
        }
        isRunning = true
        isPaused = false
        stopping = false
        volatileText = ""
        status = "Đang chuẩn bị…"
        UIApplication.shared.isIdleTimerDisabled = true      // không khoá màn hình khi đang cắt lọc

        if let whisperModel {
            await startWhisper(whisperModel)
            return
        }

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
            committedWords = 0
            let g = SilenceGate { Task { @MainActor in self.commitVolatile() } }
            gate = g
            try await m.start(format: format, recordTo: url, onLevel: { rms, sec in g.level(rms, seconds: sec) }) { buffer in rec.feed(buffer) }
            mic = m
            if let url { appendAudio(url) }
            status = "Đang nghe · \(targetLabel)"
        } catch {
            errorText = error.localizedDescription
            await teardown()
            status = ""
        }
    }

    /// Đọc chính tả bằng Whisper: micro → cắt đoạn tại chỗ ngừng nói → nhận dạng tuần tự → áp lệnh.
    private func startWhisper(_ model: WhisperModelChoice) async {
        let compute = WhisperRunner.Compute(rawValue: UserDefaults.standard.string(forKey: "whisperCompute") ?? "") ?? .neuralEngine
        do {
            if !WhisperRunner.shared.isLoaded(model, compute) {
                status = "Đang nạp \(model.title)… (lần đầu trên Neural Engine có thể mất 1–3 phút)"
                try await WhisperRunner.shared.load(model, compute: compute)
            }
            guard !stopping else { await teardown(); status = "Đã dừng"; return }
            liveWhisper = model
            engineLabel = model.title
            chunkCount = 0
            whisperInfo = "Đã nạp \(model.title) — đọc rồi ngừng nhẹ, chữ sẽ hiện sau mỗi đoạn"
            let ch = VoiceChunker { samples in Task { @MainActor in self.enqueueChunk(samples) } }
            chunker = ch
            let url = keepAudio ? newAudioURL() : nil
            let m = DictationMicrophone()
            try await m.start(format: DictationMicrophone.recordFormat, recordTo: url) { buffer in ch.feed(buffer) }
            mic = m
            if let url { appendAudio(url) }
            status = "Đang nghe (\(model.title)) · \(targetLabel)"
            startPartialLoop(ch)
        } catch {
            errorText = "Không nạp được \(model.title): \(error.localizedDescription)"
            await teardown()
            status = ""
        }
    }

    private func enqueueChunk(_ samples: [Float]) {
        // vẫn nhận dạng khi đang tạm dừng để nghe được lệnh "tiếp tục ghi" (các câu khác bị bỏ qua)
        guard isRunning else { return }
        chunkQueue.append(samples)
        startChunkWorker()
    }

    /// Whisper đôi khi đọc lại nguyên danh sách gợi ý khi đoạn âm thanh quá ngắn → bỏ.
    private static func dropPromptEcho(_ t: String) -> String {
        let head = GrossParser.vocabulary.prefix(3).joined(separator: ", ")
        return t.localizedCaseInsensitiveContains(head) ? "" : t
    }

    private var whisperPrompt: String {
        (GrossParser.vocabulary.prefix(30) + corrections.map(\.to)).joined(separator: ", ")
    }

    /// Mỗi ~1 s: nếu Whisper rảnh, nhận dạng đoạn đang nói dở → hiện xem trước (chữ nghiêng) ngay khi đang nói.
    private func startPartialLoop(_ ch: VoiceChunker) {
        partialLoop = Task {
            while !Task.isCancelled, isRunning {
                try? await Task.sleep(for: .milliseconds(900))
                guard isRunning, chunkTask == nil, partialTask == nil,
                      let snap = ch.snapshot(), liveWhisper != nil else { continue }
                let lang = language
                let prompt = whisperPrompt
                let job = Task {
                    let t = (try? await WhisperRunner.shared.transcribe(samples: snap.samples, language: lang,
                                                                        promptText: prompt, preview: true)) ?? ""
                    // đoạn đã được gửi đi nhận dạng chính thức trong lúc chờ → bỏ bản xem trước cũ
                    let clean = Self.dropPromptEcho(t)
                    if !clean.isEmpty, ch.currentGeneration == snap.generation, chunkTask == nil {
                        handle(clean, isFinal: false)
                    }
                }
                partialTask = job
                await job.value
                partialTask = nil
            }
        }
    }

    private func startChunkWorker() {
        guard chunkTask == nil, liveWhisper != nil, !chunkQueue.isEmpty else { return }
        let lang = language
        let prompt = whisperPrompt
        chunkTask = Task {
            await partialTask?.value          // không chạy song song hai lượt Whisper
            while !chunkQueue.isEmpty {
                let s = chunkQueue.removeFirst()
                whisperBusy = true
                updateStatus()
                chunkCount += 1
                let audioSec = Double(s.count) / 16_000
                let t0 = Date()
                do {
                    let t = try await WhisperRunner.shared.transcribe(samples: s, language: lang, promptText: prompt)
                    let took = Date().timeIntervalSince(t0)
                    let clean = Self.dropPromptEcho(t)
                    let onGPU = UserDefaults.standard.string(forKey: "whisperCompute") == WhisperRunner.Compute.gpu.rawValue
                    let slowHint = (onGPU && took > audioSec * 0.6) ? " · chậm: thử Neural Engine" : ""
                    whisperInfo = String(format: "Đoạn %d · %.1f s âm thanh → %.1f s nhận dạng", chunkCount, audioSec, took)
                        + slowHint + " · " + (clean.isEmpty ? "(không có chữ)" : "“\(clean.suffix(60))”")
                    if !clean.isEmpty { handle(clean, isFinal: true) }
                } catch {
                    whisperInfo = "Đoạn \(chunkCount): lỗi Whisper — \(error.localizedDescription)"
                    errorText = "Whisper không nhận dạng được: \(error.localizedDescription). Thử chuyển GPU ở tab Chép lời."
                }
            }
            whisperBusy = false
            chunkTask = nil
            updateStatus()
        }
    }

    private func updateStatus() {
        guard isRunning else { return }
        if isPaused { status = "Tạm dừng — nói \"tiếp tục ghi\" hoặc bấm ▶︎"; return }
        status = "Đang nghe · \(targetLabel)" + (whisperBusy ? " · đang nhận dạng…" : "")
    }

    func stop() async {
        guard isRunning else { return }
        stopping = true
        if starting { status = "Đang dừng…"; return }
        mic?.stop()
        mic = nil
        if let ch = chunker {
            // Whisper: nhận dạng nốt đoạn cuối trước khi dừng
            if let rest = ch.flush() { chunkQueue.append(rest) }
            startChunkWorker()
            status = "Đang nhận dạng nốt…"
            await chunkTask?.value
        }
        await recognizer?.finish()       // nhận nốt câu cuối
        flushCarry()
        await teardown()
        status = "Đã dừng"
    }

    private func teardown() async {
        mic?.stop()
        mic = nil
        await recognizer?.finish()
        recognizer = nil
        chunker = nil
        gate = nil
        committedWords = 0
        carry = ""
        partialLoop?.cancel()
        partialLoop = nil
        partialTask = nil
        chunkTask?.cancel()
        chunkTask = nil
        chunkQueue = []
        whisperBusy = false
        liveWhisper = nil
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
            // Bộ nhận dạng tiếng Việt có thể giữ cả tràng nói ở dạng "đang nghe" rất lâu →
            // áp lệnh lên bản xem trước để cát xét / xuống dòng hiện ngay, không đợi chốt câu.
            // Phần đã chốt sớm (tại chỗ ngừng nói) không áp lại.
            volatileText = text
            let rest = Self.words(text, after: committedWords)
            if !isPaused, !rest.isEmpty {
                preview = GrossParser.preview(doc, volatile: carry.isEmpty ? rest : carry + " " + rest,
                                              corrections: corrections,
                                              cassetteReturn: cassetteReturn, inlineMarker: inlineMarker)
            } else {
                preview = nil
            }
            updateStatus()
            return
        }
        volatileText = ""
        let rest = Self.words(text, after: committedWords)
        committedWords = 0
        lastHeard = text
        guard !rest.isEmpty else { updateStatus(); return }
        apply(rest)
    }

    /// Phần từ thứ `n` trở đi của một câu.
    private static func words(_ text: String, after n: Int) -> String {
        guard n > 0 else { return text }
        return text.split(whereSeparator: \.isWhitespace).dropFirst(n).joined(separator: " ")
    }

    /// Người đọc vừa ngừng nói → chốt luôn phần "đang nghe" vào văn bản (chữ thường, sửa được),
    /// không đợi bộ nhận dạng chốt câu hay bấm Dừng.
    private func commitVolatile() {
        guard isRunning, !volatileText.isEmpty else { return }
        let all = volatileText.split(whereSeparator: \.isWhitespace)
        guard all.count > committedWords else { return }
        let rest = all.dropFirst(committedWords).joined(separator: " ")
        committedWords = all.count
        preview = nil
        lastHeard = rest
        apply(rest)
    }

    /// Phần lệnh còn dở của đoạn trước ("mã ca" chưa kèm mã) — ghép vào đầu đoạn kế tiếp.
    private var carry = ""
    private var carryAt = Date.distantPast

    private func apply(_ text: String) {
        var t = text
        if !carry.isEmpty {
            // đoạn sau đến quá muộn → coi phần giữ lại là chữ thường
            if Date().timeIntervalSince(carryAt) < 12 { t = carry + " " + t } else { applyNow(carry) }
            carry = ""
        }
        let (keep, c) = GrossParser.splitDangling(t)
        if !c.isEmpty { carry = c; carryAt = Date() }
        if !keep.isEmpty { applyNow(keep) }
        if !carry.isEmpty, isRunning { status = "Nghe: “\(carry)” — đọc tiếp mã…" }
    }

    /// Đã dừng ghi mà còn phần lệnh dở → ghi ra như chữ thường.
    private func flushCarry() {
        guard !carry.isEmpty else { return }
        let c = carry
        carry = ""
        applyNow(c)
    }

    private func applyNow(_ text: String) {
        let signals = GrossParser.apply(GrossParser.parse(text), to: &doc, paused: isPaused, corrections: corrections,
                                        cassetteReturn: cassetteReturn, inlineMarker: inlineMarker)
        for s in signals {
            switch s {
            case .pause: isPaused = true; mic?.setRecording(false)
            case .resume: isPaused = false; mic?.setRecording(true)
            case .stop: Task { await stop() }
            case .newCase(let finished): finishCase(finished)
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

    /// Thông báo ngắn cho giao diện (vd. "Đã lưu ca … · ca mới") — `noticeCount` tăng mỗi lần có thông báo.
    private(set) var notice = ""
    private(set) var noticeCount = 0

    /// Lệnh giọng nói "ca mới [, mã ca …]": lưu ca vừa đọc, bắt đầu ca mới — không cần chạm màn hình.
    private func finishCase(_ s: GrossDoc.Snapshot) {
        var old = GrossDoc(pathcode: s.pathcode)
        old.restore(s)
        let hasContent = !old.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !old.cassettes.isEmpty
        let saved = hasContent ? save(old) : false
        savedID = nil
        // bản ghi âm thuộc ca cũ → bỏ; đang ghi thì chuyển sang tệp mới cho ca mới
        if isRunning, let mic {
            let url = keepAudio ? newAudioURL() : nil
            mic.rotate(to: url)
            removeAudio()
            if let url { appendAudio(url) }
        } else {
            removeAudio()
        }
        let oldName = s.pathcode.isEmpty ? "ca trước" : "ca \(s.pathcode)"
        let newName = doc.pathcode.isEmpty ? "ca mới — nói “mã ca …” để đặt pathcode" : "ca mới \(doc.pathcode)"
        notice = (saved ? "Đã lưu \(oldName) · " : hasContent ? "⚠︎ Chưa lưu được \(oldName) · " : "") + newName
        noticeCount += 1
    }

    @discardableResult
    func save() -> Bool { save(doc) }

    @discardableResult
    private func save(_ d: GrossDoc) -> Bool {
        let text = GrossParser.reportText(d, english: language == .en)
        guard !text.isEmpty else { return false }
        let title = d.pathcode.isEmpty
            ? "Đại thể · " + SavedItem.autoTitle(d.body.isEmpty ? text : d.body)
            : "Đại thể · " + d.pathcode
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
            var pending = ""      // "mã ca" ở cuối đoạn → ghép vào đoạn sau
            for line in collector.all + [""] {
                let joined = pending.isEmpty ? line : pending + " " + line
                let (keep, c) = line.isEmpty ? (joined, "") : GrossParser.splitDangling(joined)
                pending = c
                guard !keep.isEmpty else { continue }
                for sig in GrossParser.apply(GrossParser.parse(keep), to: &fresh, paused: paused, corrections: corrections,
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
