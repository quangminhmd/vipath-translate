import AVFoundation
import Foundation
import Speech

// MARK: - Nhận dạng giọng nói tiếng Anh trên máy (iOS 26 SpeechAnalyzer)

/// Bọc SpeechAnalyzer + SpeechTranscriber. Mô hình nhận dạng do hệ thống quản lý
/// (tải một lần qua AssetInventory, sau đó chạy offline, không tính vào RAM của app).
nonisolated final class EnglishTranscriber: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    /// Ghi từ luồng gọi start/finish, đọc từ luồng audio → bảo vệ bằng khoá.
    private let lock = NSLock()
    private var _continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation? {
        get { lock.withLock { _continuation } }
        set { lock.withLock { _continuation = newValue } }
    }
    private var resultsTask: Task<Void, Never>?
    private var analyzerStarted = false
    private(set) var analyzerFormat: AVAudioFormat?

    /// Xin quyền nhận dạng giọng nói. Đặt ở kiểu nonisolated để handler (gọi trên luồng nền)
    /// không bị suy luận thành @MainActor → tránh crash kiểm tra actor của Swift 6.
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable (status) in c.resume(returning: status == .authorized) }
        }
    }

    /// Chọn locale tiếng Anh được hỗ trợ, ưu tiên en-US.
    private static func pickLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let english = supported.filter { $0.language.languageCode?.identifier == "en" }
        return english.first { $0.identifier(.bcp47) == "en-US" } ?? english.first
    }

    /// Chuẩn bị mô hình (tải nếu chưa có) và bắt đầu phiên nhận dạng.
    /// `onResult(text, isFinal)` được gọi trên luồng nền.
    func start(status: @Sendable @escaping (String) -> Void,
               onResult: @Sendable @escaping (String, Bool) -> Void) async throws {
        guard let locale = await Self.pickLocale() else { throw SpeechError.noEnglish }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            // fastResults: trả câu đã chốt sớm hơn (đổi lấy chút độ chính xác)
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if !installed.contains(locale.identifier(.bcp47)) {
            status("Đang tải mô hình nhận dạng giọng nói (một lần)…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.transcriber = transcriber
        self.analyzer = analyzer

        resultsTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    onResult(String(result.text.characters), result.isFinal)
                }
            } catch {
                if !Task.isCancelled { status("Nhận dạng giọng nói dừng: \(error.localizedDescription)") }
            }
        }
        try await analyzer.start(inputSequence: stream)
        analyzerStarted = true
        status("Đang nghe")
    }

    /// Đưa một khối âm thanh (đã đúng `analyzerFormat`) vào bộ nhận dạng. An toàn từ luồng audio.
    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async {
        let c = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in
            defer { _continuation = nil }
            return _continuation
        }
        c?.finish()
        // Đã chạy → chờ nhận nốt kết quả cuối (huỷ ngay sẽ mất câu cuối cùng).
        // Chưa chạy được (lỗi khi khởi động) → luồng kết quả có thể không bao giờ kết thúc → huỷ.
        if analyzerStarted, let analyzer, let results = resultsTask,
           (try? await analyzer.finalizeAndFinishThroughEndOfInput()) != nil {
            // chờ tối đa 2 s để không treo nút Dừng nếu luồng kết quả không tự kết thúc
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
        transcriber = nil
    }

    enum SpeechError: LocalizedError {
        case noEnglish
        var errorDescription: String? { "Thiết bị không hỗ trợ nhận dạng tiếng Anh trên máy." }
    }
}

// MARK: - Chuyển định dạng âm thanh

