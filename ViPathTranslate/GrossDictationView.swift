import SwiftUI
import UIKit
import VisionKit

/// Tab "Đại thể": đọc mô tả khi phẫu tích – cắt lọc bệnh phẩm, rảnh tay bằng lệnh giọng nói.
struct GrossDictationView: View {
    @Environment(GrossDictationController.self) private var ctl
    @Environment(TranslatorViewModel.self) private var vm
    @Environment(AppRouter.self) private var router
    @AppStorage("grossLargeText") private var largeText = true
    @State private var showHelp = false
    @State private var showCorrections = false
    @State private var showChecklist = true
    @State private var confirmClear = false
    @State private var showScanner = false
    @State private var toast: String?

    private var textFont: Font { largeText ? .title3 : .body }

    var body: some View {
        @Bindable var ctl = ctl
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        setupRow
                        if showChecklist, let t = ctl.template { checklist(t) }
                        bodyCard
                        ForEach(Array(ctl.doc.cassettes.enumerated()), id: \.element.id) { i, c in
                            cassetteCard(i, c).id(c.id)
                        }
                        Button {
                            ctl.addCassette()
                        } label: {
                            Label("Thêm cát xét", systemImage: "plus.square.on.square")
                        }
                        .buttonStyle(.bordered)
                        if let e = ctl.errorText {
                            Text(e).font(.footnote).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 90).id("bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: ctl.doc.target) { _, t in
                    withAnimation {
                        if t >= 0, t < ctl.doc.cassettes.count { proxy.scrollTo(ctl.doc.cassettes[t].id, anchor: .center) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { controlBar }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast).font(.footnote.bold()).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: .capsule).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle("Đại thể")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showHelp) { GrossCommandHelp() }
            .sheet(isPresented: $showCorrections) { GrossCorrectionsView() }
            .sheet(isPresented: $showScanner) {
                PathcodeScannerSheet { code in
                    showScanner = false
                    if let code, !code.isEmpty { ctl.pathcode = code; flash("Pathcode: \(ctl.pathcode)") }
                }
            }
            .confirmationDialog("Xoá toàn bộ nội dung đang đọc?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Xoá trang", role: .destructive) { ctl.clear() }
            }
        }
    }

    // MARK: Thiết lập

    private var setupRow: some View {
        @Bindable var ctl = ctl
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Ngôn ngữ", selection: $ctl.language) {
                    Text("Tiếng Việt").tag(TranscriptLanguage.vi)
                    Text("English").tag(TranscriptLanguage.en)
                }
                .pickerStyle(.segmented)
                .disabled(ctl.isRunning)
                Menu {
                    Picker("Loại bệnh phẩm", selection: $ctl.templateID) {
                        ForEach(GrossTemplate.all) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Hiện gợi ý cấu trúc", isOn: $showChecklist)
                } label: {
                    Label(ctl.template?.name ?? "Mẫu", systemImage: "list.bullet.clipboard")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                Image(systemName: "barcode").foregroundStyle(.secondary)
                TextField("Pathcode của ca (hoặc nói “mã ca …”)", text: $ctl.pathcode)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                if PathcodeScannerSheet.isAvailable {
                    Button { showScanner = true } label: { Image(systemName: "barcode.viewfinder") }
                        .accessibilityLabel("Quét mã vạch trên nhãn")
                }
                Button("Ca mới") { flash(ctl.newCase() ? "Đã lưu ca trước" : "Trang mới") }
                    .disabled(ctl.isRunning || ctl.isRewriting)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        }
    }

    private func checklist(_ t: GrossTemplate) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(t.items, id: \.self) { item in
                    Text(item).font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.1), in: .capsule)
                }
            }
        }
    }

    // MARK: Nội dung

    private var bodyCard: some View {
        @Bindable var ctl = ctl
        let active = ctl.doc.target < 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MÔ TẢ ĐẠI THỂ").font(.caption.bold()).foregroundStyle(active ? Color.accentColor : .secondary)
                if active && ctl.isRunning { RecordingDot(paused: ctl.isPaused) }
                Spacer()
                if !active {
                    Button("Ghi vào đây") { ctl.select(target: -1) }.font(.caption)
                }
            }
            TextField("Bấm micro rồi đọc: “Bệnh phẩm gồm ba mảnh, kích thước…”", text: $ctl.doc.body, axis: .vertical)
                .font(textFont)
                .lineLimit(4...)
            if active, !ctl.volatileText.isEmpty {
                Text(ctl.volatileText).font(textFont).italic().foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.accentColor : .clear, lineWidth: 2))
    }

    /// Binding theo id (không theo chỉ số) → xoá cát xét khi đang hiển thị không làm lỗi vượt chỉ số.
    private func cassetteText(_ id: UUID) -> Binding<String> {
        Binding(get: { ctl.doc.cassettes.first { $0.id == id }?.text ?? "" },
                set: { v in
                    if let k = ctl.doc.cassettes.firstIndex(where: { $0.id == id }) { ctl.doc.cassettes[k].text = v }
                })
    }

    private func cassetteCard(_ i: Int, _ c: GrossCassette) -> some View {
        let active = ctl.doc.target == i
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(c.pathcode.isEmpty ? c.code : "\(c.pathcode) · \(c.code)")
                    .font(.headline.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(active ? Color.accentColor : Color(.tertiarySystemFill), in: .rect(cornerRadius: 6))
                    .foregroundStyle(active ? .white : .primary)
                if active && ctl.isRunning { RecordingDot(paused: ctl.isPaused) }
                Spacer()
                if !active { Button("Ghi vào đây") { ctl.select(target: i) }.font(.caption) }
                Menu {
                    Button("Xoá cát xét", systemImage: "trash", role: .destructive) { ctl.deleteCassette(at: i) }
                } label: { Image(systemName: "ellipsis") }
            }
            TextField("Vị trí lấy mẫu…", text: cassetteText(c.id), axis: .vertical)
                .font(textFont)
            if active, !ctl.volatileText.isEmpty {
                Text(ctl.volatileText).font(textFont).italic().foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.accentColor : .clear, lineWidth: 2))
    }

    // MARK: Thanh điều khiển (nút lớn, dễ bấm khi đeo găng)

    private var controlBar: some View {
        VStack(spacing: 6) {
            if !ctl.status.isEmpty {
                Text(ctl.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if ctl.isRunning, !ctl.lastHeard.isEmpty {
                Text("Nghe: “\(ctl.lastHeard)”").font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head).padding(.horizontal)
            }
            HStack(spacing: 18) {
                barButton("arrow.uturn.backward", "Hoàn tác") { ctl.undo() }
                    .disabled(ctl.doc.history.isEmpty)
                barButton(ctl.isPaused ? "play.fill" : "pause.fill", ctl.isPaused ? "Tiếp tục" : "Tạm dừng") { ctl.togglePause() }
                    .disabled(!ctl.isRunning)
                Button {
                    Task { if ctl.isRunning { await ctl.stop() } else { await ctl.start() } }
                } label: {
                    Image(systemName: ctl.isRunning ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 76, height: 76)
                        .background(ctl.isRunning ? Color.red : Color.accentColor, in: .circle)
                        .foregroundStyle(.white)
                }
                .disabled(ctl.isRewriting)
                .accessibilityLabel(ctl.isRunning ? "Dừng ghi" : "Bắt đầu ghi")
                barButton("plus.square.on.square", "Cát xét +") { ctl.addCassette() }
                barButton("text.alignleft", "Mô tả") { ctl.select(target: -1) }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func barButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(width: 56, height: 52)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    // MARK: Thanh công cụ

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                .accessibilityLabel("Lệnh giọng nói")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                UIPasteboard.general.string = ctl.reportText
                flash("Đã chép")
            } label: { Image(systemName: "doc.on.doc") }
                .disabled(ctl.doc.isEmpty)
            Menu {
                Button("Lưu", systemImage: "tray.and.arrow.down") {
                    flash(ctl.save() ? "Đã lưu vào tab Đã lưu" : "Chưa có nội dung để lưu")
                }
                ShareLink(item: ctl.reportText) { Label("Chia sẻ", systemImage: "square.and.arrow.up") }
                Button(ctl.language == .vi ? "Dịch sang tiếng Anh" : "Dịch sang tiếng Việt", systemImage: "character.book.closed") {
                    translate()
                }
                Divider()
                Button("Chép lại bằng \(ctl.whisperModel.title)", systemImage: "waveform.badge.magnifyingglass") {
                    Task { await ctl.rewriteWithWhisper() }
                }
                .disabled(!ctl.canRewrite)
                Toggle("Giữ bản ghi âm của phiên", isOn: Binding(get: { ctl.keepAudio }, set: { ctl.keepAudio = $0 }))
                Toggle("Ghi chú cát xét xong quay lại mô tả", isOn: Binding(get: { ctl.cassetteReturn }, set: { ctl.cassetteReturn = $0 }))
                Toggle("Chèn mã “(A1)” vào mô tả", isOn: Binding(get: { ctl.inlineMarker }, set: { ctl.inlineMarker = $0 }))
                Toggle("Chữ lớn", isOn: $largeText)
                Button("Sửa lỗi nhận dạng…", systemImage: "character.cursor.ibeam") { showCorrections = true }
                Divider()
                Button("Xoá trang", systemImage: "trash", role: .destructive) { confirmClear = true }
                    .disabled(ctl.isRunning || ctl.isRewriting)
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func translate() {
        let text = ctl.reportText
        guard !text.isEmpty else { return }
        vm.stop()
        vm.directionMode = ctl.language == .vi ? .viToEn : .enToVi
        vm.input = text
        router.tab = .translate
        if vm.loadedModel != nil { vm.translate() }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { toast = nil }
        }
    }
}

private struct RecordingDot: View {
    let paused: Bool
    @State private var on = false
    var body: some View {
        Circle().fill(paused ? Color.orange : Color.red).frame(width: 8, height: 8)
            .opacity(paused ? 1 : (on ? 1 : 0.25))
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { on = true } }
    }
}

// MARK: - Bảng lệnh

struct GrossCommandHelp: View {
    @Environment(\.dismiss) private var dismiss
    private let rows: [(String, String)] = [
        ("“mã ca gê pê bê hai bốn gạch …”", "Đặt pathcode cho ca (gõ hoặc quét mã vạch chính xác hơn)"),
        ("“… chấm mực xanh, cát xét A1 diện cắt gần”", "Chèn (A1) vào mô tả, ghi “diện cắt gần” vào A1, rồi tự quay lại mô tả"),
        ("“cát xét A1”, “mẫu bê hai”, “cát xét số 3”", "Mở cát xét — câu kế tiếp là ghi chú của cát xét đó"),
        ("“cát xét tiếp theo”, “khối tiếp”", "Cát xét kế tiếp (A1 → A2)"),
        ("“quay lại mô tả”", "Ghi tiếp vào phần mô tả đại thể"),
        ("“xuống dòng”, “đoạn mới”, “gạch đầu dòng”", "Định dạng"),
        ("“dấu chấm”, “dấu phẩy”, “dấu hai chấm”, “mở ngoặc” / “đóng ngoặc”", "Dấu câu"),
        ("“xoá câu”, “hoàn tác”", "Bỏ câu vừa đọc"),
        ("“tạm dừng” / “tiếp tục ghi”", "Ngừng nghe khi trao đổi với KTV; nói tiếp để ghi lại"),
        ("“dừng ghi”", "Kết thúc phiên"),
    ]
    private let numbers: [(String, String)] = [
        ("bốn nhân ba nhân hai xăng ti mét", "4 x 3 x 2 cm"),
        ("hai phẩy năm phân / hai phân rưỡi", "2,5 cm"),
        ("từ hai đến năm mi li mét", "từ 2 đến 5 mm"),
        ("nặng hai mươi lăm gam", "nặng 25 g"),
        ("ba mảnh, mười hai hạch", "3 mảnh, 12 hạch"),
        ("chiếm ba mươi phần trăm", "chiếm 30%"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Lệnh giọng nói") {
                    ForEach(rows, id: \.0) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.0).font(.subheadline.bold())
                            Text(r.1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(numbers, id: \.0) { r in
                        LabeledContent(r.0) { Text(r.1).font(.body.monospaced()) }.font(.subheadline)
                    }
                } header: { Text("Số đo tự chuẩn hoá") } footer: {
                    Text("Chỉ đổi chữ số khi đứng cạnh đơn vị, “nhân” hoặc danh từ đếm — “một đoạn đại tràng” vẫn giữ nguyên.")
                }
                Section {
                    Text("Mọi thứ nhận dạng trên iPhone, không gửi đi đâu. Dùng được AirPods / tai nghe Bluetooth để đứng xa máy. Màn hình không tự khoá khi đang ghi.")
                        .font(.footnote)
                    Text("Đọc xong có thể bấm ⋯ → Chép lại bằng PhoWhisper để nhận dạng lại toàn bộ bản ghi chính xác hơn (cần tải mô hình ở tab Chép lời).")
                        .font(.footnote)
                }
            }
            .navigationTitle("Hướng dẫn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }
}

// MARK: - Sửa lỗi nhận dạng

struct GrossCorrectionsView: View {
    @Environment(GrossDictationController.self) private var ctl
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        @Bindable var ctl = ctl
        NavigationStack {
            List {
                Section {
                    TextField("Máy nghe thành (vd. các xi nôm)", text: $from)
                    TextField("Sửa thành (vd. carcinôm)", text: $to)
                    Button("Thêm") {
                        let f = from.trimmingCharacters(in: .whitespaces), t = to.trimmingCharacters(in: .whitespaces)
                        guard !f.isEmpty, !t.isEmpty else { return }
                        ctl.corrections.insert(GrossCorrection(from: f, to: t), at: 0)
                        from = ""; to = ""
                    }
                    .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty || to.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Áp dụng cho mọi câu đọc sau đó. Từ “Sửa thành” cũng được gợi ý cho bộ nhận dạng.")
                }
                Section("Danh sách") {
                    ForEach($ctl.corrections) { $c in
                        HStack {
                            TextField("nghe thành", text: $c.from)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("sửa thành", text: $c.to)
                        }
                    }
                    .onDelete { ctl.corrections.remove(atOffsets: $0) }
                }
            }
            .navigationTitle("Sửa lỗi nhận dạng")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }
}

// MARK: - Quét pathcode trên nhãn bệnh phẩm

/// Camera quét mã vạch (tự nhận) hoặc chạm vào dòng chữ pathcode trên nhãn / phiếu.
struct PathcodeScannerSheet: View {
    let onResult: (String?) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            PathcodeScanner(onResult: onResult)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("Hướng camera vào mã vạch trên nhãn — hoặc chạm vào dòng chữ pathcode")
                        .font(.footnote.bold()).padding(10)
                        .background(.thinMaterial, in: .capsule).padding(.bottom, 30)
                }
                .navigationTitle("Quét pathcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { onResult(nil) } } }
        }
    }
}

private struct PathcodeScanner: UIViewControllerRepresentable {
    let onResult: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(), .text()],
                                           qualityLevel: .accurate,
                                           recognizesMultipleItems: true,
                                           isHighFrameRateTrackingEnabled: false,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onResult: (String?) -> Void
        private var done = false
        init(onResult: @escaping (String?) -> Void) { self.onResult = onResult }

        private func finish(_ s: String) {
            let code = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !done, !code.isEmpty else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onResult(code)
        }

        // Mã vạch: nhận ngay khi thấy
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let v = b.payloadStringValue { finish(v); return }
            }
        }

        // Camera bị từ chối / không dùng được → đóng, không để màn hình chết
        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !done else { return }
            done = true
            onResult(nil)
        }

        // Chữ: chạm vào dòng pathcode
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            switch item {
            case .barcode(let b): if let v = b.payloadStringValue { finish(v) }
            case .text(let t): finish(t.transcript)
            @unknown default: break
            }
        }
    }
}
