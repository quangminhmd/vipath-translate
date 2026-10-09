# ViPath Web

Bản trình duyệt của ViPath Translate, gói trong một tệp: `ViPath.html`.

## Mở
- **Máy Mac:** bấm đúp `serve.command`. Tệp này mở Chrome hoặc Safari tại `http://localhost:8765/ViPath.html`.
  - Nên mở qua máy chủ cục bộ như vậy: trình duyệt mới giữ lại mô hình đã tải và cho dùng micro.
  - Mở thẳng tệp HTML vẫn chạy được, nhưng có thể phải tải lại mô hình mỗi lần.
- **Windows:** đặt `ViPath.html` và `serve-windows.bat` cùng một thư mục, rồi bấm đúp `serve-windows.bat`. Không cần cài gì thêm: nếu máy không có Python, tệp này dùng PowerShell có sẵn của Windows. Chrome sẽ mở `http://localhost:8765/ViPath.html`.
- **Linux:** chạy `python3 -m http.server 8765` trong thư mục này rồi mở `http://localhost:8765/ViPath.html`.
- **iPhone (Safari iOS 26+):** trang phải nằm trên một địa chỉ `https://`, ví dụ GitHub Pages hoặc Netlify. Safari không chạy được tệp HTML mở từ ứng dụng Tệp.

## Tính năng (giống bản app)

| Tab | Chạy bằng |
|---|---|
| Dịch Anh ↔ Việt + glossary Vitranslate (487 mục), dịch khi gõ | WebLLM: Qwen3.5 2B / 4B / 9B trên WebGPU, offline sau lần tải đầu |
| Claude (tuỳ chọn) | API key của bạn, lưu trong trình duyệt. Che định danh và bắt buộc xác nhận trước khi gửi. Có vòng học thuật ngữ |
| Phụ đề hai khung | Micro hoặc âm thanh tab (Zoom / Teams / Meet trên Chrome máy tính). Nhận dạng bằng trình duyệt hoặc Whisper offline |
| ⚡ Dịch nhanh | Translator tích hợp trong Chrome 138+ (máy tính); bản chuẩn có glossary thay vào sau |
| Chép lời tệp | Whisper large-v3 turbo / small / base (Transformers.js). Có timeline, xuất SRT / VTT / TXT |
| Chữ trong ảnh | Tesseract.js (Việt + Anh), PDF qua pdf.js. Chép, hoặc dịch hai chiều |
| Thuật ngữ, Đã lưu | Lưu trong IndexedDB của trình duyệt, không gửi đi đâu |
| Đọc tiếng Việt | Giọng tiếng Việt của hệ điều hành, kèm chuẩn hoá ký hiệu GPB (p.R132H, 1p/19q, CD20) |

## Khác bản app iPhone
- Không có VieNeu-TTS và Apple Translation. Mô hình PhoWhisper chưa có bản cho trình duyệt; dùng Whisper large-v3 turbo cho tiếng Việt.
- Trình duyệt trên điện thoại không thu được âm thanh của app khác.
- Bộ nhận dạng giọng nói của Chrome gửi âm thanh lên máy chủ Google. Muốn hoàn toàn offline, chọn Whisper.

## Sửa mã
Mã nguồn nằm trong `src/`. Sau khi sửa, chạy `python3 build.py` để ghép lại `ViPath.html`, và `node test/test_logic.mjs` để kiểm thử phần logic.
