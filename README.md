# ViPath Translate — dịch y học / giải phẫu bệnh offline trên iPhone

Ứng dụng SwiftUI dịch **Anh → Việt** chạy hoàn toàn trên iPhone bằng MLX, dựa trên glossary và hồ sơ ngành của dự án [Vitranslate](https://github.com/cloud1710/Vitranslate). Có ba chế độ: dán văn bản, dịch khi gõ, và phụ đề trực tiếp từ lời nói (giảng đường, hội thảo, Zoom/Teams). Với mỗi đoạn, app chỉ chèn những thuật ngữ glossary thực sự xuất hiện vào prompt, rồi kiểm tra lại bản dịch.

## Cách hoạt động

```
Văn bản dán vào
   │
   ├─ Segmenter ── tách đoạn / gạch đầu dòng (giữ dòng trống, số liệu)
   │
   ├─ GlossaryMatcher ── khớp 641 chuỗi của 487 thuật ngữ GPB
   │     • khớp dài nhất trước ("anaplastic meningioma" thắng "meningioma")
   │     • số nhiều (biopsies, nests), "whole slide" = "whole-slide"
   │     • viết tắt phân biệt hoa thường (IHC, HPF, DLBCL)
   │
   ├─ PromptBuilder ── system: quy tắc + giọng văn từ domains/pathology.md
   │                   user:   chỉ 3–20 thuật ngữ của đoạn này + văn bản
   │
   ├─ TranslationEngine (MLX, temperature 0, tắt thinking)
   │
   └─ GlossaryQA ── cảnh báo ⚠︎ khi bản dịch không dùng đúng thuật ngữ
                    → nút "Dịch lại đoạn này"
```

Tab **Thuật ngữ** dùng để tra cứu glossary. Ở đây cũng thêm được thuật ngữ riêng: chúng lưu trên máy và được ưu tiên khi chèn vào prompt.

## Ba chế độ dịch

| Chế độ | Ở đâu | Dùng khi |
|---|---|---|
| Dịch cả đoạn | Tab **Dịch**, nút *Dịch sang tiếng Việt* | Dán kết quả GPB, bài báo, giáo trình |
| **Dịch khi gõ** | Tab **Dịch**, bật nút *Dịch khi gõ* | Soạn hoặc sửa từng câu, xem bản dịch ngay |
| **Phụ đề trực tiếp** | Tab **Phụ đề** | Nghe giảng, hội thảo, hội chẩn Zoom/Teams |

### Dịch khi gõ
App chờ người dùng ngừng gõ khoảng 0,7 giây rồi mới tách câu. Câu nào đã dịch thì lấy lại từ bộ nhớ đệm, chỉ câu mới hoặc vừa sửa mới được dịch lại. Bộ tách câu không cắt nhầm ở các viết tắt `e.g.`, `et al.`, `Fig.`, `Dr.`, số thập phân `3.5 cm` hay ký hiệu `p.R132H`; kiểm thử bằng `Tools/test_sentences.py`. Câu nào dịch chưa đúng thuật ngữ glossary sẽ hiện màu cam.

### Phụ đề trực tiếp
```
Âm thanh ─► SpeechAnalyzer (nhận dạng tiếng Anh trên máy, iOS 26)
          ─► câu đang nói (chữ xám, cập nhật liên tục)
          ─► câu đã chốt ─► tách câu ─► glossary ─► LLM ─► phụ đề tiếng Việt
```
- **Câu không có dấu chấm** (thường gặp khi nói): app tự cắt khi người nói ngừng 1,5 giây hoặc khi câu dài quá 35 từ.
- **Đuổi kịp người nói**: khi có từ 3 câu trở lên đang chờ dịch, app gộp chúng lại và dịch một lượt, để độ trễ không tăng dần. Góc trái màn hình hiển thị độ trễ của câu vừa dịch.
- **Lưu bản ghi**: nút chia sẻ xuất bản ghi song ngữ của cả buổi.
- **Chọn mô hình**: nên dùng **Qwen3.5 2B hoặc 4B**. Bản 9B có thể không theo kịp người nói và làm máy nóng khi chạy cả giờ.

**Nguồn âm thanh theo tình huống:**

| Tình huống | Nguồn trong app | Cách làm |
|---|---|---|
| Nghe giảng / hội thảo tại chỗ | **Micro** | Đặt iPhone gần loa hoặc người nói |
| Zoom/Teams trên máy tính hoặc iPad | **Micro** | Đặt iPhone cạnh loa máy tính. Cách này đơn giản và ổn định nhất |
| Zoom/Teams **trên chính iPhone này** | **Âm thanh app** | Xem mục bên dưới |

**Họp Zoom/Teams ngay trên iPhone.** iPhone không cho app chạy GPU khi đang ở nền: hiện chưa iPhone nào hỗ trợ background GPU, chỉ một số iPad có ([thảo luận trên Apple Developer Forums](https://developer.apple.com/forums/thread/816774)). Vì vậy ViPath phải luôn ở màn hình chính, còn cuộc họp thu nhỏ thành cửa sổ **Hình trong hình (PiP)**. Âm thanh của cuộc họp được lấy qua **Broadcast Upload Extension** (ReplayKit):
1. Trong ViPath, chọn nguồn *Âm thanh app* rồi bấm *Bắt đầu nghe*.
2. Mở Trung tâm điều khiển, giữ nút **Ghi màn hình**, chọn **ViPath**, rồi bấm *Bắt đầu phát sóng*.
3. Mở Zoom/Teams, vào cuộc họp và bật PiP (vuốt về màn hình chính, cửa sổ video sẽ thu nhỏ).
4. Mở lại ViPath; phụ đề chạy trong lúc cuộc họp hiển thị ở cửa sổ PiP.

Extension chỉ lấy âm thanh của app (`.audioApp`), không lấy micro, nên giọng của chính anh không bị dịch. Extension cũng không chạy mô hình nào (giới hạn khoảng 50 MB RAM); nó chỉ ghi các khối âm thanh 0,5 giây vào App Group để app chính đọc. Nếu ViPath bị chuyển ra nền, app tạm dừng dịch và bỏ âm thanh cũ hơn 5 giây khi quay lại, để phụ đề luôn bám sát thời gian thực.

## iPhone hỗ trợ và mô hình theo RAM

App tối ưu cho **iPhone 18 Pro Max (12 GB RAM)** nhưng cài được trên các iPhone khác chạy **iOS 26 trở lên**. Điều quyết định là **RAM**: mô hình dịch phải nằm trọn trong bộ nhớ. App tự đọc RAM của máy (`DeviceMemory` trong `ModelCatalog.swift`) và điều chỉnh theo bảng dưới đây.

### Dòng iPhone khuyến cáo

| Nhóm | Dòng máy | RAM | Mức dùng |
|---|---|---|---|
| ✅ **Khuyến cáo** | iPhone 18 Pro Max, 18 Pro · iPhone 17 Pro Max, 17 Pro | 12 GB | Đầy đủ: mọi mô hình trong danh mục, nạp song song mô hình dịch + Whisper |
| ⚠︎ **Dùng được, giới hạn** | iPhone 16 Pro Max, 16 Pro, 16 Plus, 16 · iPhone 15 Pro Max, 15 Pro | 8 GB | Mô hình dịch ≤ 4B; Hunyuan-MT-7B sát giới hạn; luôn nạp lần lượt |
| ✕ **Không khuyến cáo** | iPhone 15, 15 Plus và các đời trước có iOS 26 | ≤ 6 GB | Chỉ Qwen3.5-2B (TranslateGemma-4B sát giới hạn); phù hợp tra glossary, Dịch nhanh của Apple, nhận dạng giọng nói |

Không chắc máy có bao nhiêu RAM: mở tab **Dịch → chọn mô hình**, đầu danh sách ghi *“Máy này: … GB RAM”*. Các dòng máy khác (vd. iPhone 17, iPhone Air) xếp vào nhóm theo con số này.

### Phân loại mô hình dịch theo RAM

Tất cả là bản 4-bit trên `mlx-community`. Qwen3.5 và TranslateGemma được mlx-swift-lm 2.31.x hỗ trợ sẵn; Hunyuan-MT-7B dùng kiến trúc tự port (`HunyuanMT.swift`).

| Mô hình | Dung lượng | RAM trống cần | 12 GB | 8 GB | ≤ 6 GB | Vai trò |
|---|---|---|---|---|---|---|
| Qwen3.5-2B | ≈1,5 GB | 2,0 GB | ✅ | ✅ | ✅ | Dịch nháp nhanh, ít tốn pin |
| TranslateGemma-4B | 2,2 GB | 2,7 GB | ✅ | ✅ | ⚠︎ | Chuyên dịch, câu tự nhiên, nhanh — hợp phụ đề |
| **Qwen3.5-4B** (mặc định) | 3,0 GB | 3,5 GB | ✅ | ✅ | ✕ | Theo glossary tốt nhất trong nhóm nhẹ |
| Hunyuan-MT-7B | 4,2 GB | 4,7 GB | ✅ | ⚠︎ | ✕ | Chuyên dịch, rất tốt chiều Việt ↔ Anh |
| Qwen3.5-9B | 6,0 GB | 6,5 GB | ✅ | ✕ | ✕ | Chất lượng cao, chậm hơn |
| TranslateGemma-12B | 6,6 GB | 7,1 GB | ✅ | ✕ | ✕ | Bản dịch hay nhất trên máy, không hợp phụ đề |

✅ phù hợp · ⚠︎ sát giới hạn (đóng các app khác trước khi nạp) · ✕ không đủ RAM.

Trong app:
- **Danh sách chọn mô hình** (tab Dịch) hiện cảnh báo cam cho mô hình ⚠︎, làm mờ và khoá mô hình ✕. Tab **Cài đặt** ẩn hẳn mô hình ✕.
- **Nạp mô hình:** máy 12 GB nạp song song mô hình dịch (GPU) và Whisper (Neural Engine) khi mô hình dịch < 9B. Máy 8 GB trở xuống luôn nạp lần lượt. Mô hình đã chọn trước đó mà không đủ RAM sẽ không được tự nạp.
- Trước khi nạp, app kiểm tra RAM còn trống (`os_proc_available_memory`) và báo lỗi rõ ràng thay vì để iOS đóng app.
- **Phụ đề Việt → Anh — cấu hình gợi ý:** máy 12 GB chọn được PhoWhisper + Hunyuan-MT-7B hoặc PhoWhisper + TranslateGemma-4B; máy 8 GB chỉ có PhoWhisper + TranslateGemma-4B.

Các thành phần sau chạy được trên mọi máy iOS 26 (không phụ thuộc bảng trên): PhoWhisper-medium (~560 MB), Whisper large-v3 turbo (~630 MB), nhận dạng giọng nói và Dịch nhanh của Apple (mô hình do iOS quản lý, không tính vào RAM của app). Máy đời cũ chạy chậm hơn.

> Các ngưỡng trên được ước lượng theo dung lượng mô hình và mới đo thực tế trên iPhone 18 Pro Max. Nếu thử trên máy 8 GB thấy khác, chỉnh ngưỡng trong `ModelChoice.deviceFit`.

### Điều kiện cài

- **iOS 26 trở lên** (deployment target 26.0) và **Xcode 26/27** trên Mac.
- **Tài khoản Apple Developer trả phí (khuyến cáo).** App dùng hai quyền *Increased Memory Limit* (cho phép app dùng nhiều RAM hơn — cần cho các mô hình lớn) và *App Groups* (phụ đề Zoom/Teams trên cùng iPhone).
  - Với **Apple ID miễn phí**: phải tạm xoá hai entitlement này mới cài được; app hết hạn sau 7 ngày (cài lại bằng Xcode); thực tế chỉ dùng được mô hình 2B và không có phụ đề Zoom/Teams trên cùng máy.
- **Cách cài:**
  - *Cắm cáp vào Mac → Xcode ▶ (⌘R)* — xem mục dưới. Máy mới cần bật **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển**.
  - *TestFlight* để cài cho đồng nghiệp không cần cáp (cần tài khoản trả phí).
- **Dung lượng trống:** mô hình dịch 1,5–6,6 GB mỗi mô hình + Whisper ~0,6 GB mỗi mô hình. Lần đầu cần Internet để tải; sau đó chạy offline.

## Mở và chạy trong Xcode

Dự án đã kèm sẵn `ViPathTranslate.xcodeproj` (Xcode 26/27) với 2 target: app `ViPathTranslate` và extension `ViPathBroadcast`. Package (mlx-swift-lm 2.31.3, mlx-swift 0.31.x), entitlements, quyền micro và nhận dạng giọng nói đều đã cấu hình. Đã build thành công, không có cảnh báo, trên Xcode 27 / iOS 27 Simulator.

1. Mở `ViPathTranslate.xcodeproj`. Lần build đầu, Xcode hỏi cho phép plugin **CudaBuild** của mlx-swift: chọn **Trust & Enable**.
2. **Signing & Capabilities** (cả hai target): chọn *Team* của anh. Nếu đổi bundle ID thì đổi App Group trong `Config/*.entitlements` và `SharedAudio.appGroupID` cho khớp.
   - *Increased Memory Limit* và *App Groups* cần tài khoản Apple Developer trả phí (xem **Điều kiện cài** ở trên).
3. Chọn iPhone thật làm đích chạy rồi bấm ▶.

**Simulator:** dùng được để xem giao diện, tra glossary và thử phụ đề. Riêng việc nạp mô hình sẽ báo lỗi, vì MLX cần GPU Metal thật; app cố ý không khởi tạo MLX trên Simulator để tránh crash.

> Lưu ý về mlx-swift-lm 3.x: dòng 3.x tách tokenizer và downloader thành các package riêng, và đổi cách nạp mô hình. Code này viết cho 2.31.x. Nếu nâng lên 3.x, xem tài liệu nâng cấp của package để sửa `TranslationEngine.load`.

## Đọc bản dịch (giọng nói)

- Tab **Dịch** có nút **Đọc** để đọc bản dịch tiếng Việt.
- Tab **Phụ đề** → *Tuỳ chọn* → **Đọc bản dịch (thông dịch bằng giọng)**: đọc nối tiếp từng câu đã dịch. Nên đeo tai nghe để giọng đọc không lọt lại vào micro.
- Hiện dùng giọng tiếng Việt có sẵn của iOS, chạy offline. Nên tải giọng chất lượng cao tại Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt.
- `SpeechOutput.swift` là lớp đọc dùng chung, có thể thay bằng VieNeu-TTS sau này mà không phải sửa chỗ gọi.

## VieNeu-TTS (giọng đọc tiếng Việt chất lượng cao, tuỳ chọn)

[VieNeu-TTS v3 Turbo](https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo) chạy trên CPU qua [audio.cpp](https://github.com/0xShug0/audio.cpp) (C API) và [sea-g2p](https://github.com/pnnbao97/sea-g2p) (Rust, chuyển chữ thành âm vị). Cả ba đều theo giấy phép Apache 2.0. Khi chưa build VieNeu, app vẫn chạy bình thường với giọng iOS.

```
Văn bản ─► GPBSpeechNormalizer (1p/19q, pT1aN1b, p.R132H…) ─► sea-g2p (âm vị)
        ─► audio.cpp / VieNeu (CPU, Q8_0) ─► PCM 48 kHz ─► AVAudioEngine
```

**Cài đặt (một lần, khoảng 20–40 phút):**
1. **Thoát Xcode** (⌘Q).
2. Mở **Terminal** và chạy:
   ```bash
   cd ~/Documents/ViPathTranslate && bash Tools/build_vieneu_ios.sh
   ```
   Script sẽ tự làm các việc sau:
   - Kiểm tra hoặc cài cmake, ninja (qua Homebrew) và Rust.
   - Build `Frameworks/SeaG2P.xcframework` và `Frameworks/AudioCpp.xcframework` cho iPhone và Simulator.
   - Tải mô hình Q8_0 (~190 MB), giọng *minh_quan_pro* và từ điển `sea_g2p.bin` (~63 MB) vào `ViPathTranslate/Resources/VieNeu/`.
   - Gắn hai framework vào dự án Xcode (có sao lưu `project.pbxproj.bak`).
   - Nếu lỗi, xem `build/vieneu/build.log`. Chạy lại script sẽ bỏ qua các bước đã xong.
3. Mở lại dự án, chọn iPhone, rồi bấm ▶. App sẽ nặng thêm khoảng 270 MB.
4. Trong app: tab **Dịch** → nút **Giọng đọc** (biểu tượng sóng âm) → **Nạp VieNeu**. Bấm *Tổng hợp & phát* với các câu GPB mẫu để xem **RTF** và thời gian chờ câu đầu.
5. Nếu RTF < 1, bật **Dùng VieNeu cho nút Đọc và thông dịch bằng giọng**. Nếu VieNeu lỗi, app tự đọc bằng giọng iOS.

**Đã kiểm tra trước khi giao:**
- audio.cpp (bản ghim) build được với C API và chỉ họ VieNeu.
- sea-g2p đọc đúng các câu GPB mẫu, trừ vài ký hiệu; `GPBSpeechNormalizer` đã sửa các ký hiệu đó.
- Phần Swift gọi C đã biên dịch qua Xcode 27.

**Chưa kiểm tra:** build cho iOS và tốc độ thật trên iPhone, vì việc này cần Terminal trên Mac.

**Giới hạn của VieNeu trong audio.cpp hiện nay:**
- Chưa có chế độ stream nên phải tổng hợp xong cả câu rồi mới phát. App tách văn bản theo câu và tổng hợp câu kế tiếp trong lúc câu trước đang phát.
- Chưa nhân bản giọng trên máy được, vì bộ mã hoá người nói chưa được port. App dùng giọng có sẵn.

## Dịch hai chiều, lưu bản dịch, Claude (tuỳ chọn)

### Dịch Anh ↔ Việt
- Chọn chiều ở đầu ô nhập: **Tự động** (mặc định), *Anh → Việt* hoặc *Việt → Anh*. Bấm ⇄ để đảo chiều; bản dịch đang có sẽ thành văn bản nguồn.
- Chế độ Tự động đếm tỉ lệ chữ có dấu tiếng Việt: từ 3% trở lên thì coi là văn bản tiếng Việt.
- Chiều Việt → Anh dùng bộ khớp ngược `VietnameseGlossaryMatcher`. Bộ này coi "hoá" và "hóa", "thuỷ" và "thủy" là một, và chèn thuật ngữ tiếng Anh chuẩn (WHO/CAP) vào prompt.
- Cách tăng tốc:
  - Prompt hệ thống rút gọn.
  - Các dòng liền nhau được gộp thành đoạn tối đa 900 ký tự, nên số lần đọc prompt giảm.
  - Màn hình cập nhật tối đa 20 lần/giây.
  - Dưới bản dịch có dòng thống kê: tổng thời gian, thời gian đọc prompt và tok/s.

### Phụ đề hai khung
- Khung trên hiện lời tiếng Anh nhận dạng được. Câu đang nói hiện màu xám nghiêng.
- Khung dưới hiện phụ đề tiếng Việt, cập nhật theo từng token.
- Hai khung chạy song song và tự cuộn. Chiều cao khung trên chỉnh trong *Tuỳ chọn*.

### Chép lời từ tệp ghi âm / video (tab Chép lời)
1. Chọn **Tệp** (m4a, mp3, wav, mp4, mov…) hoặc một video trong **Thư viện ảnh**, và chọn ngôn ngữ nói (Anh / Việt).
2. App trích âm thanh rồi nhận dạng trên máy bằng Apple Speech.
   - Tiếng Anh dùng SpeechTranscriber. Tiếng Việt dùng SpeechTranscriber nếu iOS hỗ trợ, nếu không thì dùng DictationTranscriber.
   - Lần đầu iOS tải gói nhận dạng cho ngôn ngữ đó.
   - **Bộ nhận dạng** (chọn riêng cho từng ngôn ngữ):

     | Bộ nhận dạng | Dùng cho | Ghi chú |
     |---|---|---|
     | Apple Speech | Mặc định cho tiếng Anh | Có sẵn trong iOS |
     | PhoWhisper-medium | Mặc định cho tiếng Việt | ~560 MB |
     | Whisper large-v3 turbo | Bài giảng trộn Anh–Việt | ~630 MB |

     - Mô hình Whisper chạy qua WhisperKit (package `argmax-oss-swift`) trên Neural Engine. App tải mô hình một lần từ Hugging Face vào `Application Support/WhisperModels` (không sao lưu iCloud), sau đó chạy offline.
     - Lần nạp đầu tiên iOS tối ưu mô hình cho Neural Engine, mất 1–3 phút.
     - Âm thanh được cắt thành cửa sổ ≤ 14 s (PhoWhisper) hoặc ≤ 27 s (turbo), cắt ở chỗ im lặng nhất. Các đoạn im lặng được bỏ qua để tránh Whisper "bịa" chữ.
     - Tuỳ chọn *Gợi ý thuật ngữ GPB* đưa danh sách thuật ngữ trong glossary vào lời nhắc ban đầu, giúp Whisper viết đúng chính tả chuyên ngành.
3. Lời nói được chia thành đoạn phụ đề có mốc giờ. App ngắt đoạn ở dấu kết câu, khi người nói ngưng quá 0,8 s, hoặc khi đoạn dài quá 10 s / 84 ký tự.
4. **Dịch sang tiếng Việt/Anh** dịch từng đoạn bằng mô hình offline và có chèn glossary. Bật *Tự dịch khi chép lời* để dịch song song trong lúc nhận dạng.
5. Cách dùng bản ghi:
   - Chạm mốc giờ để nghe lại đoạn đó; chạm dòng để sửa lời hoặc bản dịch.
   - Chép văn bản gốc, bản dịch hoặc song ngữ, có hoặc không kèm mốc giờ.
   - Xuất **SRT / VTT / TXT**.
   - Bấm **Lưu** để đưa vào tab Đã lưu, nơi cũng xuất được SRT.

### Đọc mô tả đại thể khi phẫu tích – cắt lọc (tab Đại thể)

- Bấm micro rồi đọc như đọc cho người ghi chép; nhận dạng tiếng Việt / tiếng Anh **trên máy** (Apple Speech, kèm từ vựng đại thể gợi ý).
- Lệnh rảnh tay: “cát xét A1”, “mẫu bê hai”, “cát xét tiếp theo”, “quay lại mô tả”, “xuống dòng”, “dấu phẩy”, “xoá câu”, “tạm dừng” / “tiếp tục ghi”, “dừng ghi”.
- **Sang ca mới không cần chạm màn hình:** “ca mới”, “chuyển ca”, “ca tiếp theo” — lưu ca đang đọc vào Đã lưu rồi mở trang mới; nói kèm “…, mã ca …” để đặt luôn pathcode ca mới. Hoặc bấm **Ca mới** cạnh ô Pathcode (khi đã dừng ghi).
- Số đo tự chuẩn hoá: “bốn nhân ba nhân hai xăng ti mét” → 4 x 3 x 2 cm; “hai phân rưỡi” → 2,5 cm; “mười hai hạch” → 12 hạch. Chữ số chỉ được đổi khi đứng cạnh đơn vị, “nhân” hoặc danh từ đếm.
- Danh sách cát xét ghép vào cuối: `CẮT LỌC – CÁT XÉT: A1: …`. Gợi ý cấu trúc mô tả theo loại bệnh phẩm (sinh thiết, túi mật, ruột thừa, tuyến giáp, vú, đại – trực tràng, tử cung).
- Dùng được AirPods / tai nghe Bluetooth; màn hình không tự khoá khi đang ghi. Danh sách “Sửa lỗi nhận dạng” do bác sĩ tự thêm (vd. “các xi nôm” → carcinôm).
- ⋯ → **Chép lại bằng PhoWhisper**: nhận dạng lại toàn bộ bản ghi của phiên bằng PhoWhisper-medium (tiếng Việt) để chính xác hơn; bản cũ vẫn khôi phục được bằng Hoàn tác.
- Lưu vào tab Đã lưu (loại Đại thể), chép, chia sẻ, hoặc **Dịch sang tiếng Anh** bằng mô hình offline + glossary.
- Logic phân tích lệnh nằm ở `GrossDictation.swift`, bản JavaScript tương ứng ở `Web/src/logic.js`; bộ ca kiểm thử chung: `node Web/test/test_logic.mjs`.

### Chữ trong ảnh (nút **Ảnh** ở tab Dịch)
- **Nguồn ảnh:**
  - Thư viện ảnh (tối đa 20 ảnh).
  - **Quét / chụp** bằng máy quét tài liệu của iOS, tự căn phẳng và cắt viền, quét được nhiều trang.
  - Tệp ảnh hoặc PDF. PDF có lớp chữ được đọc trực tiếp; PDF scan thì nhận dạng tối đa 60 trang.
  - Ảnh dán từ bộ nhớ tạm.
- **Nhận dạng:** dùng Apple Vision trên máy, cho tiếng Việt có dấu và tiếng Anh, có tuỳ chọn nối các dòng bị ngắt giữa câu.
- **Sau khi trích:**
  - Sửa trực tiếp văn bản, rồi **Chép**.
  - Hoặc **Dịch**: tự nhận chiều, Anh → Việt, hoặc Việt → Anh. Văn bản được đưa vào tab Dịch và dịch ngay.

### Dịch nhanh (Apple Translation) cho Phụ đề và Chép lời
- Bật hoặc tắt trong *Tuỳ chọn* của tab Phụ đề, hoặc mục *Dịch nhanh* của tab Chép lời. Lần đầu bấm **Tải gói ngôn ngữ** để iOS tải gói Anh ↔ Việt; sau đó chạy offline, không dùng GPU và không chiếm RAM của app.
- **Cách kết hợp:**
  - Mỗi câu hiện ngay bản dịch nhanh, có dấu ⚡ và chữ màu xám.
  - Mô hình offline (Qwen / TranslateGemma) kèm glossary dịch lại và thay bằng bản chuẩn.
  - Nếu chưa nạp mô hình, bản ⚡ là bản cuối nhưng vẫn được kiểm tra thuật ngữ glossary (chấm màu cam nếu dùng sai).
- **Tab Chép lời:**
  - Đoạn mới được dịch nhanh theo lô 40 đoạn.
  - **Dịch chuẩn** chỉ dịch lại các đoạn ⚡ và giữ bản ⚡ trên màn hình cho đến khi có bản chuẩn.
  - Đoạn bác sĩ đã sửa tay không bị ghi đè.

### Lưu
- **Tab Dịch:** bấm **Lưu** trên khung kết quả (offline, dịch khi gõ hoặc Claude).
- **Tab Phụ đề:** phiên được tự lưu khi bấm Dừng (tắt được trong Tuỳ chọn). Cũng có nút Lưu trên thanh công cụ.
- **Tab Đã lưu:** tìm kiếm, xem, đổi tiêu đề, chép, chia sẻ, xoá.
- Mỗi mục là một tệp JSON trong `Documents/Saved`, mã hoá khi máy khoá (`completeFileProtection`).

### Claude qua API (khi có Internet)
1. Bấm biểu tượng đám mây ở góc trái tab Dịch, chọn **Cài đặt Claude…**, rồi dán API key tạo ở console.anthropic.com.
   - Key chỉ lưu trong Keychain (`WhenUnlockedThisDeviceOnly`, không đồng bộ iCloud) và không bao giờ nằm trong mã nguồn.
2. Chạm vào biểu tượng đám mây để **kết nối / ngắt kết nối**. Khi ngắt, app không gửi gì ra mạng.
3. Bấm **Hiệu đính bằng Claude** (nếu đã có bản dịch offline) hoặc **Dịch bằng Claude**.
   - `PHIRedactor` tự che họ tên, PID / mã hồ sơ / số vào viện, mã bệnh phẩm, ngày sinh, CCCD / CMND / hộ chiếu, SĐT, email, địa chỉ và ngày tháng bằng nhãn như `[TÊN_1]`, `[PID_1]`.
   - Màn hình xác nhận tô màu chỗ đã che và cho phép che thêm cụm tuỳ ý.
   - Phải bật ô xác nhận thì mới gửi được.
   - Bảng đối chiếu nhãn ↔ giá trị thật chỉ nằm trên máy. Sau khi Claude trả kết quả, app đặt lại giá trị thật vào bản dịch.
4. Chọn mô hình: Sonnet 5.5 (mặc định), Haiku 5.5 (nhanh, rẻ) hoặc Opus 5.5 (câu khó).
   - Văn bản dài hơn 9.000 ký tự được chia nhiều lượt gọi theo đoạn.

**Vòng học thuật ngữ:**
- Claude trả kèm danh sách thuật ngữ hiếm mà glossary còn thiếu hoặc bản nháp offline dịch sai.
- Danh sách này vào mục **Duyệt thuật ngữ** (tab Thuật ngữ, có số đếm trên tab).
- Bác sĩ sửa nếu cần rồi bấm **Duyệt**. Thuật ngữ được thêm vào glossary của bạn, thay mục gốc nếu trùng, và mô hình offline dùng ngay từ lần dịch sau.
- Mục bị *Bỏ qua* sẽ không được đề xuất lại.

Kiểm thử bộ che định danh: `pip install regex && python3 Tools/test_redactor.py`.

## Chạy offline 100%

- **Tải một lần.** Bấm *Nạp mô hình* lần đầu khi có mạng; mô hình được lưu cache trong app. Từ lần sau, bật Chế độ máy bay vẫn dịch được.
- **Đóng gói sẵn.** Tải mô hình trên Mac:
  ```bash
  pip install huggingface_hub
  huggingface-cli download mlx-community/Qwen3.5-4B-4bit --local-dir Qwen3.5-4B-4bit
  ```
  Kéo thư mục `Qwen3.5-4B-4bit` vào Xcode và chọn **Create folder references**. App sẽ tự ưu tiên bản có trong bundle. Tên thư mục phải trùng phần sau dấu `/` của ID mô hình.

## Cập nhật glossary từ Vitranslate

Khi glossary của Vitranslate thay đổi (ví dụ sau các phiên `learner`), chạy:

```bash
git -C Vitranslate pull
python3 Tools/build_glossary.py Vitranslate ViPathTranslate/Resources/glossary.json pathology
python3 Tools/test_matcher.py ViPathTranslate/Resources/glossary.json   # kiểm tra nhanh
```

Muốn thêm ngành khác thì truyền thêm tên ngành, ví dụ `pathology data_analysis`. Hiện chỉ `pathology` có glossary đầy đủ.

### Mâu thuẫn trong glossary gốc (nên chốt lại trong Vitranslate)

Script phát hiện một số thuật ngữ có nhiều bản dịch khác nhau trong `glossary/pathology.md`. Với các thuật ngữ này, app chèn tất cả các nghĩa và để mô hình chọn theo ngữ cảnh. Màn hình *Thuật ngữ* đánh dấu chúng là "nhiều nghĩa".

| Thuật ngữ | Các bản dịch |
|---|---|
| follicular lymphoma | u lympho dạng nang / lymphôm dạng nang |
| squamous cell carcinoma | ung thư biểu mô tế bào gai / carcinôm tế bào gai |
| DLBCL | DLBCL / lymphôm tế bào B lớn lan tỏa / giữ nguyên |
| nodular goiter | phình giáp / bướu giáp nhân |
| concordance | thống nhất chẩn đoán / đồng thuận |
| intranodal thyroid inclusions | thể vùi tuyến giáp trong hạch / mô tuyến giáp vùi trong hạch |
| MF, differentiation, EQA, somatic, rearrangement | khác nghĩa theo ngữ cảnh (phân bào / u sùi dạng nấm; biệt hóa / tách màu…) |

## Cấu trúc

| File | Vai trò |
|---|---|
| `SpeechOutput.swift` | Đọc bản dịch: giọng iOS hoặc VieNeu, tự chuyển sang giọng iOS khi VieNeu lỗi |
| `GPBSpeechNormalizer.swift` | Chuẩn hoá ký hiệu GPB trước khi đọc (1p/19q, TNM, HGVS) |
| `VieNeuEngine.swift` / `VieNeuPlayer.swift` | Gọi audio.cpp + sea-g2p qua C API, phát PCM |
| `VoiceLabView.swift` | Màn hình Giọng đọc: nạp VieNeu, đo RTF, so với giọng iOS |
| `Tools/build_vieneu_ios.sh` | Build XCFramework, tải mô hình, gắn vào dự án |
| `ViPathTranslate.xcodeproj` | Dự án Xcode, 2 target, package MLX đã khai báo |
| `ViPathTranslateApp.swift` | Điểm khởi chạy, 5 tab Dịch / Phụ đề / Chép lời / Thuật ngữ / Đã lưu; dừng sinh văn bản khi app ra nền |
| `LiveTyping.swift` | Dịch khi gõ (debounce, bộ nhớ đệm theo câu), `AppActivity` |
| `SentenceSplitter.swift` | Tách câu an toàn với viết tắt y khoa |
| `SpeechInput.swift` | Nhận dạng tiếng Anh (SpeechAnalyzer), chuyển định dạng âm thanh, nguồn Micro / Âm thanh app |
| `LiveCaptions.swift` / `LiveCaptionsView.swift` | Hàng đợi phụ đề, cơ chế đuổi kịp, giao diện |
| `Shared/SharedAudio.swift` | App Group dùng chung giữa app và extension |
| `ViPathBroadcast/SampleHandler.swift` | Broadcast Upload Extension lấy âm thanh Zoom/Teams |
| `ModelCatalog.swift` | Danh sách mô hình, dung lượng, mô tả |
| `Glossary.swift` | Đọc glossary.json + thuật ngữ riêng, `GlossaryMatcher`, `GlossaryQA` |
| `PromptBuilder.swift` | Prompt cho Qwen3.5 (chat template) và TranslateGemma (prompt thô), `Segmenter` |
| `TranslationEngine.swift` | Nạp mô hình MLX, sinh văn bản dạng stream |
| `TranslatorViewModel.swift` | Trạng thái dịch theo đoạn, chiều dịch, `LanguageGuess`, gọi Claude, lưu |
| `PHIRedactor.swift` | Che / khôi phục thông tin định danh trước khi gửi Claude |
| `ClaudeService.swift` / `KeychainHelper.swift` | Claude Messages API, theo dõi mạng, key trong Keychain |
| `ClaudeViews.swift` | Cài đặt Claude, màn hình xác nhận che định danh, duyệt thuật ngữ |
| `TermSuggestionStore.swift` | Hàng đợi thuật ngữ Claude đề xuất (vòng học) |
| `FileTranscriber.swift` | Trích âm thanh, nhận dạng có mốc thời gian, chia đoạn phụ đề, xuất SRT/VTT |
| `WhisperEngine.swift` | Tải mô hình Whisper, chạy WhisperKit trên Neural Engine, cắt cửa sổ theo chỗ im lặng |
| `TranscribeController.swift` / `TranscribeView.swift` | Tab Chép lời: dịch từng đoạn, nghe lại theo timeline, chép, xuất, lưu |
| `TextRecognizer.swift` / `ImageTextView.swift` | Trích chữ từ ảnh / PDF / máy quét (Vision), chép và dịch 2 chiều |
| `FastTranslator.swift` | Dịch nhanh bằng Apple Translation, tải gói ngôn ngữ |
| `SavedStore.swift` / `SavedViews.swift` | Lưu bản dịch, phụ đề; tab Đã lưu |
| `Tools/test_redactor.py` | Bản Python của bộ che định danh để kiểm thử |
| `TranslatorView.swift` / `GlossaryView.swift` | Giao diện |
| `Tools/build_glossary.py` | Chuyển glossary Markdown của Vitranslate → JSON |
| `Tools/test_matcher.py` | Bản Python của bộ khớp thuật ngữ để kiểm thử |
| `Tools/test_sentences.py` | Bản Python của bộ tách câu để kiểm thử |

## Giới hạn hiện tại

- **Mới chạy thử trên iPhone 18 Pro Max.** Tốc độ, RAM và nhiệt độ trên iPhone 15/16 Pro Max (8 GB) và 17 Pro Max chưa được đo.
- **Nhận dạng thuật ngữ hiếm khi nghe** (ví dụ "pleomorphic xanthoastrocytoma", "SMARCB1") chưa được kiểm chứng. Nếu bước nhận dạng nghe sai thì bước dịch cũng sai theo. Apple cho phép gợi ý từ vựng (contextual strings) với `DictationTranscriber`, theo phản ánh trên diễn đàn thì `SpeechTranscriber` chưa hỗ trợ. Đây là hướng cải thiện tiếp theo.
- **Định dạng âm thanh của ReplayKit** (endianness, tần số lấy mẫu) và bộ nhớ của extension cần kiểm tra trên máy thật.
- **Phụ đề Việt → Anh** dùng bộ nhận dạng tiếng Việt của Apple (chốt câu theo chỗ ngừng nói) hoặc PhoWhisper / Whisper turbo; độ trễ thực tế cần đo thêm với bài giảng dài.
- **Bộ che định danh dựa trên quy tắc.** Bộ che bắt tốt các trường có nhãn và họ tên tiếng Việt phổ biến, nhưng có thể sót tên nước ngoài không có nhãn hoặc tên viết thường. Vì vậy màn hình xác nhận là bắt buộc; luôn đọc lại trước khi gửi.
- **Chất lượng offline.** Mô hình 2–9B kém Claude ở câu phức. Bản dịch dùng cho hồ sơ bệnh án hoặc ấn phẩm vẫn cần bác sĩ duyệt.
- **Chưa xử lý file.** Chưa đọc trực tiếp file .docx/.pptx/.pdf; hiện chỉ nhập hoặc dán văn bản.
