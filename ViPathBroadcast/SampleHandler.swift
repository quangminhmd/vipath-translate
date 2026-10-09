import AVFoundation
import CoreMedia
import ReplayKit

/// Broadcast Upload Extension: khi người dùng bắt đầu "Phát sóng màn hình" và chọn ViPath,
/// extension nhận âm thanh của app đang phát (Zoom, Teams, YouTube…), đổi sang 16 kHz mono Int16
/// rồi ghi từng khối 0,5 s vào App Group cho app chính nhận dạng + dịch.
/// Extension bị giới hạn ~50 MB RAM nên KHÔNG chạy nhận dạng hay LLM ở đây — chỉ chuyển âm thanh.
nonisolated final class SampleHandler: RPBroadcastSampleHandler {
    private let writer = ChunkWriter()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        writer.begin()
        SharedAudio.writeState("live")
    }

    override func broadcastPaused() { SharedAudio.writeState("paused") }
    override func broadcastResumed() { SharedAudio.writeState("live") }

    override func broadcastFinished() {
        writer.flush()
        SharedAudio.writeState("stopped")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        // .audioApp = âm thanh của app khác (giọng người nói trong cuộc họp).
        // Không lấy .audioMic để không dịch giọng của chính mình.
        guard type == .audioApp else { return }
        writer.append(sampleBuffer)
    }
}

nonisolated final class ChunkWriter: @unchecked Sendable {
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: SharedAudio.sampleRate,
                                       channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pending = Data()
    private var sequence = 0
    private let queue = DispatchQueue(label: "vipath.chunkwriter")
    private var bytesPerChunk: Int { Int(SharedAudio.sampleRate * SharedAudio.chunkSeconds) * 2 }

    func begin() {
        queue.sync {
            pending.removeAll()
            sequence = 0
            if let dir = SharedAudio.directory { SharedAudio.removeAllChunks(in: dir) }
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        // sync: nhẹ, giữ thứ tự, và không phải chuyển AVAudioPCMBuffer (không Sendable) sang closure thoát
        queue.sync {
            guard let out = convert(pcm), let ptr = out.int16ChannelData?[0] else { return }
            pending.append(Data(bytes: ptr, count: Int(out.frameLength) * 2))
            while pending.count >= bytesPerChunk {
                write(pending.prefix(bytesPerChunk))
                pending.removeFirst(bytesPerChunk)
            }
        }
    }

    func flush() {
        queue.sync {
            if !pending.isEmpty { write(pending) }
            pending.removeAll()
        }
    }

    private func write(_ data: Data) {
        guard let dir = SharedAudio.directory else { return }
        sequence += 1
        let name = String(format: "chunk-%09ld.pcm", sequence)
        let tmp = dir.appending(path: "." + name)
        do {
            try data.write(to: tmp)
            try FileManager.default.moveItem(at: tmp, to: dir.appending(path: name))   // ghi nguyên tử
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true   // stereo → mono: trộn hai kênh thay vì chỉ lấy kênh trái
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let input = OneShotInput(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { @Sendable (_, inputStatus) in
            input.next(inputStatus)
        }
        return (status == .error || error != nil) ? nil : out
    }

    /// CMSampleBuffer (ReplayKit) → AVAudioPCMBuffer. Âm thanh app của ReplayKit thường là
    /// Int16 big-endian; AVAudioPCMBuffer cần native-endian nên đảo byte tại đây.
    private static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var asbd = asbdPtr.pointee
        let bigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        asbd.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }

        if bigEndian {
            let width = Int(asbd.mBitsPerChannel / 8)
            for ab in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                guard let p = ab.mData else { continue }
                let n = Int(ab.mDataByteSize) / max(width, 1)
                switch width {
                case 2:
                    let s = p.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<n { s[i] = s[i].byteSwapped }
                case 4:
                    let s = p.assumingMemoryBound(to: UInt32.self)
                    for i in 0..<n { s[i] = s[i].byteSwapped }
                default:
                    break
                }
            }
        }
        return buffer
    }
}
