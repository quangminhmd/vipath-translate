import Foundation

/// Mô hình chạy được trên iPhone 18 Pro Max (12 GB RAM) qua mlx-swift-lm 2.31.x.
/// Dung lượng = tổng file .safetensors trên Hugging Face (mlx-community).
/// RAM của máy (iPhone 15/16 Pro Max: 8 GB · 17/18 Pro Max: 12 GB) → chọn mô hình và cách nạp phù hợp.
nonisolated enum DeviceMemory {
    /// GB thực tế iOS báo (máy 8 GB báo ~7,5; máy 12 GB báo ~11,x).
    static let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    /// Máy ≤ 8 GB: nạp lần lượt, tránh mô hình lớn.
    static var isLowRAM: Bool { gb < 10 }
    static var label: String { "\(Int(gb.rounded())) GB RAM" }
}

enum ModelChoice: String, CaseIterable, Identifiable, Codable {
    case qwen35_4b       = "mlx-community/Qwen3.5-4B-4bit"
    case translateGemma4b = "mlx-community/translategemma-4b-it-4bit"
    case qwen35_9b       = "mlx-community/Qwen3.5-9B-4bit"
    case qwen35_2b       = "mlx-community/Qwen3.5-2B-4bit"
    case hunyuanMT7b     = "mlx-community/Hunyuan-MT-7B-4bit"
    case translateGemma12b = "mlx-community/translategemma-12b-it-4bit"

    enum Family { case qwen, translateGemma, hunyuanMT }

    var id: String { rawValue }

    var family: Family {
        switch self {
        case .translateGemma4b, .translateGemma12b: .translateGemma
        case .hunyuanMT7b: .hunyuanMT
        default: .qwen
        }
    }

    var shortName: String {
        switch self {
        case .qwen35_4b: "Qwen3.5 4B"
        case .translateGemma4b: "TranslateGemma 4B"
        case .qwen35_9b: "Qwen3.5 9B"
        case .qwen35_2b: "Qwen3.5 2B"
        case .hunyuanMT7b: "Hunyuan-MT 7B"
        case .translateGemma12b: "TranslateGemma 12B"
        }
    }

    var sizeLabel: String {
        switch self {
        case .qwen35_4b: "3,0 GB"
        case .translateGemma4b: "2,2 GB"
        case .qwen35_9b: "6,0 GB"
        case .qwen35_2b: "≈1,5 GB"
        case .hunyuanMT7b: "4,2 GB"
        case .translateGemma12b: "6,6 GB"
        }
    }

    var summary: String {
        switch self {
        case .qwen35_4b:
            "Khuyên dùng. Làm theo glossary tốt, cân bằng tốc độ/chất lượng."
        case .translateGemma4b:
            "Chuyên dịch thuật, câu văn tự nhiên; tuân thủ glossary kém hơn Qwen."
        case .qwen35_9b:
            "Chất lượng cao nhất, nhưng sát giới hạn RAM — có thể bị iOS đóng app với văn bản dài."
        case .qwen35_2b:
            "Nhanh, nhẹ pin; dùng khi cần dịch nháp."
        case .hunyuanMT7b:
            "Mô hình chuyên dịch của Tencent (WMT25), câu văn rất tự nhiên. Ít làm theo glossary hơn Qwen — nên bật bước kiểm tra thuật ngữ."
        case .translateGemma12b:
            "Bản lớn của TranslateGemma, chất lượng dịch cao hơn 4B rõ rệt. Nặng nhất máy chạy được: đóng các mô hình Whisper trước khi nạp."
        }
    }

    /// RAM tối thiểu cần còn trống trước khi nạp (trọng số + ≈0,5 GB KV cache), tính bằng byte.
    var requiredFreeBytes: UInt64 {
        let gb: Double = switch self {
        case .qwen35_2b: 2.0
        case .translateGemma4b: 2.7
        case .qwen35_4b: 3.5
        case .hunyuanMT7b: 4.7
        case .qwen35_9b: 6.5
        case .translateGemma12b: 7.1
        }
        return UInt64(gb * 1_073_741_824)
    }

    /// Mức sàn tuyệt đối: dưới mức này chắc chắn không nạp nổi → từ chối.
    /// Giữa sàn và `requiredFreeBytes` vẫn cho nạp (kèm cảnh báo): trọng số MLX được ánh xạ
    /// từ tệp nên iOS thường cấp thêm khi cần — Qwen 9B vẫn chạy được ở mức ~6 GB còn trống.
    var minFreeBytes: UInt64 {
        let gb: Double = switch self {
        case .qwen35_2b: 1.4
        case .translateGemma4b: 2.0
        case .qwen35_4b: 2.6
        case .hunyuanMT7b: 3.6
        case .qwen35_9b: 5.0
        // 12B: trọng số 6,6 GB được nạp hết vào RAM → cần ít nhất trọng số + 0,2 GB, nếu không iOS đóng app giữa lúc nạp
        // (đã gặp trên iPhone 18 Pro Max: còn 6,0 GB → văng).
        case .translateGemma12b: 6.8
        }
        return UInt64(gb * 1_073_741_824)
    }

    /// Mô hình lớn (Qwen 9B, TranslateGemma 12B): dịch theo đoạn ngắn hơn, nén KV cache để không vượt RAM.
    var isLarge: Bool { requiredFreeBytes >= UInt64(6 * 1_073_741_824) }

    enum DeviceFit { case ok, tight, tooBig }

    /// Mức phù hợp với RAM của máy này.
    var deviceFit: DeviceFit {
        let need = Double(requiredFreeBytes) / 1_073_741_824
        let (okMax, tightMax): (Double, Double) =
            DeviceMemory.gb >= 10 ? (99, 99)      // 12 GB: chạy được mọi mô hình trong danh mục
            : DeviceMemory.gb >= 7 ? (3.6, 5.0)   // 8 GB: ≤ 4B thoải mái, 7B sát giới hạn, 9B/12B không
            : (2.1, 2.8)                          // ≤ 6 GB: chỉ mô hình nhỏ
        // iPhone 12 GB chỉ cấp cho app ≈ 7 GB → 12B (cần ≈ 7,1 GB trống) thường không nạp được.
        if self == .translateGemma12b, DeviceMemory.gb >= 10 { return .tight }
        return need <= okMax ? .ok : need <= tightMax ? .tight : .tooBig
    }

    /// Ghi chú hiện trong danh sách chọn mô hình (nil = phù hợp).
    var deviceFitNote: String? {
        switch deviceFit {
        case .ok: nil
        case .tight where self == .translateGemma12b:
            "Cần ≈ 6,8 GB RAM trống; iPhone \(DeviceMemory.label) thường chỉ cấp cho app ≈ 7 GB nên hay bị từ chối. Xem RAM còn trống ở mục Bộ nhớ."
        case .tight: "Sát giới hạn \(DeviceMemory.label) — đóng các app khác trước khi nạp"
        case .tooBig: "Không đủ RAM trên máy này (\(DeviceMemory.label))"
        }
    }

    /// Mô hình dịch Việt → Anh nên dùng cho phụ đề trên máy này.
    static var recommendedSubtitleModel: ModelChoice {
        hunyuanMT7b.deviceFit == .ok ? .hunyuanMT7b : .translateGemma4b
    }

    /// Mô hình có kiến trúc mlx-swift-lm chưa hỗ trợ sẵn → app tự đăng ký.
    var needsCustomArchitecture: Bool { self == .hunyuanMT7b }

    /// Tên thư mục khi đóng gói model sẵn trong app (folder reference).
    var bundleFolder: String { rawValue.components(separatedBy: "/").last ?? rawValue }
}
