import AVFoundation
import CoreML
import Foundation
import Observation
import WhisperKit

// MARK: - Mô hình Whisper

/// Mô hình Whisper (Core ML, chạy trên Neural Engine qua WhisperKit).
enum WhisperModelChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case phoWhisperMedium
    case largeV3Turbo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phoWhisperMedium: "PhoWhisper-medium"
        case .largeV3Turbo: "Whisper large-v3 turbo"
        }
    }

    var sizeLabel: String {
        switch self {
        case .phoWhisperMedium: "~560 MB"
        case .largeV3Turbo: "~630 MB"
        }
    }

    var summary: String {
        switch self {
        case .phoWhisperMedium:
            "VinAI tinh chỉnh trên 844 giờ tiếng Việt — chính xác nhất cho tiếng Việt (WER 8,3% Common Voice, 5,0% VIVOS)."
        case .largeV3Turbo:
            "Đa ngôn ngữ, hợp bài giảng trộn Anh–Việt; nén 632 MB, bộ giải mã 4 lớp nên nhanh."
        }
    }

    /// Kho Hugging Face và thư mục con chứa mô hình.
    var repo: String {
        switch self {
        case .phoWhisperMedium: "aoiandroid/whisper-vi-phowhisper-medium-whisperkit-coreml-ios"
        case .largeV3Turbo: "argmaxinc/whisperkit-coreml"
        }
    }

    var repoFolder: String? {
        switch self {
        case .phoWhisperMedium: nil
        case .largeV3Turbo: "openai_whisper-large-v3-v20240930_turbo_632MB"
        }
    }

    /// Kho lấy tokenizer nếu gói mô hình không kèm sẵn.
    var tokenizerRepo: String? {
        switch self {
        case .phoWhisperMedium: nil                    // gói đã kèm tokenizer (bản sửa 30/9/2026)
        case .largeV3Turbo: "openai/whisper-large-v3-turbo"
        }
    }

    /// Độ dài tối đa mỗi cửa sổ âm thanh đưa vào Whisper.
    /// PhoWhisper bản Core ML: ≤ 15 s (cửa sổ 30 s làm rơi câu vì token tiếng Việt dài).
    var maxWindow: Double {
        switch self {
        case .phoWhisperMedium: 14
        case .largeV3Turbo: 27
        }
    }
}

// MARK: - Tải và quản lý mô hình

/// Tải mô hình Whisper từ Hugging Face một lần (cần Internet), lưu trong Application Support,
/// không sao lưu iCloud. Sau đó chạy hoàn toàn offline.
@MainActor
@Observable
final class WhisperModelStore {
    static let shared = WhisperModelStore()

    enum State: Equatable { case notDownloaded, downloading(Double), ready }

    private(set) var states: [WhisperModelChoice: State] = [:]
    var errorText: String?
    private var tasks: [WhisperModelChoice: Task<Void, Never>] = [:]

    private init() {
        for m in WhisperModelChoice.allCases {
            states[m] = Self.isComplete(m) ? .ready : .notDownloaded
        }
    }

    nonisolated static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperModels", isDirectory: true)
    }

    nonisolated static func folder(_ m: WhisperModelChoice) -> URL {
        baseDir.appendingPathComponent(m.rawValue, isDirectory: true)
    }

    nonisolated static func isComplete(_ m: WhisperModelChoice) -> Bool {
        let f = folder(m)
        let fm = FileManager.default
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "tokenizer.json"]
            .allSatisfy { fm.fileExists(atPath: f.appendingPathComponent($0).path) }
    }

    func state(_ m: WhisperModelChoice) -> State { states[m] ?? .notDownloaded }
    func isReady(_ m: WhisperModelChoice) -> Bool { state(m) == .ready }

    func download(_ m: WhisperModelChoice) {
        guard tasks[m] == nil, !isReady(m) else { return }
        errorText = nil
        states[m] = .downloading(0)
        tasks[m] = Task {
            do {
                try await ModelDownloader.download(m) { p in
                    Task { @MainActor in
                        if case .downloading = self.states[m] { self.states[m] = .downloading(p) }
                    }
                }
                states[m] = .ready
            } catch is CancellationError {
                states[m] = .notDownloaded
            } catch {
                states[m] = .notDownloaded
                errorText = "Tải \(m.title) lỗi: \(error.localizedDescription)"
            }
            tasks[m] = nil
        }
    }

    func cancel(_ m: WhisperModelChoice) {
        tasks[m]?.cancel()
    }

    func delete(_ m: WhisperModelChoice) {
        cancel(m)
        try? FileManager.default.removeItem(at: Self.folder(m))
        states[m] = .notDownloaded
        WhisperRunner.shared.unload()
    }
}

