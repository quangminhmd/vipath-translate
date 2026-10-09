import Foundation
#if canImport(AudioCpp) && canImport(SeaG2P)
import AudioCpp
import SeaG2P
#endif

/// Tài nguyên VieNeu do Tools/build_vieneu_ios.sh tải về ViPathTranslate/Resources/VieNeu.
enum VieNeuResources {
    private static func url(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "VieNeu")
    }
    static var model: URL? { url("vieneu-v3-turbo-q8_0", "gguf") }
    static var dictionary: URL? { url("sea_g2p", "bin") }
    static var referenceCodes: URL? { url("vieneu_ref_codes", "txt") }
    static var speakerEmbedding: URL? { url("vieneu_speaker.emb", "txt") }

    static var missing: [String] {
        var m: [String] = []
        if model == nil { m.append("vieneu-v3-turbo-q8_0.gguf") }
        if dictionary == nil { m.append("sea_g2p.bin") }
        if referenceCodes == nil { m.append("vieneu_ref_codes.txt") }
        if speakerEmbedding == nil { m.append("vieneu_speaker.emb.txt") }
        return m
    }
}

struct VieNeuAudio: Sendable {
    let samples: [Float]        // xen kẽ theo kênh (interleaved)
    let sampleRate: Int
    let channels: Int
    var frames: Int { samples.count / max(channels, 1) }
    var duration: Double { Double(frames) / Double(max(sampleRate, 1)) }
}

struct VieNeuTiming: Sendable {
    var g2p: Double = 0          // giây
    var synthesis: Double = 0    // giây
    var audio: Double = 0        // độ dài âm thanh, giây
    /// Real-time factor: < 1 nghĩa là tổng hợp nhanh hơn thời gian nói.
    var rtf: Double { synthesis / max(audio, 0.001) }
}

