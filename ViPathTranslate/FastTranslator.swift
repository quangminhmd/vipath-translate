import Foundation
import Observation
import SwiftUI
import Translation

/// "Dịch nhanh": Apple Translation chạy trên máy (không dùng GPU, không chiếm RAM của app),
/// cho bản dịch gần như tức thì. Không nhận glossary nên chỉ dùng làm bản tạm:
/// mô hình offline (Qwen / TranslateGemma) + glossary sẽ thay bằng bản chuẩn ngay sau đó.
@MainActor
@Observable
final class FastTranslator {
    static let shared = FastTranslator()

    enum PackState: Equatable { case unknown, installed, needsDownload, unsupported }

    /// Người dùng bật / tắt chế độ Dịch nhanh.
    var enabled: Bool = UserDefaults.standard.object(forKey: "fastTranslate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "fastTranslate") }
    }
    private(set) var states: [TranslationDirection: PackState] = [:]

    private init() {
        Task { await refresh() }
    }

    static func language(_ code: String) -> Locale.Language { Locale.Language(identifier: code) }

    func state(_ d: TranslationDirection) -> PackState { states[d] ?? .unknown }

    /// Bật và gói ngôn ngữ đã có trên máy → dùng được ngay.
    func isActive(_ d: TranslationDirection) -> Bool { enabled && state(d) == .installed }

    func refresh() async {
        let availability = LanguageAvailability()
        for d in TranslationDirection.allCases {
            let status = await availability.status(from: Self.language(d.sourceCode), to: Self.language(d.targetCode))
            states[d] = switch status {
            case .installed: .installed
            case .supported: .needsDownload
            case .unsupported: .unsupported
            @unknown default: .unknown
            }
        }
    }

    /// Dịch một câu. Mỗi lần tạo phiên mới (phiên cho gói đã cài, tạo rất nhanh).
    func translate(_ text: String, _ d: TranslationDirection) async throws -> String {
        try await Self.run([text], source: Self.language(d.sourceCode), target: Self.language(d.targetCode)).first ?? ""
    }

    /// Dịch nhiều câu một lượt (nhanh hơn gọi từng câu).
    func translate(batch texts: [String], _ d: TranslationDirection) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        return try await Self.run(texts, source: Self.language(d.sourceCode), target: Self.language(d.targetCode))
    }

    /// Toàn bộ thao tác với TranslationSession nằm trong một hàm chạy ngoài MainActor
    /// (phiên và yêu cầu không Sendable → không được chuyển qua lại giữa các actor).
    @concurrent
    nonisolated private static func run(_ texts: [String], source: Locale.Language,
                                        target: Locale.Language) async throws -> [String] {
        let session = TranslationSession(installedSource: source, target: target)
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await session.translations(from: requests)
        var out = Array(repeating: "", count: texts.count)
        for r in responses {
            if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
        }
        return out
    }
}

/// Khối cài đặt "Dịch nhanh" dùng chung cho Phụ đề và Chép lời: bật/tắt, trạng thái gói ngôn ngữ, tải gói.
struct FastTranslateSettings: View {
    let directions: [TranslationDirection]
    @State private var downloadConfig: TranslationSession.Configuration?
    private var fast: FastTranslator { FastTranslator.shared }

    var body: some View {
        @Bindable var fast = self.fast
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $fast.enabled) {
                Label("Dịch nhanh (Apple Translation)", systemImage: "bolt.fill")
            }
            ForEach(directions, id: \.self) { d in
                HStack {
                    Text(d.label).font(.caption)
                    Spacer()
                    switch fast.state(d) {
                    case .installed:
                        Label("Sẵn sàng · offline", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .needsDownload:
                        Button("Tải gói ngôn ngữ") {
                            downloadConfig = TranslationSession.Configuration(
                                source: FastTranslator.language(d.sourceCode),
                                target: FastTranslator.language(d.targetCode))
                        }
                        .font(.caption.bold())
                    case .unsupported:
                        Text("Không hỗ trợ").font(.caption).foregroundStyle(.secondary)
                    case .unknown:
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            Text("Hiện bản dịch tức thì (⚡); mô hình offline + glossary thay bằng bản chuẩn vài giây sau. Nếu chưa nạp mô hình, bản ⚡ là bản cuối và vẫn được kiểm tra thuật ngữ.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .translationTask(downloadConfig, action: Self.prepare)
        .task { await fast.refresh() }
    }

    /// iOS hỏi người dùng tải gói ngôn ngữ (một lần), sau đó dịch offline.
    nonisolated private static func prepare(_ session: TranslationSession) async {
        try? await session.prepareTranslation()
        await FastTranslator.shared.refresh()
    }
}

/// Dòng trạng thái ngắn "⚡ Dịch nhanh: …" để luôn thấy chế độ này đang bật hay cần tải gói.
struct FastStatusLabel: View {
    let direction: TranslationDirection
    private var fast: FastTranslator { FastTranslator.shared }

    var body: some View {
        let (text, color): (String, Color) = {
            if !fast.enabled { return ("tắt", .secondary) }
            switch fast.state(direction) {
            case .installed: return ("bật · \(direction.label)", .green)
            case .needsDownload: return ("cần tải gói \(direction.label)", .orange)
            case .unsupported: return ("không hỗ trợ", .secondary)
            case .unknown: return ("đang kiểm tra…", .secondary)
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").foregroundStyle(.yellow)
            Text("Dịch nhanh (Apple):").font(.subheadline)
            Text(text).font(.subheadline.bold()).foregroundStyle(color)
        }
        .task { await fast.refresh() }
    }
}
