import Foundation
import Network
import Observation

/// Mô hình Claude dùng qua API (chỉ khi người dùng bật kết nối và có Internet).
enum ClaudeModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }
    var shortName: String {
        switch self {
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        case .opus: "Claude Opus 5.5"
        }
    }
    var summary: String {
        switch self {
        case .sonnet: "Cân bằng chất lượng / tốc độ — khuyên dùng cho kết luận, vi thể, bài báo."
        case .haiku: "Nhanh và rẻ nhất — đủ cho slide, đoạn ngắn."
        case .opus: "Chất lượng cao nhất cho câu phức, thuật ngữ hiếm; chậm và đắt hơn."
        }
    }
}

/// Đề xuất thuật ngữ Claude trả về (vòng học glossary).
struct ClaudeTermSuggestion: Codable, Hashable, Sendable {
    var english: String
    var vietnamese: String
    var note: String?
}

struct ClaudeTranslation: Sendable {
    let text: String
    let suggestions: [ClaudeTermSuggestion]
    let inputTokens: Int
    let outputTokens: Int
    let seconds: Double
    let model: ClaudeModel
}

enum ClaudeError: LocalizedError {
    case disconnected, offline, noKey, truncated, badResponse(String), http(Int, String), transport(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: "Claude đang ngắt kết nối. Bật kết nối ở nút đám mây trên thanh công cụ."
        case .offline: "Không có Internet. Bản dịch offline vẫn dùng bình thường."
        case .noKey: "Chưa nhập API key. Vào Cài đặt Claude để nhập key (lưu trong Keychain)."
        case .truncated: "Văn bản quá dài, Claude trả lời bị cắt. Hãy chia nhỏ văn bản."
        case .badResponse(let s): "Phản hồi không hợp lệ từ Claude: \(s)"
        case .http(let code, let msg):
            switch code {
            case 401: "API key không hợp lệ hoặc đã bị thu hồi (401)."
            case 403: "Key không có quyền dùng mô hình này (403). \(msg)"
            case 404: "Không tìm thấy mô hình (404). Thử chọn mô hình khác. \(msg)"
            case 413: "Văn bản quá lớn để gửi (413)."
            case 429: "Vượt giới hạn tốc độ / hạn mức (429). Đợi một lát rồi thử lại."
            case 529: "Claude đang quá tải (529). Thử lại sau ít phút."
            default: "Lỗi Claude API (\(code)): \(msg)"
            }
        case .transport(let s): "Lỗi mạng: \(s)"
        }
    }
}

/// Kết nối Claude Messages API.
/// - Key do người dùng tự nhập, chỉ lưu trong Keychain; không nhúng trong app.
/// - Chỉ gửi văn bản ĐÃ che thông tin định danh (xem PHIRedactor + RedactionConfirmView).
/// - Nút kết nối / ngắt kết nối: khi ngắt, app không gửi bất kỳ yêu cầu mạng nào tới Claude.
@MainActor
@Observable
final class ClaudeService {
    static let shared = ClaudeService()

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let modelsEndpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    private static let apiVersion = "2023-06-01"
    private static let keyAccount = "anthropic-api-key"
    /// Văn bản dài hơn ngưỡng này được chia nhiều lượt gọi (theo đoạn).
    private static let chunkChars = 9_000

