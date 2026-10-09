import AVFoundation
import CoreTransferable
import CoreMedia
import Foundation
import Speech
import UniformTypeIdentifiers

// MARK: - Dữ liệu

/// Một đoạn phụ đề có mốc thời gian (giây tính từ đầu tệp).
struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var translation: String = ""
    /// Bản dịch hiện có là bản nhanh (Apple Translation), chưa qua mô hình + glossary
    var isFast: Bool = false
}

/// Ngôn ngữ nói trong tệp ghi âm / video.
enum TranscriptLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case en, vi
    var id: String { rawValue }
    var label: String { self == .en ? "Tiếng Anh" : "Tiếng Việt" }
    var shortLabel: String { self == .en ? "English" : "Tiếng Việt" }
    var direction: TranslationDirection { self == .en ? .enToVi : .viToEn }
    var languageCode: String { rawValue }
}

// MARK: - Trích âm thanh

/// Giải mã track âm thanh của tệp audio / video (m4a, mp3, wav, mp4, mov…) thành CAF PCM mono 16 kHz.
/// Tệp CAF dùng cho cả nhận dạng và nghe lại theo mốc thời gian.
nonisolated enum MediaAudioExtractor {
    static let sampleRate: Double = 16_000

    enum ExtractError: LocalizedError {
        case noAudio, readerFailed(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: "Tệp không có track âm thanh."
            case .readerFailed(let s): "Không đọc được âm thanh: \(s)"
            }
        }
    }

    /// Trả về (đường dẫn CAF, thời lượng giây).
    static func extract(from source: URL, progress: @Sendable (Double) -> Void) async throws -> (URL, Double) {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExtractError.noAudio }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractError.readerFailed("không gắn được bộ đọc") }
        reader.add(output)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw ExtractError.readerFailed("định dạng")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Transcribe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = dir.appendingPathComponent(UUID().uuidString + ".caf")
        let file = try AVAudioFile(forWriting: outURL, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        guard reader.startReading() else {
            throw ExtractError.readerFailed(reader.error?.localizedDescription ?? "startReading")
        }
        var written: Double = 0
        var lastReport = 0.0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { continue }
            try file.write(from: buffer)
            written += Double(frames) / sampleRate
            if duration > 0, written - lastReport > 2 {
                lastReport = written
                progress(min(1, written / duration))
            }
        }
        if reader.status == .failed {
            throw ExtractError.readerFailed(reader.error?.localizedDescription ?? "lỗi giải mã")
        }
        progress(1)
        return (outURL, duration > 0 ? duration : written)
    }
}

// MARK: - Nhận dạng có mốc thời gian