/// Tải từng tệp trong kho Hugging Face (liệt kê qua API, rồi tải bằng URLSession).
nonisolated enum ModelDownloader {
    private struct Entry: Decodable { let type: String; let path: String; let size: Int? }

    static func download(_ m: WhisperModelChoice, progress: @Sendable @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: WhisperModelStore.baseDir, withIntermediateDirectories: true)
        let partial = WhisperModelStore.baseDir.appendingPathComponent(m.rawValue + ".partial", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)

        // Danh sách tệp
        var files: [(remote: String, local: String, size: Int, repo: String)] = []
        for e in try await list(repo: m.repo, folder: m.repoFolder) where e.type == "file" {
            let name = (e.path as NSString).lastPathComponent
            if name == ".gitattributes" || name.lowercased().hasPrefix("readme") { continue }
            var local = e.path
            if let prefix = m.repoFolder, local.hasPrefix(prefix + "/") { local.removeFirst(prefix.count + 1) }
            files.append((e.path, local, e.size ?? 0, m.repo))
        }
        if let tok = m.tokenizerRepo {
            for name in ["tokenizer.json", "tokenizer_config.json"] {
                files.append((name, name, 0, tok))
            }
        }
        guard !files.isEmpty else { throw URLError(.zeroByteResource) }
        let total = max(1, files.map(\.size).reduce(0, +))

        var done = 0
        for f in files {
            try Task.checkCancellation()
            let dest = partial.appendingPathComponent(f.local)
            if let attrs = try? fm.attributesOfItem(atPath: dest.path),
               let s = attrs[.size] as? Int, f.size > 0, s == f.size {
                done += f.size                 // đã tải ở lần trước (tải tiếp sau khi gián đoạn)
                progress(Double(done) / Double(total))
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoded = f.remote.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
            }.joined(separator: "/")
            guard let url = URL(string: "https://huggingface.co/\(f.repo)/resolve/main/\(encoded)") else { continue }
            let base = done
            let delegate = ProgressDelegate { written in
                progress(min(1, Double(base + Int(written)) / Double(total)))
            }
            let (tmp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            done += f.size
            progress(Double(done) / Double(total))
        }

        // Hoàn tất → đổi tên thư mục, không sao lưu iCloud
        let final = WhisperModelStore.folder(m)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: partial, to: final)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var finalURL = final
        try? finalURL.setResourceValues(values)
    }

    private static func list(repo: String, folder: String?) async throws -> [Entry] {
        var path = "https://huggingface.co/api/models/\(repo)/tree/main"
        if let folder { path += "/\(folder)" }
        guard let url = URL(string: path + "?recursive=true") else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([Entry].self, from: data)
    }

    /// Nhận tiến độ từng tệp lớn (weight.bin vài trăm MB) bằng KVO trên số byte đã nhận.
    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let onWrite: @Sendable (Int64) -> Void
        private var observation: NSKeyValueObservation?
        init(onWrite: @Sendable @escaping (Int64) -> Void) { self.onWrite = onWrite }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let cb = onWrite
            observation = task.observe(\.countOfBytesReceived, options: [.new]) { t, _ in
                cb(t.countOfBytesReceived)
            }
        }
    }
}

// MARK: - Chạy Whisper

