import AVFoundation
import Foundation

/// Dùng chung giữa app chính và Broadcast Upload Extension (thêm file này vào CẢ HAI target).
nonisolated enum SharedAudio {
    /// ĐỔI thành App Group bạn tạo trong Signing & Capabilities của cả hai target.
    static let appGroupID = "group.vn.quangminh.vipath.translate"

    static let sampleRate: Double = 16_000
    /// Mỗi khối ≈ 0,5 s âm thanh
    static let chunkSeconds: Double = 0.5
    /// Giữ tối đa ~5 s tồn đọng; cũ hơn thì bỏ để phụ đề không bị trễ dần.
    static let maxBacklogChunks = 10

    static var directory: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return nil }
        let dir = base.appending(path: "LiveAudio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var stateURL: URL? { directory?.appending(path: "state.txt") }

    static func writeState(_ s: String) {
        guard let url = stateURL else { return }
        try? Data(s.utf8).write(to: url, options: .atomic)
    }

    static func readState() -> String? {
        guard let url = stateURL, let d = try? Data(contentsOf: url) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Các khối "chunk-000000123.pcm" theo thứ tự ghi.
    static func chunkFiles(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("chunk-") && $0.hasSuffix(".pcm") }
            .sorted()
            .map { dir.appending(path: $0) }
    }

    static func removeAllChunks(in dir: URL) {
        for url in chunkFiles(in: dir) { try? FileManager.default.removeItem(at: url) }
    }
}

/// Đưa đúng MỘT khối vào `AVAudioConverter.convert(to:error:withInputFrom:)`.
/// Khối input có thể bị SDK đánh dấu @Sendable → không được sửa biến `var` bắt vào closure,
/// cũng không bắt trực tiếp AVAudioPCMBuffer (không Sendable); dùng hộp này thay thế.
nonisolated final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioBuffer?
    init(_ buffer: AVAudioBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let b = buffer else {
            status.pointee = .noDataNow
            return nil
        }
        buffer = nil
        status.pointee = .haveData
        return b
    }
}