/// Chép lời tệp âm thanh trên máy bằng SpeechAnalyzer (iOS 26).
/// Tiếng Anh: SpeechTranscriber. Tiếng Việt: SpeechTranscriber nếu hệ thống hỗ trợ, nếu không dùng DictationTranscriber.
/// Kết quả được chia thành đoạn phụ đề theo mốc thời gian từng từ (audioTimeRange).
nonisolated enum FileTranscriber {

    enum TranscribeError: LocalizedError {
        case unsupported(String), noFormat
        var errorDescription: String? {
            switch self {
            case .unsupported(let l): "iPhone chưa hỗ trợ nhận dạng \(l) trên máy."
            case .noFormat: "Không xác định được định dạng âm thanh cho bộ nhận dạng."
            }
        }
    }

    /// - onStatus: thông báo trạng thái (tải mô hình…)
    /// - onProgress: 0…1 theo thời lượng đã nhận dạng
    /// - onSegments: các đoạn mới (đã chốt) theo thứ tự thời gian
    static func transcribe(audioURL: URL, duration: Double, language: TranscriptLanguage,
                           onStatus: @Sendable @escaping (String) -> Void,
                           onProgress: @Sendable @escaping (Double) -> Void,
                           onSegments: @Sendable @escaping ([TranscriptSegment]) -> Void) async throws {
        let progress = ProgressBox()
        let module: any SpeechModule
        let results: AsyncThrowingStream<(AttributedString, CMTimeRange), Error>

        if let locale = await locale(for: language, in: SpeechTranscriber.supportedLocales) {
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                      attributeOptions: [.audioTimeRange])
            try await install(t, locale: locale, installed: SpeechTranscriber.installedLocales, onStatus: onStatus)
            module = t
            results = AsyncThrowingStream { c in
                let task = Task {
                    do {
                        for try await r in t.results where r.isFinal { c.yield((r.text, r.range)) }
                        c.finish()
                    } catch { c.finish(throwing: error) }
                }
                c.onTermination = { _ in task.cancel() }
            }
        } else if let locale = await locale(for: language, in: DictationTranscriber.supportedLocales) {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [], attributeOptions: [.audioTimeRange])
            try await install(t, locale: locale, installed: DictationTranscriber.installedLocales, onStatus: onStatus)
            module = t
            results = AsyncThrowingStream { c in
                let task = Task {
                    do {
                        for try await r in t.results where r.isFinal { c.yield((r.text, r.range)) }
                        c.finish()
                    } catch { c.finish(throwing: error) }
                }
                c.onTermination = { _ in task.cancel() }
            }
        } else {
            throw TranscribeError.unsupported(language.label.lowercased())
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscribeError.noFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        onStatus("Đang chép lời…")

        // Đọc kết quả song song với việc đưa âm thanh vào.
        let reader = Task {
            var segmenter = SubtitleSegmenter()
            for try await (text, range) in results {
                let segs = segmenter.segments(from: text, fallback: range)
                if let last = segs.last { progress.set(last.end) }
                else if range.end.isNumeric { progress.set(range.end.seconds) }
                if duration > 0 { onProgress(min(1, progress.get() / duration)) }
                if !segs.isEmpty { onSegments(segs) }
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
            try await feed(audioURL: audioURL, to: input, format: analyzerFormat, progress: progress)
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await reader.value
            onProgress(1)
        } catch {
            input.finish()
            reader.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func locale(for language: TranscriptLanguage, in supported: [Locale]) async -> Locale? {
        let match = supported.filter { $0.language.languageCode?.identifier == language.languageCode }
        let preferred = language == .en ? "en-US" : "vi-VN"
        return match.first { $0.identifier(.bcp47) == preferred } ?? match.first
    }

    private static func install(_ module: any SpeechModule, locale: Locale, installed: [Locale],
                                onStatus: @Sendable (String) -> Void) async throws {
        let ids = Set(installed.map { $0.identifier(.bcp47) })
        guard !ids.contains(locale.identifier(.bcp47)) else { return }
        onStatus("Đang tải mô hình nhận dạng \(locale.identifier(.bcp47)) (một lần)…")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// Đọc CAF theo khối 1 giây, đổi sang định dạng bộ nhận dạng và đưa vào luồng.
    /// Không đi trước kết quả quá 90 giây âm thanh để giới hạn bộ nhớ.
    private static func feed(audioURL: URL, to input: AsyncStream<AnalyzerInput>.Continuation,
                             format: AVAudioFormat, progress: ProgressBox) async throws {
        let file = try AVAudioFile(forReading: audioURL)
        let source = file.processingFormat
        let converter = BufferConverter(target: format)
        let chunk = AVAudioFrameCount(source.sampleRate)          // 1 giây
        var fed: Double = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            fed += Double(buffer.frameLength) / source.sampleRate
            if let converted = converter.convert(buffer) {
                input.yield(AnalyzerInput(buffer: converted))
            }
            while fed - progress.get() > 90 {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

/// Giây âm thanh đã có kết quả (đọc / ghi từ hai task khác nhau).
nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func set(_ v: Double) { lock.withLock { value = max(value, v) } }
    func get() -> Double { lock.withLock { value } }
}

// MARK: - Chia đoạn phụ đề

/// Ghép các từ (mỗi từ có audioTimeRange) thành đoạn phụ đề dễ đọc:
/// ngắt ở dấu kết câu, khi ngưng nói > 0,8 s, khi đoạn dài > 7 s (ưu tiên sau dấu phẩy) hoặc > 84 ký tự.
nonisolated struct SubtitleSegmenter {
    private var text = ""
    private var start: Double?
    private var end: Double = 0

    mutating func segments(from attributed: AttributedString, fallback: CMTimeRange) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var sawTiming = false
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            guard let range = run.audioTimeRange, range.start.isNumeric, range.end.isNumeric else {
                // dấu câu / khoảng trắng không có mốc thời gian → nối vào đoạn hiện tại
                text += piece
                if start != nil, Self.endsSentence(piece), end - (start ?? 0) >= 1.2 { flush(into: &out) }
                continue
            }
            sawTiming = true
            let s = range.start.seconds, e = range.end.seconds
            if start != nil, s - end > 0.8 { flush(into: &out) }
            if start == nil { start = s }
            text += piece
            end = max(end, e)
            let dur = end - (start ?? s)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if (Self.endsSentence(trimmed) && dur >= 1.2)
                || (dur >= 7 && (trimmed.hasSuffix(",") || trimmed.hasSuffix(";") || trimmed.hasSuffix(":")))
                || dur >= 10 || trimmed.count >= 84 {
                flush(into: &out)
            }
        }
        if !sawTiming {
            // không có mốc từng từ → cả kết quả là một đoạn
            let t = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            start = nil
            guard !t.isEmpty, fallback.start.isNumeric else { return out }
            out.append(TranscriptSegment(start: fallback.start.seconds,
                                         end: fallback.end.isNumeric ? fallback.end.seconds : fallback.start.seconds + 3,
                                         text: t))
            return out
        }
        flush(into: &out)          // mỗi kết quả chốt là một lượt nói → kết thúc đoạn
        return out
    }

    private mutating func flush(into out: inout [TranscriptSegment]) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = start, !t.isEmpty, t.contains(where: { $0.isLetter || $0.isNumber }) {
            out.append(TranscriptSegment(start: s, end: max(end, s + 0.5), text: t))
        }
        text = ""
        start = nil
    }

    private static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…".contains(last)
    }
}

// MARK: - Xuất phụ đề

enum SubtitleFormat: String, CaseIterable, Identifiable, Sendable {
    case srt, vtt, txt
    var id: String { rawValue }
}

/// Nội dung xuất: văn bản gốc, bản dịch, hoặc song ngữ (gốc trên, dịch dưới).
enum SubtitleContent: String, CaseIterable, Identifiable, Sendable {
    case source, translation, bilingual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .source: "Gốc"
        case .translation: "Bản dịch"
        case .bilingual: "Song ngữ"
        }
    }
}

