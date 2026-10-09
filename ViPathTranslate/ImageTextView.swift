import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Một ảnh / trang đã nhận dạng.
struct OCRPage: Identifiable {
    let id = UUID()
    let image: UIImage
    let label: String
    var pdfText: String?
    var result: OCRResult?
    var failed: String?
}

/// Trích chữ từ ảnh (Thư viện ảnh, máy ảnh quét tài liệu, tệp ảnh / PDF, ảnh trong bộ nhớ tạm).
@MainActor
@Observable
final class ImageTextModel {
    var pages: [OCRPage] = []
    var text = ""
    var isWorking = false
    var progress = ""
    var errorText: String?
    var language: OCRLanguage = OCRLanguage(rawValue: UserDefaults.standard.string(forKey: "ocrLanguage") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "ocrLanguage") }
    }
    var joinWrapped: Bool = UserDefaults.standard.object(forKey: "ocrJoinWrapped") as? Bool ?? true {
        didSet { UserDefaults.standard.set(joinWrapped, forKey: "ocrJoinWrapped") }
    }

    var averageConfidence: Float? {
        let rs = pages.compactMap(\.result).filter { !$0.fromPDFText && $0.lines > 0 }
        guard !rs.isEmpty else { return nil }
        return rs.map(\.confidence).reduce(0, +) / Float(rs.count)
    }

    func add(images: [UIImage], label: String) async {
        let start = pages.count
        for (i, img) in images.enumerated() {
            pages.append(OCRPage(image: Self.downscaled(img), label: "\(label) \(start + i + 1)"))
        }
        await recognize(from: start)
    }

    func add(pdf url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else {
            errorText = "Không mở được PDF."
            return
        }
        let start = pages.count
        let name = url.deletingPathExtension().lastPathComponent
        isWorking = true
        for i in 0..<min(doc.pageCount, 60) {
            guard let page = doc.page(at: i) else { continue }
            progress = "Đang đọc trang \(i + 1)/\(doc.pageCount)…"
            let bounds = page.bounds(for: .mediaBox)
            let scale = 2200 / max(bounds.width, bounds.height, 1)
            let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                                       for: .mediaBox)
            let raw = page.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usable = (raw?.filter(\.isLetter).count ?? 0) >= 20 ? raw : nil
            pages.append(OCRPage(image: image, label: "\(name) · tr. \(i + 1)", pdfText: usable))
            await Task.yield()
        }
        if doc.pageCount > 60 { errorText = "Chỉ đọc 60 trang đầu của PDF." }
        await recognize(from: start)
    }

    func add(imageFile url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else {
            errorText = "Không đọc được ảnh \(url.lastPathComponent)."
            return
        }
        await add(images: [img], label: "Ảnh")
    }

    /// Nhận dạng lại tất cả (vd. sau khi đổi ngôn ngữ).
    func rerun() async {
        for i in pages.indices { pages[i].result = nil; pages[i].failed = nil }
        await recognize(from: 0)
    }

    private func recognize(from start: Int) async {
        isWorking = true
        defer { isWorking = false; progress = "" }
        for i in start..<pages.count {
            progress = "Đang nhận dạng \(i + 1)/\(pages.count)…"
            if let t = pages[i].pdfText {
                pages[i].result = OCRResult(text: t, lines: t.split(whereSeparator: \.isNewline).count,
                                            confidence: 1, fromPDFText: true)
                continue
            }
            do {
                pages[i].result = try await TextRecognizer.recognize(pages[i].image, language: language,
                                                                      joinWrapped: joinWrapped)
            } catch {
                pages[i].failed = error.localizedDescription
            }
        }
        rebuildText()
    }

    func rebuildText() {
        text = pages.compactMap { $0.result?.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func remove(_ page: OCRPage) {
        pages.removeAll { $0.id == page.id }
        rebuildText()
    }

    func clear() {
        pages = []
        text = ""
        errorText = nil
    }

    /// Thu nhỏ ảnh quá lớn (ảnh 48 MP) để OCR nhanh, đỡ tốn bộ nhớ; vẫn đủ nét cho chữ.
    static func downscaled(_ image: UIImage, maxSide: CGFloat = 3000) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Màn hình "Chữ trong ảnh": chọn ảnh → trích chữ → sửa / chép / dịch hai chiều.
struct ImageTextView: View {
    @Environment(TranslatorViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var model = ImageTextModel()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showImporter = false
    @State private var showScanner = false
    @State private var copied = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    sourceButtons
                    Picker("Ngôn ngữ chữ", selection: $model.language) {
                        ForEach(OCRLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: model.language) { _, _ in
                        if !model.pages.isEmpty { Task { await model.rerun() } }
                    }
                    Toggle("Nối dòng bị ngắt giữa câu", isOn: $model.joinWrapped)
                        .onChange(of: model.joinWrapped) { _, _ in
                            if !model.pages.isEmpty { Task { await model.rerun() } }
                        }
                } footer: {
                    Text(TextRecognizer.supportsVietnamese
                         ? "Nhận dạng chạy trên iPhone bằng Apple Vision, hỗ trợ tiếng Việt có dấu và tiếng Anh, không cần mạng. PDF có lớp chữ được đọc trực tiếp."
                         : "Máy này chưa có nhận dạng chữ tiếng Việt; chỉ nhận dạng được chữ Latin không dấu.")
                }

                if !model.pages.isEmpty {
                    Section {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(model.pages) { p in thumbnail(p) }
                            }
                            .padding(.vertical, 4)
                        }
                        if model.isWorking {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(model.progress).font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let c = model.averageConfidence {
                            Text("\(model.pages.count) ảnh/trang · độ tin cậy trung bình \(Int(c * 100))%"
                                 + (c < 0.6 ? " — nên chụp lại rõ hơn" : ""))
                                .font(.caption)
                                .foregroundStyle(c < 0.6 ? .orange : .secondary)
                        }
                    }
                }

                if let e = model.errorText {
                    Section { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }

                if !model.text.isEmpty || (!model.pages.isEmpty && !model.isWorking) {
                    Section {
                        TextEditor(text: $model.text)
                            .focused($editorFocused)
                            .frame(minHeight: 220)
                            .font(.callout)
                        if model.text.isEmpty {
                            Text("Không tìm thấy chữ trong ảnh.").foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Text("Văn bản trích được")
                            Spacer()
                            Text("\(model.text.count) ký tự").monospacedDigit()
                        }
                    } footer: {
                        Text("Sửa trực tiếp nếu cần trước khi chép hoặc dịch.")
                    }

                    Section {
                        Button(copied ? "Đã chép" : "Chép văn bản", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = model.text
                            copied = true
                        }
                        .disabled(model.text.isEmpty)
                        Button("Dịch (tự nhận chiều)", systemImage: "character.book.closed") { translate(.auto) }
                            .disabled(model.text.isEmpty)
                        Button("Dịch Anh → Việt", systemImage: "arrow.right") { translate(.enToVi) }
                            .disabled(model.text.isEmpty)
                        Button("Dịch Việt → Anh", systemImage: "arrow.left") { translate(.viToEn) }
                            .disabled(model.text.isEmpty)
                    } footer: {
                        Text(vm.loadedModel == nil
                             ? "Chưa nạp mô hình: văn bản sẽ được đưa vào ô nhập của tab Dịch để bạn dịch sau."
                             : "Văn bản được đưa vào tab Dịch và dịch ngay bằng mô hình offline (có thể hiệu đính bằng Claude).")
                    }
                }
            }
            .navigationTitle("Chữ trong ảnh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Xoá hết", systemImage: "trash") { model.clear() }
                        .disabled(model.pages.isEmpty || model.isWorking)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Xong") { editorFocused = false }
                }
            }
            .onChange(of: model.text) { _, _ in copied = false }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .pdf],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    for url in urls {
                        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                            await model.add(pdf: url)
                        } else {
                            await model.add(imageFile: url)
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    if !images.isEmpty { Task { await model.add(images: images, label: "Quét") } }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var sourceButtons: some View {
        VStack(spacing: 8) {
            HStack {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .images) {
                    Label("Thư viện ảnh", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { showScanner = true } label: {
                    Label("Quét / chụp", systemImage: "doc.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!VNDocumentCameraViewController.isSupported)
            }
            HStack {
                Button { showImporter = true } label: {
                    Label("Tệp ảnh / PDF", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    if let img = UIPasteboard.general.image {
                        Task { await model.add(images: [img], label: "Ảnh dán") }
                    } else {
                        model.errorText = "Bộ nhớ tạm không có ảnh."
                    }
                } label: {
                    Label("Dán ảnh", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.regular)
        .disabled(model.isWorking)
    }

    private func thumbnail(_ p: OCRPage) -> some View {
        VStack(spacing: 4) {
            Image(uiImage: p.image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 96)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    Button { model.remove(p) } label: {
                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                    .disabled(model.isWorking)
                }
            Group {
                if let r = p.result {
                    Text(r.fromPDFText ? "lớp chữ PDF" : "\(r.lines) dòng")
                } else if p.failed != nil {
                    Text("lỗi").foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                images.append(img)
            }
        }
        photoItems = []
        await model.add(images: images, label: "Ảnh")
    }

    private func translate(_ mode: DirectionMode) {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        vm.stop()
        vm.input = text
        vm.directionMode = mode
        dismiss()
        if vm.loadedModel != nil {
            Task {
                try? await Task.sleep(for: .milliseconds(350))   // chờ sheet đóng
                vm.translate()
            }
        }
    }
}

// MARK: - Máy quét tài liệu (VisionKit): tự căn phẳng, cắt viền, nhiều trang

struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onFinish([])
        }
    }
}