/// Đổi tần số lấy mẫu / số kênh / kiểu mẫu sang định dạng bộ nhận dạng yêu cầu.
/// Không an toàn đa luồng: mỗi nguồn âm thanh dùng một bộ riêng trên luồng của nó.
nonisolated final class BufferConverter: @unchecked Sendable {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let input = OneShotInput(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { @Sendable (_, inputStatus) in
            input.next(inputStatus)
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

// MARK: - Phiên âm thanh (ngoài luồng giao diện)

/// setCategory / setActive có thể chặn vài trăm ms → làm trên một hàng đợi nền nối tiếp
/// (giữ đúng thứ tự: tắt phiên cũ xong mới bật phiên mới), không chạy trên luồng giao diện.
nonisolated enum AudioSessionControl {
    private static let queue = DispatchQueue(label: "vn.quangminh.vipath.audiosession", qos: .userInitiated)

    static func activate(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) async throws {
        // chỉ chuyển giá trị thô (String/UInt) sang hàng đợi nền — chắc chắn Sendable
        let cat = category.rawValue, md = mode.rawValue, opt = options.rawValue
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let s = AVAudioSession.sharedInstance()
                    try s.setCategory(AVAudioSession.Category(rawValue: cat), mode: AVAudioSession.Mode(rawValue: md),
                                      options: AVAudioSession.CategoryOptions(rawValue: opt))
                    try s.setActive(true)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// Phát âm thanh (đọc bản dịch): giữ playAndRecord nếu micro đang dùng.
    static func preparePlayback() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                let s = AVAudioSession.sharedInstance()
                if s.category != .playAndRecord && s.category != .playback {
                    try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                }
                try? s.setActive(true)
                c.resume()
            }
        }
    }

    /// Tắt phiên (không chờ).
    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// MARK: - Nguồn âm thanh

nonisolated protocol AudioSource: AnyObject, Sendable {
    /// `onBuffer` nhận âm thanh đã chuyển sang `format`.
    func start(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
    func stop()
}

/// Micro của iPhone: nghe giảng / hội thảo trực tiếp, hoặc đặt máy cạnh loa máy tính đang họp Zoom/Teams.
nonisolated final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        // playAndRecord: vẫn đọc được bản dịch ra tai nghe trong lúc nghe micro
        try await AudioSessionControl.activate(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .mixWithOthers])

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = BufferConverter(target: format)
        // @Sendable: khối chạy trên luồng audio thời gian thực, không được suy luận thành @MainActor
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable (buffer, _) in
            if let out = converter.convert(buffer) { onBuffer(out) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        AudioSessionControl.deactivate()
    }
}

/// Âm thanh của app khác (Zoom, Teams…) trên CHÍNH iPhone này, do Broadcast Upload Extension
/// (target ViPathBroadcast) ghi thành các khối PCM 16 kHz mono Int16 trong App Group.
nonisolated final class BroadcastSource: AudioSource, @unchecked Sendable {
    private var task: Task<Void, Never>?

    func start(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        guard let dir = SharedAudio.directory else { throw SourceError.noAppGroup }
        SharedAudio.removeAllChunks(in: dir)
        let converter = BufferConverter(target: format)   // Sendable; không bắt AVAudioFormat vào task
        task = Task.detached(priority: .userInitiated) {
            let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: SharedAudio.sampleRate,
                                          channels: 1, interleaved: true)!
            while !Task.isCancelled {
                var chunks = SharedAudio.chunkFiles(in: dir)
                // app vừa bị gián đoạn → bỏ phần quá cũ để phụ đề bám sát thời gian thực
                if chunks.count > SharedAudio.maxBacklogChunks {
                    for url in chunks.dropLast(SharedAudio.maxBacklogChunks) { try? FileManager.default.removeItem(at: url) }
                    chunks = Array(chunks.suffix(SharedAudio.maxBacklogChunks))
                }
                for url in chunks {
                    if let data = try? Data(contentsOf: url) {
                        let frames = AVAudioFrameCount(data.count / 2)
                        if frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames) {
                            buf.frameLength = frames
                            data.withUnsafeBytes { raw in
                                if let src = raw.baseAddress, let dst = buf.int16ChannelData?[0] {
                                    memcpy(dst, src, Int(frames) * 2)
                                }
                            }
                            if let out = converter.convert(buf) { onBuffer(out) }
                        }
                    }
                    try? FileManager.default.removeItem(at: url)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Extension đang phát sóng (đã ghi trạng thái "live")?
    static var isBroadcastLive: Bool { SharedAudio.readState() == "live" }

    enum SourceError: LocalizedError {
        case noAppGroup
        var errorDescription: String? {
            "Chưa cấu hình App Group — xem mục Zoom/Teams trên cùng iPhone trong README."
        }
    }
}