nonisolated enum SubtitleWriter {
    static func lines(_ s: TranscriptSegment, _ content: SubtitleContent) -> String {
        switch content {
        case .source: s.text
        case .translation: s.translation.isEmpty ? s.text : s.translation
        case .bilingual: s.translation.isEmpty ? s.text : "\(s.text)\n\(s.translation)"
        }
    }

    static func render(_ segments: [TranscriptSegment], format: SubtitleFormat, content: SubtitleContent) -> String {
        switch format {
        case .srt:
            return segments.enumerated().map { i, s in
                "\(i + 1)\n\(time(s.start, sep: ",")) --> \(time(s.end, sep: ","))\n\(lines(s, content))\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + segments.map { s in
                "\(time(s.start, sep: ".")) --> \(time(s.end, sep: "."))\n\(lines(s, content))\n"
            }.joined(separator: "\n")
        case .txt:
            return segments.map { "[\(clock($0.start))] \(lines($0, content))" }.joined(separator: "\n")
        }
    }

    /// Văn bản liền mạch không mốc thời gian.
    static func plain(_ segments: [TranscriptSegment], content: SubtitleContent) -> String {
        switch content {
        case .bilingual: segments.map { lines($0, .bilingual) }.joined(separator: "\n\n")
        default: segments.map { lines($0, content) }.joined(separator: " ")
        }
    }

    /// 00:01:02,345
    static func time(_ t: Double, sep: String) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, sep, ms % 1000)
    }

    /// 00:01:02
    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// Tệp phụ đề tạo khi bấm chia sẻ (ShareLink).
struct SubtitleFile: Transferable, Sendable {
    let fileName: String
    let content: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { f in
            let safe = f.fileName.map { "/:\\".contains($0) ? "-" : $0 }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(safe))
            try f.content.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
