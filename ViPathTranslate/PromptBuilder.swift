import Foundation

/// Dựng prompt cho từng họ mô hình. Chỉ chèn những thuật ngữ thực sự xuất hiện trong đoạn
/// đang dịch (thường 3–20 dòng) thay vì toàn bộ glossary — mô hình nhỏ làm theo tốt hơn nhiều.
enum PromptBuilder {

    /// Khối thuật ngữ: "- immunohistochemistry → hóa mô miễn dịch (ghi chú)"
    static func glossaryBlock(_ hits: [GlossaryHit], maxNoteLength: Int = 90) -> String {
        hits.map { hit in
            var line = "- \(hit.matched) → \(hit.translations.joined(separator: " | "))"
            if hit.isAmbiguous { line += " (chọn nghĩa hợp ngữ cảnh)" }
            if maxNoteLength > 0, let note = hit.notes.first {
                line += " — \(note.prefix(maxNoteLength))"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: Qwen3.5 — dùng chat template qua UserInput(chat:)
    //
    // Prompt hệ thống được giữ NGẮN có chủ đích: mỗi đoạn phải "nạp" lại toàn bộ prompt trước khi
    // sinh chữ, nên bớt ~200 token prompt giúp mỗi đoạn bắt đầu nhanh hơn rõ rệt trên iPhone.

    static func qwenSystem(direction: TranslationDirection, styleGuide: String) -> String {
        switch direction {
        case .enToVi:
            return """
            Bạn là biên dịch viên giải phẫu bệnh, dịch Anh → Việt.
            - Chỉ trả về bản dịch tiếng Việt, không giải thích.
            - Dùng đúng bản dịch trong mục THUẬT NGỮ.
            - Giữ nguyên tiếng Anh: tên gen, protein, kháng thể, dấu ấn (CD20, HER2, BRAF V600E), mã TNM, tên người.
            - Giữ nguyên số liệu, đơn vị, xuống dòng, gạch đầu dòng.
            - Văn phong giáo trình y khoa, chủ động, chính xác.\(styleGuide.isEmpty ? "" : "\n" + styleGuide)
            """
        case .viToEn:
            return """
            You are an anatomic pathology translator, Vietnamese → English.
            - Output only the English translation, no explanations.
            - Use exactly the English terms given under TERMS.
            - Use standard English pathology terminology (WHO/CAP style).
            - Keep gene, protein, antibody and marker names, TNM codes and person names unchanged.
            - Keep numbers, units, line breaks and bullet points.
            """
        }
    }

    static func qwenUser(text: String, hits: [GlossaryHit], direction: TranslationDirection) -> String {
        var s = ""
        switch direction {
        case .enToVi:
            if !hits.isEmpty { s += "THUẬT NGỮ (bắt buộc dùng):\n\(glossaryBlock(hits))\n\n" }
            s += "Dịch sang tiếng Việt:\n\n\(text)"
        case .viToEn:
            if !hits.isEmpty { s += "TERMS (must use):\n\(glossaryBlock(hits))\n\n" }
            s += "Translate into English:\n\n\(text)"
        }
        return s
    }

    // MARK: TranslateGemma — tự dựng chuỗi prompt Gemma
    //
    // Chat template của TranslateGemma bắt buộc nội dung user là cấu trúc
    // {type, source_lang_code, target_lang_code, text} và không cho phép role system,
    // nên không chèn glossary qua template được. Ta dựng prompt thô theo định dạng Gemma
    // (giữ đúng câu lệnh mà template sinh ra) và thêm khối thuật ngữ trước văn bản nguồn.

    static func translateGemmaRaw(text: String, hits: [GlossaryHit],
                                  direction: TranslationDirection = .enToVi) -> String {
        let (src, tgt) = direction == .enToVi ? ("English", "Vietnamese") : ("Vietnamese", "English")
        var instruction = """
        You are a professional \(src) (\(direction.sourceCode)) to \(tgt) (\(direction.targetCode)) translator \
        specialising in anatomical pathology. Your goal is to accurately convey the meaning and nuances of the \
        original \(src) text while adhering to \(tgt) medical terminology.
        Produce only the \(tgt) translation, without any additional explanations or commentary.
        Keep gene, protein, antibody and marker names, TNM codes and person names unchanged.
        """
        if !hits.isEmpty {
            instruction += "\nUse exactly these \(tgt) terms:\n\(glossaryBlock(hits, maxNoteLength: 0))"
        }
        instruction += "\nPlease translate the following \(src) text into \(tgt):\n\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        // BOS do tokenizer tự thêm khi encode.
        return "<start_of_turn>user\n\(instruction)<end_of_turn>\n<start_of_turn>model\n"
    }

    // MARK: Hunyuan-MT — prompt thô theo chat template của Tencent
    //
    // Template: "<|startoftext|>" + nội dung user + "<|extra_0|>"; mô hình trả lời rồi kết thúc bằng
    // "<|eos|>". Hunyuan-MT được huấn luyện với đúng một câu lệnh ngắn và KHÔNG dùng system prompt,
    // nên chỉ thêm khối thuật ngữ gọn ở giữa câu lệnh và văn bản nguồn.

    static func hunyuanRaw(text: String, hits: [GlossaryHit],
                           direction: TranslationDirection = .enToVi) -> String {
        let tgt = direction == .enToVi ? "Vietnamese" : "English"
        var prompt = "Translate the following segment into \(tgt), without additional explanation."
        if !hits.isEmpty {
            prompt += " Use these term translations:\n\(glossaryBlock(hits, maxNoteLength: 0))"
        }
        prompt += "\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        return "<|startoftext|>\(prompt)<|extra_0|>"
    }

    /// Chuỗi dừng / rác cần cắt khỏi đầu ra.
    static let stopMarkers = ["<end_of_turn>", "<|im_end|>", "<eos>", "<|eos|>", "<|endoftext|>"]

    static func clean(_ raw: String) -> String {
        var t = raw
        // Qwen có thể xuất phần suy luận <think>…</think>
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) {
                t.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                t.removeSubrange(open.lowerBound..<t.endIndex)
                break
            }
        }
        for m in stopMarkers {
            if let r = t.range(of: m) { t.removeSubrange(r.lowerBound..<t.endIndex) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Tách văn bản dán vào thành các đoạn để dịch lần lượt (mỗi đoạn có glossary riêng,
/// ngữ cảnh ngắn → nhanh, ít "quên" chỉ dẫn, ít tốn RAM cho KV cache).
enum Segmenter {
    struct Segment: Identifiable {
        let id: Int
        let text: String
        /// true = dòng trống / chỉ ký hiệu → giữ nguyên, không dịch
        let passthrough: Bool
    }

    static func split(_ text: String, maxChars: Int = 900) -> [Segment] {
        var out: [Segment] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var buffer: [String] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(Segment(id: out.count, text: buffer.joined(separator: "\n"), passthrough: false))
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.allSatisfy({ !$0.isLetter }) {
                flush()
                out.append(Segment(id: out.count, text: line, passthrough: true))
                continue
            }
            // Gom nhiều dòng (kể cả gạch đầu dòng liên tiếp) vào một đoạn đến ~maxChars:
            // ít đoạn hơn = ít lần nạp lại prompt = dịch nhanh hơn. Mô hình được dặn giữ xuống dòng.
            if buffer.joined(separator: "\n").count + line.count > maxChars { flush() }
            buffer.append(line)
        }
        flush()
        return out
    }
}