/// Trạng thái nạp Whisper cho giao diện (mọi tab cùng thấy: đã nạp mô hình nào, trên Neural Engine hay GPU).
@MainActor
@Observable
final class WhisperStatus {
    static let shared = WhisperStatus()
    private(set) var loaded: WhisperModelChoice?
    private(set) var compute: WhisperRunner.Compute?
    private(set) var loading: WhisperModelChoice?
    private(set) var loadingCompute: WhisperRunner.Compute?
    private(set) var loadingSince: Date?
    private(set) var lastError: String?
    /// Đã nạp xong, đang chạy thử một đoạn ngắn để lượt nhận dạng thật đầu tiên không bị chậm.
    private(set) var warming = false

    func isLoaded(_ m: WhisperModelChoice, _ c: WhisperRunner.Compute) -> Bool { loaded == m && compute == c }

    fileprivate func begin(_ m: WhisperModelChoice, _ c: WhisperRunner.Compute) {
        loading = m; loadingCompute = c; loadingSince = Date(); lastError = nil; warming = false
        if loaded != nil { loaded = nil; compute = nil }      // mô hình cũ đã bị bỏ khi bắt đầu nạp
    }
    fileprivate func startWarming() { warming = true }
    fileprivate func finished(_ m: WhisperModelChoice, _ c: WhisperRunner.Compute) {
        loaded = m; compute = c; loading = nil; loadingCompute = nil; loadingSince = nil; warming = false
    }
    /// Mô hình nạp lỗi gần nhất (để chỉ hiện lỗi ở đúng dòng mô hình đó)
    private(set) var failedModel: WhisperModelChoice?
    fileprivate func failed(_ m: WhisperModelChoice, _ message: String?) {
        loading = nil; loadingCompute = nil; loadingSince = nil; warming = false; lastError = message; failedModel = message == nil ? nil : m
    }
    fileprivate func cleared() {
        loaded = nil; compute = nil; loading = nil; loadingCompute = nil; loadingSince = nil; warming = false; lastError = nil; failedModel = nil
    }
}