/// VieNeu-TTS v3 Turbo chạy trên CPU qua audio.cpp (C API) + sea-g2p (Rust, C ABI).
/// Văn bản → GPBSpeechNormalizer → sea-g2p (âm vị) → audio.cpp → PCM 48 kHz.
/// Không dùng GPU để không tranh với mô hình dịch MLX.
actor VieNeuEngine {
    static let shared = VieNeuEngine()

    nonisolated static var isCompiledIn: Bool {
        #if canImport(AudioCpp) && canImport(SeaG2P)
        return true
        #else
        return false
        #endif
    }

    enum VNError: LocalizedError {
        case notBuilt, missingResources([String]), failed(String)
        var errorDescription: String? {
            switch self {
            case .notBuilt:
                "Chưa build VieNeu. Chạy Tools/build_vieneu_ios.sh trên Mac rồi build lại app."
            case .missingResources(let files):
                "Thiếu tệp VieNeu trong app: \(files.joined(separator: ", "))."
            case .failed(let msg):
                msg
            }
        }
    }

    private(set) var loadedThreads = 0
    private(set) var loadSeconds: Double = 0

    #if canImport(AudioCpp) && canImport(SeaG2P)
    private var registry: OpaquePointer?
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var g2p: OpaquePointer?

    private func check(_ status: audiocpp_status, _ what: String) throws {
        guard status != AUDIOCPP_OK else { return }
        let detail = String(cString: audiocpp_last_error())
        throw VNError.failed("\(what): \(String(cString: audiocpp_status_string(status))) — \(detail)")
    }
    #endif

    var isLoaded: Bool {
        #if canImport(AudioCpp) && canImport(SeaG2P)
        return session != nil && g2p != nil
        #else
        return false
        #endif
    }

    /// Nạp từ điển + mô hình + tạo phiên CPU. Trả về thời gian nạp (giây).
    @discardableResult
    func load(threads: Int) throws -> Double {
        #if canImport(AudioCpp) && canImport(SeaG2P)
        if isLoaded, loadedThreads == threads { return loadSeconds }
        unload()
        let missing = VieNeuResources.missing
        guard missing.isEmpty,
              let modelURL = VieNeuResources.model,
              let dictURL = VieNeuResources.dictionary else { throw VNError.missingResources(missing) }

        let start = Date()
        guard sea_g2p_abi_version() == SEA_G2P_ABI_VERSION else {
            throw VNError.failed("sea-g2p ABI không khớp")
        }
        g2p = sea_g2p_open(dictURL.path)
        guard g2p != nil else {
            throw VNError.failed("Không mở được sea_g2p.bin: \(String(cString: sea_g2p_last_error()))")
        }

        try check(audiocpp_registry_create(nil, &registry), "registry")
        let family = "vieneu_v3_turbo"
        let status: audiocpp_status = family.withCString { fam in
            var config = audiocpp_model_config(family_hint: fam, config_id: nil,
                                               weight_id: nil, model_spec_override: nil)
            return audiocpp_model_load(registry, modelURL.path, &config, nil, &model)
        }
        try check(status, "nạp mô hình")

        let sessionStatus: audiocpp_status = "cpu".withCString { cpu in
            var backend = audiocpp_backend_config(backend: cpu, device: 0, threads: Int32(threads))
            return audiocpp_session_create(model, "tts", "offline", &backend, nil, &session)
        }
        try check(sessionStatus, "tạo phiên")

        loadedThreads = threads
        loadSeconds = Date().timeIntervalSince(start)
        return loadSeconds
        #else
        throw VNError.notBuilt
        #endif
    }

    /// Âm vị sea-g2p của một câu (để kiểm tra cách đọc thuật ngữ).
    func phonemes(for text: String) throws -> String {
        #if canImport(AudioCpp) && canImport(SeaG2P)
        guard let g2p else { throw VNError.failed("Chưa nạp VieNeu.") }
        let normalized = GPBSpeechNormalizer.normalize(text)
        guard let out = sea_g2p_phonemize(g2p, normalized, 1) else {
            throw VNError.failed("sea-g2p: \(String(cString: sea_g2p_last_error()))")
        }
        defer { sea_g2p_string_free(out) }
        return String(cString: out)
        #else
        throw VNError.notBuilt
        #endif
    }

    /// Tổng hợp một đoạn văn bản tiếng Việt (có thể lẫn thuật ngữ tiếng Anh).
    func synthesize(_ text: String, temperature: Double = 0.6) throws -> (VieNeuAudio, VieNeuTiming) {
        #if canImport(AudioCpp) && canImport(SeaG2P)
        guard let session else { throw VNError.failed("Chưa nạp VieNeu.") }
        guard let refCodes = VieNeuResources.referenceCodes,
              let speaker = VieNeuResources.speakerEmbedding else {
            throw VNError.missingResources(VieNeuResources.missing)
        }
        var timing = VieNeuTiming()

        let t0 = Date()
        let phon = try phonemes(for: text)
        timing.g2p = Date().timeIntervalSince(t0)

        let request = audiocpp_request_create()
        defer { audiocpp_request_free(request) }
        // Không đặt language: VieNeu nhận chuỗi âm vị trực tiếp.
        try check(audiocpp_request_set_text(request, phon, nil), "đặt văn bản")
        try check(audiocpp_request_set_option(request, "reference_codes_file", refCodes.path), "giọng (codes)")
        try check(audiocpp_request_set_option(request, "speaker_embedding_file", speaker.path), "giọng (embedding)")
        try check(audiocpp_request_set_option(request, "seed", "1234"), "seed")
        // Nhiệt độ thấp hơn mặc định (0,8) → ít nuốt/lặp chữ ở số dài và ký hiệu.
        try check(audiocpp_request_set_option(request, "temperature", String(format: "%.2f", temperature)), "temperature")

        var result: OpaquePointer?
        let t1 = Date()
        try check(audiocpp_session_run(session, request, &result), "tổng hợp")
        defer { audiocpp_result_free(result) }
        timing.synthesis = Date().timeIntervalSince(t1)

        var samplesPtr: UnsafePointer<Float>?
        var frames = 0
        var rate: Int32 = 0
        var channels: Int32 = 0
        try check(audiocpp_result_audio(result, &samplesPtr, &frames, &rate, &channels), "đọc âm thanh")
        guard let samplesPtr, frames > 0 else { throw VNError.failed("VieNeu không trả về âm thanh.") }
        let count = frames * Int(max(channels, 1))
        let audio = VieNeuAudio(samples: Array(UnsafeBufferPointer(start: samplesPtr, count: count)),
                                sampleRate: Int(rate), channels: Int(max(channels, 1)))
        timing.audio = audio.duration
        return (audio, timing)
        #else
        throw VNError.notBuilt
        #endif
    }

    func unload() {
        #if canImport(AudioCpp) && canImport(SeaG2P)
        audiocpp_session_free(session); session = nil
        audiocpp_model_free(model); model = nil
        audiocpp_registry_free(registry); registry = nil
        sea_g2p_close(g2p); g2p = nil
        #endif
        loadedThreads = 0
    }
}
