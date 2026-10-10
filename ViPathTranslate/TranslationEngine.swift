import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

/// Nạp mô hình MLX và dịch từng đoạn. Viết cho mlx-swift-lm 2.31.x
/// (bản đầu tiên hỗ trợ Qwen3.5: model type `qwen3_5` / `qwen3_5_text`).
actor TranslationEngine {
    private var container: ModelContainer?
    private(set) var loaded: ModelChoice?

    struct Stats: Sendable {
        var tokensPerSecond: Double
        var promptTokens: Int
        var generatedTokens: Int
        var promptSeconds: Double = 0
        var text: String = ""
    }

    /// MLX chỉ khởi tạo Metal khi nạp mô hình lần đầu (không làm trong init):
    /// iOS Simulator không có GPU Metal mà MLX cần, gọi sớm sẽ làm app crash ngay khi mở.
    private var memoryConfigured = false

    func load(_ choice: ModelChoice,
              progress: @Sendable @escaping (Double) -> Void) async throws {
        #if targetEnvironment(simulator)
        throw EngineError.simulator
        #else
        if loaded == choice, container != nil { return }
        if !memoryConfigured {
            // Giữ bộ nhớ đệm GPU nhỏ để chừa RAM cho KV cache, tránh bị iOS đóng app.
            Memory.cacheLimit = 64 * 1024 * 1024
            memoryConfigured = true
        }
        container = nil
        loaded = nil
        Memory.clearCache()

        // Kiểm tra RAM còn trống: mô hình 9B/12B sát giới hạn của iPhone 12 GB,
        // báo lỗi rõ ràng thay vì để iOS đóng app giữa chừng.
        var available = UInt64(os_proc_available_memory())
        if available > 0, available < choice.requiredFreeBytes {
            // Whisper (PhoWhisper / turbo) đang giữ ~1–2 GB → tự đóng để nhường RAM cho mô hình dịch;
            // tab Đại thể / Chép lời / Phụ đề sẽ tự nạp lại khi bấm mic.
            if WhisperRunner.shared.hasLoadedModel { WhisperRunner.shared.unload() }
            Memory.clearCache()
            try? await Task.sleep(for: .milliseconds(500))   // chờ iOS thu hồi bộ nhớ vừa trả
            available = UInt64(os_proc_available_memory())
        }
        if available > 0, available < choice.requiredFreeBytes {
            throw EngineError.insufficientMemory(needGB: Double(choice.requiredFreeBytes) / 1_073_741_824,
                                                 freeGB: Double(available) / 1_073_741_824)
        }
        if choice.needsCustomArchitecture {
            await HunyuanRegistration.register()
        }

        let configuration: ModelConfiguration
        if let dir = Bundle.main.url(forResource: choice.bundleFolder, withExtension: nil) {
            configuration = ModelConfiguration(directory: dir)   // đóng gói sẵn → offline ngay
            progress(1)
        } else {
            configuration = ModelConfiguration(id: choice.rawValue) // tải 1 lần, cache trong app
        }
        container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { p in
            progress(p.fractionCompleted)
        }
        loaded = choice
        #endif
    }

    /// Dịch một đoạn; `onText` nhận toàn bộ văn bản đã sinh (đã làm sạch) sau mỗi chunk.
    func translate(_ text: String,
                   hits: [GlossaryHit],
                   styleGuide: String,
                   direction: TranslationDirection = .enToVi,
                   onText: @Sendable @escaping (String) -> Void) async throws -> Stats {
        guard let container, let model = loaded else { throw EngineError.notLoaded }

        // Đầu ra ≈ 1,5–2× số token đầu vào khi dịch EN→VI.
        // Số ký tự nguồn luôn ≥ số token đích nên dùng làm trần là đủ rộng.
        let maxTokens = min(2048, max(256, text.count))

        let family = model.family
        let system = PromptBuilder.qwenSystem(direction: direction, styleGuide: styleGuide)
        let user = PromptBuilder.qwenUser(text: text, hits: hits, direction: direction)
        let raw = family == .hunyuanMT
            ? PromptBuilder.hunyuanRaw(text: text, hits: hits, direction: direction)
            : PromptBuilder.translateGemmaRaw(text: text, hits: hits, direction: direction)

        return try await container.perform { context in
            let parameters = GenerateParameters(maxTokens: maxTokens,
                                                temperature: 0.0,      // dịch: tất định
                                                repetitionPenalty: 1.05)
            let input: LMInput
            switch family {
            case .qwen:
                let userInput = UserInput(
                    chat: [.system(system), .user(user)],
                    additionalContext: ["enable_thinking": false]   // tắt suy luận để dịch nhanh
                )
                input = try await context.processor.prepare(input: userInput)
            case .translateGemma:
                let tokens = context.tokenizer.encode(text: raw)
                input = LMInput(tokens: MLXArray(tokens.map(Int32.init)))
            case .hunyuanMT:
                // Prompt đã có sẵn <|startoftext|> → không để tokenizer thêm BOS lần nữa.
                let tokens = context.tokenizer.encode(text: raw, addSpecialTokens: false)
                input = LMInput(tokens: MLXArray(tokens.map(Int32.init)))
            }

            var output = ""
            var lastEmit = Date.distantPast      // cập nhật giao diện tối đa ~20 lần/giây
            var stats = Stats(tokensPerSecond: 0, promptTokens: 0, generatedTokens: 0)
            // Tự đo thời gian: TranslateGemma kết thúc bằng "<end_of_turn>" dạng văn bản → vòng lặp dừng sớm
            // trước khi MLX gửi `.info`, nên phải tự tính tok/s cho trường hợp này.
            let began = Date()
            var firstChunkAt: Date?
            let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            generation: for await item in stream {
                if Task.isCancelled { break generation }
                switch item {
                case .chunk(let s):
                    if firstChunkAt == nil { firstChunkAt = Date() }
                    output += s
                    let now = Date()
                    if now.timeIntervalSince(lastEmit) >= 0.05 {
                        lastEmit = now
                        onText(PromptBuilder.clean(output))
                    }
                    if PromptBuilder.stopMarkers.contains(where: { output.contains($0) }) {
                        break generation
                    }
                case .info(let info):
                    stats = Stats(tokensPerSecond: info.tokensPerSecond,
                                  promptTokens: info.promptTokenCount,
                                  generatedTokens: info.generationTokenCount,
                                  promptSeconds: info.promptTime)
                default:
                    break
                }
            }
            stats.text = PromptBuilder.clean(output)
            if stats.tokensPerSecond <= 0, let first = firstChunkAt {
                let generated = context.tokenizer.encode(text: output).count
                let genSeconds = max(Date().timeIntervalSince(first), 0.001)
                stats.generatedTokens = generated
                stats.promptTokens = input.text.tokens.size
                stats.promptSeconds = first.timeIntervalSince(began)
                stats.tokensPerSecond = Double(max(generated - 1, 1)) / genSeconds
            }
            return stats
        }
    }

    /// Chạy thử 1 lượt rất ngắn ngay sau khi nạp: Metal biên dịch kernel và cấp phát bộ đệm ở đây,
    /// nên lượt dịch thật đầu tiên không bị chậm. Trả về số giây.
    func warmUp() async -> Double {
        guard let container else { return 0 }
        let t0 = Date()
        _ = try? await container.perform { context in
            let tokens = context.tokenizer.encode(text: "Hello, world.")
            let input = LMInput(tokens: MLXArray(tokens.map(Int32.init)))
            let parameters = GenerateParameters(maxTokens: 2, temperature: 0.0)
            let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            for await _ in stream { if Task.isCancelled { break } }
            return 0
        }
        return Date().timeIntervalSince(t0)
    }

    func unload() {
        container = nil
        loaded = nil
        if memoryConfigured { Memory.clearCache() }
    }

    enum EngineError: LocalizedError {
        case notLoaded
        case simulator
        case insufficientMemory(needGB: Double, freeGB: Double)
        var errorDescription: String? {
            switch self {
            case .insufficientMemory(let need, let free):
                String(format: "Không đủ RAM: mô hình cần ≈%.1f GB nhưng app chỉ còn %.1f GB. Đã tự đóng Whisper nhưng vẫn thiếu — hãy đóng các app khác (vuốt tắt hẳn) rồi nạp lại, hoặc chọn mô hình nhỏ hơn.", need, free)
            case .notLoaded: "Chưa nạp mô hình."
            case .simulator: "MLX không chạy trên iOS Simulator — hãy chạy app trên iPhone thật để dịch."
            }
        }
    }
}
