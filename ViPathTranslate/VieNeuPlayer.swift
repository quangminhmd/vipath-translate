import AVFoundation
import Foundation

/// Phát lần lượt các đoạn âm thanh VieNeu (PCM float, xen kẽ kênh) qua AVAudioEngine.
/// `schedule` không chờ: có thể tổng hợp câu tiếp theo trong lúc câu trước đang phát.
@MainActor
final class VieNeuPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        engine.attach(node)
    }

    /// Bật phiên âm thanh phát ra loa/tai nghe kể cả khi iPhone gạt sang chế độ im lặng.
    /// Giữ nguyên nếu phụ đề đang dùng playAndRecord (micro + đọc bản dịch).
    /// Chạy ngoài luồng giao diện: setCategory/setActive có thể chặn vài trăm ms.
    nonisolated static func preparePlaybackSession() async {
        await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord && session.category != .playback {
                try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            try? session.setActive(true)
        }.value
    }

    func schedule(_ audio: VieNeuAudio) throws {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate),
                                      channels: AVAudioChannelCount(audio.channels)) else { return }
        if format != fmt {
            node.stop()
            engine.stop()
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            format = fmt
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        let frames = AVAudioFrameCount(audio.frames)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              let channelData = buffer.floatChannelData else { return }
        buffer.frameLength = frames
        let ch = audio.channels
        audio.samples.withUnsafeBufferPointer { src in
            for c in 0..<ch {
                let dst = channelData[c]
                for i in 0..<Int(frames) { dst[i] = src[i * ch + c] }
            }
        }
        pending += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finishedOne() }
        }
        if !node.isPlaying { node.play() }
    }

    /// Chờ đến khi mọi đoạn đã lên lịch phát xong.
    func waitUntilDone() async {
        guard pending > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func stop() {
        node.stop()
        pending = 0
        resumeWaiters()
    }

    private func finishedOne() {
        pending = max(0, pending - 1)
        if pending == 0 { resumeWaiters() }
    }

    private func resumeWaiters() {
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }
}
