# ViPath Translate — hướng dẫn cho Claude Code

App iPhone/iPad dịch y khoa – giải phẫu bệnh (GPB) Anh ↔ Việt, chạy **offline** trên máy, kèm bản web. Chủ dự án: BS. Quang Minh (bác sĩ GPB), làm một mình. Trả lời bằng **tiếng Việt**.

## Nguyên tắc bắt buộc
- **Offline trước tiên.** Mọi mô hình chạy trên máy; dữ liệu không rời thiết bị.
- **Không bao giờ nhúng API key vào app.** Người dùng tự nhập key (Claude), app lưu trong Keychain (`KeychainHelper.swift`).
- **Không có thông tin định danh bệnh nhân.** Trước khi gửi gì ra ngoài (Claude API) phải tự động che tên, PID, mã bệnh phẩm, ngày sinh (`PHIRedactor.swift`) và có màn xác nhận rõ ràng (`RedactionConfirmView`).
- Logic dùng chung Swift ↔ JS phải giữ **tương đương**: `GrossDictation.swift` (GrossParser) ↔ `Web/src/logic.js`. Sửa một bên thì sửa bên kia và chạy test.

## Cấu trúc
- `ViPathTranslate/` — app SwiftUI (iOS 26+, Swift 6). Tab: Dịch · Phụ đề · Chép lời · Đại thể · Thuật ngữ · Đã lưu · Cài đặt (`AppTab` trong `ViPathTranslateApp.swift`; iPad màn rộng dùng sidebar).
  - Dịch: `TranslationEngine.swift` (MLX, actor), `TranslatorViewModel.swift`, `PromptBuilder.swift` (prompt + `Segmenter` chia đoạn ≤ 900 ký tự), `ModelCatalog.swift` (danh mục mô hình, `DeviceMemory`, ngưỡng RAM), `HunyuanMT.swift` (kiến trúc tuỳ biến).
  - Giọng nói: `WhisperEngine.swift` (WhisperKit: PhoWhisper / Whisper turbo, Neural Engine hoặc GPU), `SpeechInput.swift` (Apple SpeechAnalyzer, `AudioSessionControl`), `LiveCaptions*.swift` (Phụ đề), `GrossDictation*.swift` (Đại thể: lệnh giọng nói, mã ca, cát xét, "ca mới", chế độ song song Apple + Whisper), `TranscribeController.swift` (Chép lời).
  - Bộ nhớ: `MemoryMonitor.swift` (phys_footprint, os_proc_available_memory, đỉnh theo tab, memory warning) + mục "Bộ nhớ" trong `SettingsView.swift`. `ModelLoader` (trong `SettingsView.swift`) nạp mô hình song song/lần lượt.
  - TTS: `SpeechOutput.swift`, `VieNeuEngine.swift` (VieNeu-TTS, tuỳ chọn, build bằng `Tools/build_vieneu_ios.sh`).
- `ViPathBroadcast/` — Broadcast Upload Extension (phụ đề từ âm thanh hệ thống), dùng App Group.
- `Web/` — bản web (`src/`, build ra `ViPath.html`, `docs/` là GitHub Pages). `Web/README.md` có chế độ máy chủ cục bộ cho mô hình lớn (TranslateGemma 12B/27B…).
- `Tools/` — script Python build glossary, test bộ che PHI, chuẩn hoá lời đọc…

## Build & kiểm tra
- Mở `ViPathTranslate.xcodeproj`, scheme `ViPathTranslate` (Run dùng cấu hình **Release** — MLX chạy chậm hẳn ở Debug).
- Build dòng lệnh (kiểm tra lỗi biên dịch):
  `xcodebuild -project ViPathTranslate.xcodeproj -scheme ViPathTranslate -configuration Release -destination 'generic/platform=iOS' build | xcbeautify` (hoặc `| tail -50` nếu chưa có xcbeautify)
- MLX **không chạy trên Simulator** — phải thử trên iPhone thật.
- Test logic JS: `node Web/test/test_logic.mjs` → phải in "Tất cả đạt". Test Python: `python3 Tools/test_*.py`.
- Package: mlx-swift-lm ≥ 2.31.3, mlx-swift ≥ 0.31.3, argmax-oss-swift (WhisperKit) ≥ 1.1.1. Project dùng file-system synchronized groups → thêm file .swift mới không cần sửa pbxproj.
- Khi chạy qua Xcode: tắt Metal API Validation và GPU Frame Capture trong Scheme để đo tốc độ MLX cho đúng.

## Thiết bị & RAM (quan trọng)
- Máy chính: iPhone 18 Pro Max, 12 GB RAM; có entitlement `com.apple.developer.kernel.increased-memory-limit`. iOS cấp cho app ≈ 7 GB (đang dùng + còn trống); phần nền của app ≈ 1 GB.
- Mô hình dịch (4-bit, mlx-community): Qwen3.5 2B / 4B (mặc định) / 9B, TranslateGemma 4B, Hunyuan-MT 7B. **TranslateGemma 12B đã bỏ khỏi iOS** (6,6 GB trọng số → iOS đóng app khi nạp).
- Ngưỡng RAM: `requiredFreeBytes` (khuyến nghị) và `minFreeBytes` (sàn, dưới mức này mới từ chối). Qwen 9B: khuyến nghị 6,5 GB, sàn 5,0 GB — chạy tốt ở ~6 GB còn trống.
- Tốc độ sinh chữ bị giới hạn bởi băng thông RAM: Qwen 4B ≈ 29 tok/s, 9B ≈ 13 tok/s là bình thường.
- Đã thử và gỡ: nén KV 8-bit / prefill 256 / đoạn 600 ký tự cho mô hình lớn (chậm hơn, gần như không tiết kiệm RAM vì Qwen3.5 chỉ ¼ lớp dùng KV cache).
- Whisper tự đóng khi nạp mô hình dịch lớn thiếu RAM; tuỳ chọn đóng Whisper khi rời tab giọng nói (mặc định tắt).

## Quy trình phát hành
- Bundle ID `vn.quangminh.vipath.translate`, Team `7BJXZV3PG8`. `ITSAppUsesNonExemptEncryption = NO`.
- TestFlight: tăng `CURRENT_PROJECT_VERSION` cho **cả hai target** (app + ViPathBroadcast), Product → Archive → Distribute → App Store Connect. Nhóm external "Pathology".
- Build đã tải: 1, 2. Việc tiếp theo: build 3 (gồm mục Bộ nhớ, gỡ 12B, chế độ xem trước Apple + Whisper ở Đại thể/Phụ đề), rồi Expire build 2.
- Git: remote `github.com/quangminhmd/vipath-translate`, nhánh `main`. Ảnh ghi ra Mac đôi khi bị thêm metadata C2PA → `git restore` nếu chỉ khác metadata.

## Việc để giai đoạn sau
- Bộ nhớ dịch (RAG trên các bản dịch đã sửa) + lưu cặp "bản mô hình → bản đã sửa"; bộ kiểm tra 100–200 câu; LoRA hai chiều cho Qwen 4B/9B trên Mac (mlx_lm.lora → fuse → 4-bit); DPO từ các bản sửa.
- Đánh giá Zipformer-30M (sherpa-onnx) làm bộ xem trước tiếng Việt thay Apple; Qwen3-ASR và Parakeet-CTC-vi kém PhoWhisper-medium trên tiếng Việt.
- App tra cứu tài liệu kiểu NotebookLM offline: làm thành **app riêng** (không phải tab trong app này).
