import Foundation
import UIKit
import Vision

/// Ngôn ngữ chữ trong ảnh.
enum OCRLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto, vi, en
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Tự động"
        case .vi: "Tiếng Việt"
        case .en: "Tiếng Anh"
        }
    }
}

/// Kết quả nhận dạng một ảnh / một trang.
struct OCRResult: Sendable {
    var text: String
    var lines: Int
    /// Độ tin cậy trung bình 0…1 (1 nếu lấy từ lớp văn bản PDF)
    var confidence: Float
    var fromPDFText = false
}

/// Nhận dạng chữ trên máy bằng Apple Vision (hỗ trợ tiếng Việt có dấu và tiếng Anh, không cần mạng).
nonisolated enum TextRecognizer {

    /// Các mã ngôn ngữ Vision hỗ trợ trên máy này (Apple dùng mã riêng cho tiếng Việt, vd. "vi-VT").
    static func languages(for lang: OCRLanguage) -> [String] {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        let vi = supported.first { $0.lowercased().hasPrefix("vi") }
        let en = supported.first { $0 == "en-US" } ?? supported.first { $0.hasPrefix("en") } ?? "en-US"
        switch lang {
        case .en: return [en]
        case .vi, .auto: return [vi, en].compactMap { $0 }
        }
    }

    static var supportsVietnamese: Bool { languages(for: .vi).contains { $0.lowercased().hasPrefix("vi") } }

    /// Nhận dạng một ảnh. `joinWrapped`: nối các dòng bị ngắt giữa câu thành đoạn liền.
    static func recognize(_ image: UIImage, language: OCRLanguage, joinWrapped: Bool) async throws -> OCRResult {
        let langs = languages(for: language)
        return try await Task.detached(priority: .userInitiated) {
            guard let cg = image.cgImage else { return OCRResult(text: "", lines: 0, confidence: 0) }
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = langs
            request.automaticallyDetectsLanguage = (language == .auto)
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            return layout(observations, joinWrapped: joinWrapped)
        }.value
    }

    /// Sắp xếp dòng từ trên xuống, trái sang phải; tách đoạn khi khoảng cách dọc lớn.
    private static func layout(_ obs: [VNRecognizedTextObservation], joinWrapped: Bool) -> OCRResult {
        struct Line { let text: String; let box: CGRect; let conf: Float }
        let lines: [Line] = obs.compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            let t = c.string.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Line(text: t, box: o.boundingBox, conf: c.confidence)
        }
        guard !lines.isEmpty else { return OCRResult(text: "", lines: 0, confidence: 0) }

        // Gộp các mảnh cùng hàng (bảng, nhãn ảnh) rồi sắp theo y giảm dần (Vision: gốc toạ độ ở dưới).
        var rows: [[Line]] = []
        for l in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let i = rows.indices.last, let ref = rows[i].first,
               abs(ref.box.midY - l.box.midY) < min(ref.box.height, l.box.height) * 0.5 {
                rows[i].append(l)
            } else {
                rows.append([l])
            }
        }
        let heights = lines.map(\.box.height).sorted()
        let median = heights[heights.count / 2]

        var out = ""
        var prevBottom: CGFloat?
        for row in rows {
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            let text = sorted.map(\.text).joined(separator: "  ")
            let top = sorted.map(\.box.maxY).max() ?? 0
            if let pb = prevBottom {
                let gap = pb - top
                if gap > median * 1.1 {
                    out += "\n\n"
                } else if joinWrapped, shouldJoin(previous: out, next: text) {
                    out += " "
                } else {
                    out += "\n"
                }
            }
            out += text
            prevBottom = sorted.map(\.box.minY).min() ?? 0
        }
        let conf = lines.map(\.conf).reduce(0, +) / Float(lines.count)
        return OCRResult(text: out, lines: lines.count, confidence: conf)
    }

    /// Nối dòng khi dòng trước chưa kết câu và dòng sau không bắt đầu như một mục mới.
    private static func shouldJoin(previous: String, next: String) -> Bool {
        guard let last = previous.last, let first = next.first else { return false }
        if ".:;!?…)".contains(last) { return false }
        if "•-–—*·▪●○■□0123456789".contains(first) { return false }   // gạch đầu dòng, đánh số
        return first.isLowercase || last == ","
    }
}

extension CGImagePropertyOrientation {
    nonisolated init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
