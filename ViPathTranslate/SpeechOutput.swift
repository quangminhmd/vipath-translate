import AVFoundation
import Foundation
import Observation

/// Đọc bản dịch tiếng Việt, offline. Hai giọng:
///   • Giọng iOS (AVSpeechSynthesizer) — luôn có sẵn.
///   • VieNeu-TTS — khi đã chạy Tools/build_vieneu_ios.sh và bật trong "Giọng đọc".
/// Mọi chỗ trong app chỉ gọi `speak` / `stop`; đổi giọng không phải sửa chỗ gọi.
@MainActor
@Observable
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechOutput()

    private(set) var isSpeaking = false
    /// 0…1, mặc định hơi chậm hơn giọng hệ thống cho thuật ngữ y khoa dễ nghe.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.95

    /// Dùng VieNeu thay giọng iOS (lưu lại giữa các lần mở app).
    var useVieNeu: Bool = UserDefaults.standard.bool(forKey: "useVieNeu") {
        didSet { UserDefaults.standard.set(useVieNeu, forKey: "useVieNeu") }
    }
    /// Số luồng CPU cho VieNeu (A20 Pro: 2 lõi hiệu năng + 4 lõi tiết kiệm điện).
    var vieneuThreads: Int = max(2, UserDefaults.standard.integer(forKey: "vieneuThreads")) {
        didSet { UserDefaults.standard.set(vieneuThreads, forKey: "vieneuThreads") }
    }
    /// Nhiệt độ lấy mẫu của VieNeu: thấp = đọc chắc, đều; cao = tự nhiên hơn nhưng dễ nuốt chữ.
    var vieneuTemperature: Double = UserDefaults.standard.object(forKey: "vieneuTemperature") as? Double ?? 0.6 {
        didSet { UserDefaults.standard.set(vieneuTemperature, forKey: "vieneuTemperature") }
    }
    private(set) var lastVieNeuError: String?

    private let synth = AVSpeechSynthesizer()
    private let player = VieNeuPlayer()
    private var vieneuQueue: [String] = []
    private var vieneuTask: Task<Void, Never>?
    private var vieneuRun = 0

    private override init() {
        super.init()
        synth.delegate = self
        Task { await VieNeuPlayer.preparePlaybackSession() }
        if UserDefaults.standard.object(forKey: "vieneuThreads") == nil { vieneuThreads = 4 }
    }

    /// Có giọng tiếng Việt của iOS trên máy chưa (Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt).
    var hasVietnameseVoice: Bool { Self.bestVoice != nil }

    /// VieNeu đã được build vào app và đủ tệp mô hình.
    var vieneuAvailable: Bool { VieNeuEngine.isCompiledIn && VieNeuResources.missing.isEmpty }

    private static var bestVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("vi") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// `enqueue = true`: đọc nối tiếp (phụ đề); `false`: dừng câu đang đọc rồi đọc câu mới.
    func speak(_ text: String, enqueue: Bool = false) {
        let t = Self.prepare(text)
        guard !t.isEmpty else { return }
        if useVieNeu && vieneuAvailable {
            if !enqueue { stop() }
            vieneuQueue.append(t)
            runVieNeuQueue()
        } else {
            speakSystem(t, enqueue: enqueue)
        }
    }

    /// Đọc tiếng Anh (phụ đề chiều Việt → Anh) bằng giọng iOS tốt nhất có trên máy.
    func speakEnglish(_ text: String, enqueue: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task { await VieNeuPlayer.preparePlaybackSession() }
        if !enqueue { stop() }
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0) < ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0) }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = rate
        u.postUtteranceDelay = 0.15
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        vieneuQueue.removeAll()
        vieneuTask?.cancel()
        vieneuTask = nil
        vieneuRun += 1
        player.stop()
        isSpeaking = false
    }

    private func speakSystem(_ t: String, enqueue: Bool) {
        Task { await VieNeuPlayer.preparePlaybackSession() }
        if !enqueue { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: GPBSpeechNormalizer.normalize(t))
        u.voice = Self.bestVoice ?? AVSpeechSynthesisVoice(language: "vi-VN")
        u.rate = rate
        u.postUtteranceDelay = 0.15
        synth.speak(u)
    }

    /// Tổng hợp từng câu rồi lên lịch phát ngay; câu sau được tổng hợp trong lúc câu trước đang phát.
    private func runVieNeuQueue() {
        guard vieneuTask == nil else { return }
        vieneuRun += 1
        let run = vieneuRun
        isSpeaking = true
        vieneuTask = Task { @MainActor in
            let engine = VieNeuEngine.shared
            await VieNeuPlayer.preparePlaybackSession()
            queue: while !vieneuQueue.isEmpty, !Task.isCancelled {
                let text = vieneuQueue.removeFirst()
                do {
                    try await engine.load(threads: vieneuThreads)
                    for sentence in SentenceSplitter.split(text) where sentence.contains(where: \.isLetter) {
                        if Task.isCancelled { break queue }
                        let (audio, _) = try await engine.synthesize(sentence, temperature: vieneuTemperature)
                        if Task.isCancelled { break queue }
                        try player.schedule(audio)
                    }
                    lastVieNeuError = nil
                } catch {
                    // VieNeu lỗi → đọc tạm bằng giọng iOS để không mất nội dung
                    lastVieNeuError = error.localizedDescription
                    speakSystem(text, enqueue: true)
                }
            }
            if !Task.isCancelled { await player.waitUntilDone() }
            // stop() có thể đã khởi động một lượt mới — chỉ dọn nếu vẫn là lượt này
            if run == vieneuRun {
                vieneuTask = nil
                isSpeaking = synth.isSpeaking
            }
        }
    }

    /// Bỏ ký hiệu cảnh báo / ngoặc chú thích không cần đọc.
    static func prepare(_ text: String) -> String {
        text.replacingOccurrences(of: "⚠︎", with: "")
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synth.isSpeaking || self.vieneuTask != nil }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synth.isSpeaking || self.vieneuTask != nil }
    }
}
