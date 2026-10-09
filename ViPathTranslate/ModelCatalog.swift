import Foundation

/// Mô hình chạy được trên iPhone 18 Pro Max (12 GB RAM) qua mlx-swift-lm 2.31.x.
/// Dung lượng = tổng file .safetensors trên Hugging Face (mlx-community).
enum ModelChoice: String, CaseIterable, Identifiable, Codable {
    case qwen35_4b       = "mlx-community/Qwen3.5-4B-4bit"
    case translateGemma4b = "mlx-community/translategemma-4b-it-4bit"
    case qwen35_9b       = "mlx-community/Qwen3.5-9B-4bit"
    case qwen35_2b       = "mlx-community/Qwen3.5-2B-4bit"

    enum Family { case qwen, translateGemma }

    var id: String { rawValue }

    var family: Family {
        switch self {
        case .translateGemma4b: .translateGemma
        default: .qwen
        }
    }

    var shortName: String {
        switch self {
        case .qwen35_4b: "Qwen3.5 4B"
        case .translateGemma4b: "TranslateGemma 4B"
        case .qwen35_9b: "Qwen3.5 9B"
        case .qwen35_2b: "Qwen3.5 2B"
        }
    }

    var sizeLabel: String {
        switch self {
        case .qwen35_4b: "3,0 GB"
        case .translateGemma4b: "2,2 GB"
        case .qwen35_9b: "6,0 GB"
        case .qwen35_2b: "≈1,5 GB"
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
        }
    }

    /// Tên thư mục khi đóng gói model sẵn trong app (folder reference).
    var bundleFolder: String { rawValue.components(separatedBy: "/").last ?? rawValue }
}