/// Giữ một phiên WhisperKit đã nạp; bộ mã hoá âm thanh và bộ giải mã chạy trên Neural Engine.
/// Âm thanh được cắt thành cửa sổ ≤ `maxWindow` giây tại chỗ im lặng nhất gần cuối cửa sổ.
nonisolated final class WhisperRunner: @unchecked Sendable {
    static let shared = WhisperRunner()

    /// Phần cứng chạy Whisper.
    /// Neural Engine: nhanh, tiết kiệm pin, nhưng lần nạp ĐẦU TIÊN iOS phải biên dịch mô hình cho ANE
    /// (large-v3 turbo có thể mất nhiều phút). GPU: nạp trong vài giây, chạy chung GPU với mô hình dịch.
    enum Compute: String, CaseIterable, Identifiable, Sendable {
        case neuralEngine, gpu
        var id: String { rawValue }
        var label: String { self == .neuralEngine ? "Neural Engine" : "GPU" }
    }

    private let lock = NSLock()
    private var kit: WhisperKit?
    private var loaded: WhisperModelChoice?
    private var loadedCompute: Compute?
    private var generation = 0

    func unload() {
        lock.withLock {
            generation += 1
            kit = nil
            loaded = nil
            loadedCompute = nil
        }
        Task { @MainActor in WhisperStatus.shared.cleared() }
    }

    func isLoaded(_ m: WhisperModelChoice, _ c: Compute) -> Bool {
        lock.withLock { loaded == m && loadedCompute == c && kit != nil }
    }

    /// Đang giữ một mô hình Whisper trong bộ nhớ (bất kể loại nào).
    var hasLoadedModel: Bool { lock.withLock { kit != nil } }

    /// Lượt nạp đang chạy — nơi khác xin nạp đúng mô hình + phần cứng đó thì chờ chung, không nạp lại từ đầu.
    private var inFlight: (m: WhisperModelChoice, c: Compute, task: Task<Void, Error>)?

    @concurrent
    func load(_ m: WhisperModelChoice, compute c: Compute) async throws {
        if isLoaded(m, c) { return }
        let task: Task<Void, Error> = lock.withLock {
            if let f = inFlight, f.m == m, f.c == c { return f.task }
            let t = Task { try await self.loadNow(m, compute: c) }
            inFlight = (m, c, t)
            return t
        }
        defer { lock.withLock { if inFlight?.task == task { inFlight = nil } } }
        try await task.value
    }

    /// Lượt nạp cũ (bị huỷ / bị thay bằng lượt nạp khác) hoàn tất muộn sẽ bị bỏ, không ghi đè.
    private func loadNow(_ m: WhisperModelChoice, compute c: Compute) async throws {
        if isLoaded(m, c) { return }
        let gen = lock.withLock { () -> Int in
            generation += 1
            kit = nil
            loaded = nil
            loadedCompute = nil
            return generation
        }
        await MainActor.run { WhisperStatus.shared.begin(m, c) }
        let folder = WhisperModelStore.folder(m)
        let compute: ModelComputeOptions = switch c {
        case .neuralEngine:
            ModelComputeOptions(melCompute: .cpuAndGPU,
                                audioEncoderCompute: .cpuAndNeuralEngine,
                                textDecoderCompute: .cpuAndNeuralEngine)
        case .gpu:
            ModelComputeOptions(melCompute: .cpuAndGPU,
                                audioEncoderCompute: .cpuAndGPU,
                                textDecoderCompute: .cpuAndGPU)
        }
        // prewarm = false: prewarm nạp → bỏ → nạp lại từng mô hình, làm lần nạp đầu lâu gấp đôi
        let config = WhisperKitConfig(modelFolder: folder.path,
                                      tokenizerFolder: folder,
                                      computeOptions: compute,
                                      verbose: false,
                                      prewarm: false,
                                      load: true,
                                      download: false)
        let k: WhisperKit
        let t0 = Date()
        do {
            k = try await WhisperKit(config)
        } catch {
            let stillCurrent = lock.withLock { gen == generation }
            let msg = error is CancellationError ? nil : error.localizedDescription
            if stillCurrent { await MainActor.run { WhisperStatus.shared.failed(m, msg) } }
            throw error
        }
        let current = lock.withLock { () -> Bool in
            guard gen == generation else { return false }
            kit = k
            loaded = m
            loadedCompute = c
            return true
        }
        if !current { throw CancellationError() }
        let loadSeconds = Date().timeIntervalSince(t0)
        await MainActor.run { WhisperStatus.shared.startWarming() }
        let warm = await Self.warmUp(k)
        guard lock.withLock({ gen == generation }) else { throw CancellationError() }
        await MainActor.run {
            WhisperStatus.shared.finished(m, c)
            LoadTimings.shared.record(LoadTimings.key(m, c), load: loadSeconds, warm: warm)
        }
    }

    /// Nhận dạng thử 1 giây tiếng ồn nhẹ (tối đa 4 token): Core ML cấp phát bộ đệm và chuẩn bị
    /// Neural Engine/GPU ở đây, nên câu đọc đầu tiên ở tab Đại thể hiện chữ ngay.
    private static func warmUp(_ k: WhisperKit) async -> Double {
        let t0 = Date()
        var g = SystemRandomNumberGenerator()
        let noise = (0..<16_000).map { _ in Float.random(in: -0.01...0.01, using: &g) }
        let options = DecodingOptions(task: .transcribe, language: "en", temperature: 0,
                                      temperatureFallbackCount: 0, sampleLength: 4,
                                      usePrefillPrompt: true, detectLanguage: false,
                                      withoutTimestamps: true)
        _ = try? await k.transcribe(audioArray: noise, decodeOptions: options)
        return Date().timeIntervalSince(t0)
    }

    /// - promptText: gợi ý thuật ngữ (vd. danh sách thuật ngữ GPB) để Whisper viết đúng chính tả
    @concurrent
    func transcribe(audioURL: URL, model: WhisperModelChoice, language: TranscriptLanguage, promptText: String?,
                    onProgress: @Sendable @escaping (Double) -> Void,
                    onSegments: @Sendable @escaping ([TranscriptSegment]) -> Void) async throws {
        guard let kit = lock.withLock({ kit }) else { throw CocoaError(.featureUnsupported) }

        var promptTokens: [Int]?
        if let promptText, !promptText.isEmpty, let tok = kit.tokenizer {
            let ids = tok.encode(text: " " + promptText).filter { $0 < tok.specialTokens.specialTokenBegin }
            promptTokens = Array(ids.prefix(120))
        }
        let options = DecodingOptions(task: .transcribe,
                                      language: language.languageCode,
                                      temperature: 0,
                                      usePrefillPrompt: true,
                                      detectLanguage: false,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: false,
                                      wordTimestamps: false,
                                      promptTokens: promptTokens,
                                      suppressBlank: true,
                                      chunkingStrategy: ChunkingStrategy.none)

        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sr = format.sampleRate
        let total = file.length
        let maxFrames = AVAudioFrameCount(model.maxWindow * sr)
        var position: AVAudioFramePosition = 0

        while position < total {
            try Task.checkCancellation()
            file.framePosition = position
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else { break }
            try file.read(into: buffer, frameCount: maxFrames)
            let n = Int(buffer.frameLength)
            guard n > 0, let ch = buffer.floatChannelData?[0] else { break }
            let samples = Array(UnsafeBufferPointer(start: ch, count: n))
            let isLast = position + AVAudioFramePosition(n) >= total
            let cut = isLast ? n : Self.quietestCut(samples, sampleRate: sr)
            let chunk = Array(samples[0..<cut])
            let offset = Double(position) / sr

            if Self.rms(chunk) > 0.003 {         // bỏ qua đoạn im lặng (tránh Whisper "bịa" chữ)
                let results = try await kit.transcribe(audioArray: chunk, decodeOptions: options)
                let chunkEnd = offset + Double(cut) / sr
                let segs: [TranscriptSegment] = results.flatMap(\.segments).compactMap { s in
                    let text = Self.clean(s.text)
                    guard !text.isEmpty else { return nil }
                    let start = offset + Double(max(0, s.start))
                    let end = min(chunkEnd, max(start + 0.5, offset + Double(s.end)))
                    return TranscriptSegment(start: start, end: end, text: text)
                }
                if !segs.isEmpty { onSegments(segs) }
            }
            position += AVAudioFramePosition(cut)
            onProgress(min(1, Double(position) / Double(max(total, 1))))
        }
    }

    /// Nhận dạng một đoạn âm thanh ngắn (16 kHz mono) — dùng cho đọc chính tả trực tiếp ở tab Đại thể.
    @concurrent
    func transcribe(samples: [Float], language: TranscriptLanguage, promptText: String?) async throws -> String {
        guard let kit = lock.withLock({ kit }) else { throw CocoaError(.featureUnsupported) }
        guard Self.rms(samples) > 0.003 else { return "" }       // im lặng → không để Whisper "bịa" chữ
        var promptTokens: [Int]?
        if let promptText, !promptText.isEmpty, let tok = kit.tokenizer {
            let ids = tok.encode(text: " " + promptText).filter { $0 < tok.specialTokens.specialTokenBegin }
            promptTokens = Array(ids.prefix(120))
        }
        let options = DecodingOptions(task: .transcribe,
                                      language: language.languageCode,
                                      temperature: 0,
                                      usePrefillPrompt: true,
                                      detectLanguage: false,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: true,
                                      wordTimestamps: false,
                                      promptTokens: promptTokens,
                                      suppressBlank: true,
                                      chunkingStrategy: ChunkingStrategy.none)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    /// Cắt tại khung 100 ms nhỏ năng lượng nhất trong 3 giây cuối cửa sổ.
    private static func quietestCut(_ s: [Float], sampleRate: Double) -> Int {
        let frame = Int(sampleRate * 0.1)
        let searchStart = max(frame, s.count - Int(sampleRate * 3))
        var best = s.count, bestEnergy = Float.greatestFiniteMagnitude
        var i = searchStart
        while i + frame <= s.count {
            var e: Float = 0
            for j in i..<(i + frame) { e += s[j] * s[j] }
            if e < bestEnergy { bestEnergy = e; best = i + frame / 2 }
            i += frame / 2
        }
        return max(frame, best)
    }

    private static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var e: Float = 0
        for v in s { e += v * v }
        return (e / Float(s.count)).squareRoot()
    }

    /// Bỏ token đặc biệt còn sót (<|0.00|>, <|vi|>…) và khoảng trắng thừa.
    private static func clean(_ t: String) -> String {
        t.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
