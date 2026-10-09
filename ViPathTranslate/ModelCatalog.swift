import Foundation

/// Mô hình chạy được trên iPhone 18 Pro Max (12 GB RAM) qua mlx-swift-lm 2.31.x.
/// Dung lượng = tổng file .safetensors trên Hugging Face (mlx-community).
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

    /// Mô hình có kiến trúc mlx-swift-lm chưa hỗ trợ sẵn → app tự đăng ký.
    var needsCustomArchitecture: Bool { self == .hunyuanMT7b }

    /// Tên thư mục khi đóng gói model sẵn trong app (folder reference).
    var bundleFolder: String { rawValue.components(separatedBy: "/").last ?? rawValue }
}