    /// Người dùng bật / tắt kết nối Claude.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "claudeEnabled") }
    }
    var model: ClaudeModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "claudeModel") }
    }
    private(set) var networkAvailable = true
    private(set) var hasKey: Bool
    private(set) var isBusy = false
    private(set) var progressText = ""
    /// Tổng token đã dùng trong phiên mở app (để ước lượng chi phí).
    private(set) var sessionInputTokens = 0
    private(set) var sessionOutputTokens = 0

    var isReady: Bool { isEnabled && networkAvailable && hasKey }

    var statusText: String {
        if !isEnabled { return "Đã ngắt kết nối" }
        if !hasKey { return "Chưa có API key" }
        if !networkAvailable { return "Không có Internet" }
        return "Đã kết nối · \(model.shortName)"
    }

    private let monitor = NWPathMonitor()
    private let session: URLSession

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "claudeEnabled")
        model = UserDefaults.standard.string(forKey: "claudeModel").flatMap(ClaudeModel.init) ?? .sonnet
        hasKey = KeychainHelper.read(account: Self.keyAccount) != nil
        let config = URLSessionConfiguration.ephemeral          // không lưu cache / cookie văn bản gửi đi
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.urlCache = nil
        session = URLSession(configuration: config)
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.networkAvailable = ok }
        }
        monitor.start(queue: DispatchQueue(label: "vn.quangminh.vipath.netmonitor"))
    }

    // MARK: API key

    func saveKey(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return false }
        let ok = KeychainHelper.save(k, account: Self.keyAccount)
        hasKey = KeychainHelper.read(account: Self.keyAccount) != nil
        return ok
    }

    func deleteKey() {
        KeychainHelper.delete(account: Self.keyAccount)
        hasKey = false
    }

    /// 4 ký tự cuối để người dùng nhận ra key đang lưu (không hiển thị toàn bộ).
    var keyHint: String? {
        guard let k = KeychainHelper.read(account: Self.keyAccount), k.count > 8 else { return nil }
        return "…" + k.suffix(4)
    }

    /// Kiểm tra key bằng GET /v1/models (không tốn token).
    func verifyKey() async throws {
        guard networkAvailable else { throw ClaudeError.offline }
        guard let key = KeychainHelper.read(account: Self.keyAccount) else { throw ClaudeError.noKey }
        var req = URLRequest(url: Self.modelsEndpoint)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, resp) = try await perform(req)
        try Self.check(resp, data)
    }

    // MARK: Dịch

    /// `source` và `draft` PHẢI là văn bản đã che định danh.
    func translate(source: String, draft: String?, direction: TranslationDirection,
                   hits: [GlossaryHit]) async throws -> ClaudeTranslation {
        guard isEnabled else { throw ClaudeError.disconnected }
        guard networkAvailable else { throw ClaudeError.offline }
        guard let key = KeychainHelper.read(account: Self.keyAccount) else { throw ClaudeError.noKey }

        isBusy = true
        defer { isBusy = false; progressText = "" }
        let start = Date()

        let chunks = Self.chunk(source)
        // Văn bản dài: chia lượt, không gửi kèm bản nháp (không căn được bản nháp theo từng phần).
        let useDraft = chunks.count == 1 ? draft : nil
        var texts: [String] = []
        var suggestions: [ClaudeTermSuggestion] = []
        var inTok = 0, outTok = 0
        for (i, part) in chunks.enumerated() {
            try Task.checkCancellation()
            progressText = chunks.count > 1 ? "Phần \(i + 1)/\(chunks.count)" : ""
            let partHits = hits.filter { part.localizedCaseInsensitiveContains($0.matched) }
            let body = Self.requestBody(model: model, source: part, draft: useDraft,
                                        direction: direction, hits: partHits)
            var req = URLRequest(url: Self.endpoint)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = body
            let (data, resp) = try await perform(req)
            try Self.check(resp, data)
            let r = try Self.parse(data)
            texts.append(r.text)
            suggestions += r.suggestions
            inTok += r.inTok
            outTok += r.outTok
            sessionInputTokens += r.inTok
            sessionOutputTokens += r.outTok
        }
        var seen = Set<String>()
        suggestions = suggestions.filter { seen.insert($0.english.lowercased()).inserted }
        return ClaudeTranslation(text: texts.joined(separator: "\n\n"), suggestions: suggestions,
                                 inputTokens: inTok, outputTokens: outTok,
                                 seconds: Date().timeIntervalSince(start), model: model)
    }

    // MARK: Nội bộ

    private func perform(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            if e.code == .notConnectedToInternet { throw ClaudeError.offline }
            throw ClaudeError.transport(e.localizedDescription)
        }
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw ClaudeError.badResponse("không phải HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            var msg = String(data: data, encoding: .utf8) ?? ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any], let m = err["message"] as? String {
                msg = m
            }
            throw ClaudeError.http(http.statusCode, msg)
        }
    }

    private struct Parsed { let text: String; let suggestions: [ClaudeTermSuggestion]; let inTok: Int; let outTok: Int }

    private static func parse(_ data: Data) throws -> Parsed {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw ClaudeError.badResponse("thiếu content")
        }
        if (obj["stop_reason"] as? String) == "max_tokens" { throw ClaudeError.truncated }
        let usage = obj["usage"] as? [String: Any]
        let inTok = usage?["input_tokens"] as? Int ?? 0
        let outTok = usage?["output_tokens"] as? Int ?? 0
        guard let tool = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = tool["input"] as? [String: Any],
              let text = input["translation"] as? String else {
            // dự phòng: mô hình trả lời văn bản thường
            let plain = content.compactMap { $0["text"] as? String }.joined()
            guard !plain.isEmpty else { throw ClaudeError.badResponse("không có bản dịch") }
            return Parsed(text: plain, suggestions: [], inTok: inTok, outTok: outTok)
        }
        let raw = input["term_suggestions"] as? [[String: Any]] ?? []
        let suggestions = raw.compactMap { d -> ClaudeTermSuggestion? in
            guard let en = d["english"] as? String, let vi = d["vietnamese"] as? String else { return nil }
            return ClaudeTermSuggestion(english: en.trimmingCharacters(in: .whitespaces),
                                        vietnamese: vi.trimmingCharacters(in: .whitespaces),
                                        note: d["note"] as? String)
        }
        return Parsed(text: text, suggestions: suggestions, inTok: inTok, outTok: outTok)
    }

    /// Chia văn bản dài theo đoạn (giữ nguyên ranh giới dòng trống).
    static func chunk(_ text: String) -> [String] {
        guard text.count > chunkChars else { return [text] }
        var out: [String] = [], cur = ""
        for para in text.components(separatedBy: "\n") {
            if cur.count + para.count + 1 > chunkChars, !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
            cur += (cur.isEmpty ? "" : "\n") + para
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static let systemPrompt = """
    You are an expert medical translator specialising in anatomical pathology (surgical pathology, \
    cytopathology, immunohistochemistry, molecular pathology), translating between English and Vietnamese \
    for Vietnamese pathologists. Typical content: gross descriptions, microscopic descriptions, \
    diagnoses/conclusions, journal articles, textbooks and teaching slides.

    Rules:
    1. Translate faithfully and completely. Do not summarise, add, explain or omit anything. Keep the \
    original structure: line breaks, headings, bullet points, numbering, tables.
    2. English → Vietnamese: use standard Vietnamese pathology terminology as in Vietnamese medical \
    textbooks and pathology reports; natural, concise report style. Vietnamese → English: use standard \
    English terminology (WHO Classification of Tumours, CAP protocols).
    3. Glossary terms supplied by the user are mandatory unless clearly wrong in context.
    4. Keep unchanged: gene and protein names, IHC markers (CD20, Ki-67), HGVS variants (p.R132H), \
    TNM staging (pT1aN1b), numbers, units, ICD-O codes, drug names, established Latin/English eponyms.
    5. The text is de-identified with placeholders such as [TÊN_1], [PID_1], [MÃ_BP_1], [NGÀY_SINH_1]. \
    Copy every placeholder exactly as written, in the matching position. Never translate, change, \
    merge or guess them.
    6. If an offline draft translation is supplied, use it as a starting point: fix terminology, \
    meaning and grammar errors, improve fluency, keep the parts that are already correct.
    7. term_suggestions: list rare or specialised pathology/medical terms (not common words, numbers, \
    gene symbols or placeholders) that are missing from the supplied glossary or that the offline draft \
    translated wrongly. Give the English term in canonical dictionary form (singular, lower case unless \
    an abbreviation or proper noun) and its standard Vietnamese equivalent. note: one short Vietnamese \
    sentence explaining why (e.g. what the draft got wrong). At most 15 items; an empty list is fine.
    Always answer by calling the submit_translation tool.
    """

    private static func requestBody(model: ClaudeModel, source: String, draft: String?,
                                    direction: TranslationDirection, hits: [GlossaryHit]) -> Data {
        var user = "Direction: \(direction == .enToVi ? "English → Vietnamese" : "Vietnamese → English")\n"
        if !hits.isEmpty {
            user += "\nGlossary (mandatory):\n"
            for h in hits.prefix(120) {
                user += "- \(h.matched) → \(h.translations.joined(separator: " | "))\n"
            }
        }
        user += "\n<source>\n\(source)\n</source>\n"
        if let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "\n<offline_draft>\n\(draft)\n</offline_draft>\n"
        }
        let maxTokens = min(32_000, max(2_048, source.count * 2))
        let tool: [String: Any] = [
            "name": "submit_translation",
            "description": "Return the final translation and glossary term suggestions.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "translation": [
                        "type": "string",
                        "description": "Complete translation with all placeholders preserved.",
                    ],
                    "term_suggestions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "english": ["type": "string"],
                                "vietnamese": ["type": "string"],
                                "note": ["type": "string"],
                            ],
                            "required": ["english", "vietnamese"],
                        ],
                    ],
                ],
                "required": ["translation", "term_suggestions"],
            ],
        ]
        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "submit_translation"],
            "messages": [["role": "user", "content": user]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}
