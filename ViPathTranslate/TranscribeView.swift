import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Tab "Chép lời": chọn tệp ghi âm / video → bản ghi lời có mốc thời gian → dịch, chép, xuất phụ đề.
struct TranscribeView: View {
    @Environment(TranslatorViewModel.self) private var vm
    @Environment(TranscribeController.self) private var tc
    @State private var showImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var editing: TranscriptSegment?
    @State private var toast: String?
    @State private var followPlayback = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List {
                        Section { headerCard }
                        if !tc.segments.isEmpty {
                            Section {
                                ForEach(tc.segments) { seg in
                                    SegmentLine(segment: seg, display: tc.display,
                                                isCurrent: tc.currentSegmentID == seg.id,
                                                isTranslating: tc.translatingID == seg.id) {
                                        tc.play(from: seg.start)
                                    }
                                    .id(seg.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editing = seg }
                                    .contextMenu { rowMenu(seg) }
                                    .swipeActions {
                                        Button("Xoá", systemImage: "trash", role: .destructive) { tc.delete(seg.id) }
                                    }
                                }
                            } header: {
                                transcriptHeader
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .onChange(of: tc.currentSegmentID) { _, id in
                        if tc.isPlaying, followPlayback, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: tc.segments.count) { old, new in
                        if tc.isBusy, new > old, let last = tc.segments.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                if tc.audioURL != nil && !tc.segments.isEmpty { playerBar }
            }
            .navigationTitle("Chép lời")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .movie, .audiovisualContent, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { tc.importFile(url) }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            .sheet(item: $editing) { seg in
                SegmentEditor(segment: seg, direction: tc.language.direction,
                              canTranslate: vm.loadedModel != nil) { text, translation, retranslate in
                    tc.update(seg.id, text: text, translation: translation)
                    if retranslate { tc.retranslate(seg.id) }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 70)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: Phần đầu: tệp, ngôn ngữ, trạng thái

    @ViewBuilder
    private var headerCard: some View {
        @Bindable var tc = tc
        VStack(alignment: .leading, spacing: 12) {
            Picker("Ngôn ngữ nói", selection: $tc.language) {
                ForEach(TranscriptLanguage.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(tc.isBusy)

            engineRow

            DisclosureGroup {
                FastTranslateSettings(directions: [tc.language.direction])
            } label: {
                FastStatusLabel(direction: tc.language.direction)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))

            if tc.fileName.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic").font(.system(size: 40)).foregroundStyle(.tint)
                    Text("Chọn tệp ghi âm hoặc video để tạo bản ghi lời có mốc thời gian, rồi dịch và xuất phụ đề.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    importButtons
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                fileRow
                statusRow
                if !tc.segments.isEmpty { translateRow }
            }
            if let err = tc.errorText {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    /// Đồng hồ thời gian chờ nạp Whisper; quá 4 phút trên Neural Engine thì gợi ý chuyển sang GPU.
    @ViewBuilder
    private func loadingTimer(title: String) -> some View {
        if let since = tc.loadStartedAt {
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                let secs = Int(ctx.date.timeIntervalSince(since))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(title) \(secs / 60):\(String(format: "%02d", secs % 60))")
                            .font(.caption.monospacedDigit())
                    }
                    if tc.whisperCompute == .neuralEngine && secs >= 240 {
                        Text("iOS vẫn đang tối ưu mô hình cho Neural Engine. Có thể chờ thêm (chỉ lần đầu), hoặc:")
                            .font(.caption2).foregroundStyle(.orange)
                        Button("Chuyển sang GPU và chạy lại (nạp vài giây)", systemImage: "bolt.fill") {
                            tc.switchToGPUAndRetry()
                        }
                        .font(.caption.bold())
                        .buttonStyle(.glass)
                    }
                }
            }
        }
    }

    // MARK: Bộ nhận dạng — gọn: chọn mô hình · trạng thái tải/nạp · Neural Engine/GPU · tuỳ chọn ẩn

    @ViewBuilder
    private var engineRow: some View {
        @Bindable var tc = tc
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Bộ nhận dạng", systemImage: "cpu").font(.subheadline)
                Spacer()
                Picker("Bộ nhận dạng", selection: $tc.engine) {
                    ForEach(ASREngine.options(for: tc.language)) { e in
                        Text(e.title).tag(e)
                    }
                }
                .pickerStyle(.menu)
                .disabled(tc.isBusy)
            }
            if let wm = tc.engine.whisper {
                WhisperModelStatusRow(model: wm)
                    .disabled(tc.isBusy)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Gợi ý thuật ngữ GPB cho Whisper", isOn: $tc.useTermPrompt)
                        Text(tc.whisperCompute == .neuralEngine
                             ? "Neural Engine: nhanh, mát máy; lần nạp đầu iOS phải tối ưu mô hình (có thể vài phút)."
                             : "GPU: nạp trong vài giây; chạy chung GPU với mô hình dịch.")
                            .font(.caption2).foregroundStyle(.secondary)
                        if WhisperModelStore.shared.isReady(wm) {
                            Button("Xoá \(wm.title) (\(wm.sizeLabel))", systemImage: "trash", role: .destructive) {
                                WhisperModelStore.shared.delete(wm)
                            }
                            .font(.caption)
                            .disabled(tc.isBusy)
                        }
                    }
                    .font(.caption)
                } label: {
                    Text("Tuỳ chọn Whisper").font(.caption)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text("Apple Speech").font(.subheadline.bold())
                    Label("Sẵn sàng", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                if tc.language == .vi {
                    Text("Apple Speech cho tiếng Việt kém chính xác hơn — nên dùng PhoWhisper.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }

    private var importButtons: some View {
        let photoLabel = loadingPhoto ? "Đang tải…" : "Thư viện ảnh"
        return HStack {
            Button { showImporter = true } label: {
                Label("Tệp", systemImage: "folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            PhotosPicker(selection: $photoItem, matching: .videos) {
                Label(photoLabel, systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(loadingPhoto)
        }
        .controlSize(.large)
        .disabled(tc.isBusy)
    }

    private var fileRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(tc.fileName).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                Text((tc.duration > 0 ? SubtitleWriter.clock(tc.duration) + " · " : "")
                     + "Apple Speech · trên máy · \(tc.language.shortLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Chọn tệp khác…", systemImage: "folder") { showImporter = true }
                Button("Chép lời lại (\(tc.language.label))", systemImage: "arrow.clockwise") { tc.rerun() }
                    .disabled(tc.isBusy)
                Button("Đóng tệp", systemImage: "xmark", role: .destructive) { tc.clear() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if tc.isBusy {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(tc.status).font(.subheadline)
                    Spacer()
                    Text("\(Int(tc.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Huỷ", role: .destructive) { tc.cancel() }
                        .font(.caption.bold())
                }
                ProgressView(value: tc.progress)
                if tc.loadStartedAt != nil {
                    loadingTimer(title: "Đã chờ")
                }
            }
        } else if tc.phase == .done {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tc.status).font(.subheadline.bold()).foregroundStyle(.green)
                    Text(tc.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var translateRow: some View {
        @Bindable var tc = tc
        let target = tc.language.direction.targetName.lowercased()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if tc.isTranslating {
                    Button(role: .destructive) { tc.stopTranslating() } label: {
                        Label("Dừng dịch \(tc.translatedCount)/\(tc.segments.count)", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else {
                    Button { tc.translateAll() } label: {
                        Label(tc.refinedCount == 0 ? "Dịch chuẩn sang \(target)"
                              : tc.refinedCount < tc.segments.count ? "Dịch tiếp \(tc.refinedCount)/\(tc.segments.count)"
                              : "Đã dịch \(tc.segments.count) đoạn",
                              systemImage: "character.book.closed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(vm.loadedModel == nil || tc.refinedCount == tc.segments.count)
                }
            }
            .controlSize(.regular)
            if FastTranslator.shared.isActive(tc.language.direction),
               tc.translatedCount < tc.segments.count {
                Button {
                    tc.fastTranslateAll()
                } label: {
                    Label(tc.isFastTranslating ? "Đang dịch nhanh…" : "Dịch nhanh ⚡ \(tc.segments.count - tc.translatedCount) đoạn",
                          systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(tc.isFastTranslating)
            }
            if vm.loadedModel == nil {
                Text("Nạp mô hình ở tab Dịch để có bản dịch chuẩn theo glossary (Dịch nhanh vẫn dùng được).").font(.caption).foregroundStyle(.orange)
            }
            Toggle("Tự dịch khi chép lời", isOn: $tc.autoTranslate).font(.subheadline)
        }
    }

    private var transcriptHeader: some View {
        @Bindable var tc = tc
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Hiển thị", selection: $tc.display) {
                ForEach(SubtitleContent.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .textCase(nil)
            Label("Bản ghi lời · chạm mốc giờ để nghe, chạm dòng để sửa", systemImage: "text.alignleft")
                .font(.caption)
                .textCase(nil)
        }
        .padding(.bottom, 4)
    }

    // MARK: Thanh công cụ: chép / xuất / lưu

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Chọn tệp…", systemImage: "folder") { showImporter = true }
                PhotosPicker(selection: $photoItem, matching: .videos) {
                    Label("Video trong Thư viện ảnh", systemImage: "photo.on.rectangle")
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .disabled(tc.isBusy)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Section("Chép văn bản") {
                    ForEach(SubtitleContent.allCases) { c in
                        Button("Chép \(c.label.lowercased())", systemImage: "doc.on.doc") {
                            tc.copy(c, timestamps: false)
                            show("Đã chép \(c.label.lowercased())")
                        }
                    }
                }
                Section("Chép kèm mốc thời gian") {
                    ForEach(SubtitleContent.allCases) { c in
                        Button("\(c.label) + mốc giờ", systemImage: "clock") {
                            tc.copy(c, timestamps: true)
                            show("Đã chép kèm mốc thời gian")
                        }
                    }
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(tc.segments.isEmpty)

            Menu {
                ForEach(SubtitleContent.allCases) { c in
                    Section("Phụ đề · \(c.label)") {
                        ForEach([SubtitleFormat.srt, .vtt, .txt]) { f in
                            ShareLink(item: tc.file(f, c), preview: SharePreview(tc.file(f, c).fileName)) {
                                Label(f.rawValue.uppercased(), systemImage: f == .txt ? "doc.plaintext" : "captions.bubble")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(tc.segments.isEmpty)

            Button("Lưu", systemImage: "square.and.arrow.down") {
                if tc.save() { show("Đã lưu vào tab Đã lưu") }
            }
            .disabled(tc.segments.isEmpty || tc.isBusy)
        }
    }

    @ViewBuilder
    private func rowMenu(_ seg: TranscriptSegment) -> some View {
        Button("Nghe từ đây", systemImage: "play.fill") { tc.play(from: seg.start) }
        Button("Chép đoạn", systemImage: "doc.on.doc") { UIPasteboard.general.string = seg.text }
        if !seg.translation.isEmpty {
            Button("Chép bản dịch", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = seg.translation }
        }
        Button("Sửa", systemImage: "pencil") { editing = seg }
        Button("Dịch lại", systemImage: "arrow.clockwise") { tc.retranslate(seg.id) }
            .disabled(vm.loadedModel == nil || tc.isTranslating)
    }

    // MARK: Nghe lại

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button { tc.togglePlay() } label: {
                Image(systemName: tc.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34))
            }
            .accessibilityLabel(tc.isPlaying ? "Tạm dừng" : "Phát")
            Text(SubtitleWriter.clock(tc.currentTime)).font(.caption.monospacedDigit())
            Slider(value: Binding(get: { tc.currentTime }, set: { tc.seek(to: $0) }),
                   in: 0...max(tc.duration, 1))
            Text(SubtitleWriter.clock(tc.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { followPlayback.toggle() } label: {
                Image(systemName: followPlayback ? "text.line.first.and.arrowtriangle.forward" : "text.alignleft")
            }
            .accessibilityLabel("Cuộn theo lời đang phát")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 10)
    }

    // MARK: Hỗ trợ

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { toast = nil }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        loadingPhoto = true
        defer { loadingPhoto = false; photoItem = nil }
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                tc.errorText = "Không tải được video."
                return
            }
            tc.start(movie.url, name: movie.url.lastPathComponent)
        } catch {
            tc.errorText = "Không tải được video: \(error.localizedDescription)"
        }
    }
}

/// Video lấy từ Thư viện ảnh (chép ra thư mục tạm).
struct PickedMovie: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            PickedMovie(url: try TranscribeController.copyToTemp(received.file))
        }
    }
}

// MARK: - Một dòng phụ đề

private struct SegmentLine: View {
    let segment: TranscriptSegment
    let display: SubtitleContent
    let isCurrent: Bool
    let isTranslating: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onPlay) {
                Text(SubtitleWriter.clock(segment.start))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 3) {
                if display != .translation || segment.translation.isEmpty {
                    Text(segment.text)
                        .foregroundStyle(display == .bilingual && !segment.translation.isEmpty ? Color.secondary : Color.primary)
                        .font(display == .bilingual ? .subheadline : .body)
                }
                if display != .source, !segment.translation.isEmpty {
                    if segment.isFast {
                        Text("\(Image(systemName: "bolt.fill")) \(segment.translation)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(segment.translation)
                    }
                }
                if isTranslating {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
    }
}

// MARK: - Sửa một đoạn

private struct SegmentEditor: View {
    let segment: TranscriptSegment
    let direction: TranslationDirection
    let canTranslate: Bool
    let onSave: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var translation: String

    init(segment: TranscriptSegment, direction: TranslationDirection, canTranslate: Bool,
         onSave: @escaping (String, String, Bool) -> Void) {
        self.segment = segment
        self.direction = direction
        self.canTranslate = canTranslate
        self.onSave = onSave
        _text = State(initialValue: segment.text)
        _translation = State(initialValue: segment.translation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(SubtitleWriter.time(segment.start, sep: ",")) → \(SubtitleWriter.time(segment.end, sep: ","))") {
                    EmptyView()
                }
                Section(direction.sourceName) {
                    TextField("Lời nói", text: $text, axis: .vertical).lineLimit(2...8)
                }
                Section(direction.targetName) {
                    TextField("Bản dịch", text: $translation, axis: .vertical).lineLimit(2...8)
                }
                Section {
                    Button("Lưu và dịch lại đoạn này", systemImage: "arrow.clockwise") {
                        onSave(text, "", true)
                        dismiss()
                    }
                    .disabled(!canTranslate)
                }
            }
            .navigationTitle("Sửa đoạn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        onSave(text, translation, false)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
