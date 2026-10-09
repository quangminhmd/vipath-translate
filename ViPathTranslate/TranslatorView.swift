import SwiftUI
import UIKit

struct TranslatorView: View {
    @Environment(TranslatorViewModel.self) private var vm
    @Environment(LiveTypingTranslator.self) private var typing
    @AppStorage("liveTyping") private var liveMode = false
    @State private var showModels = false
    @State private var showHits = false
    @State private var showVoiceLab = false
    @State private var showClaudeSettings = false
    @State private var showTermReview = false
    @State private var savedToast = false
    @State private var showImageText = false
    @FocusState private var editorFocused: Bool
    private var claude: ClaudeService { ClaudeService.shared }
    private var suggestions: TermSuggestionStore { TermSuggestionStore.shared }

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelBar
                    inputCard
                    if !liveMode { actionRow }
                    if claude.isEnabled { claudeRow }
                    if let err = vm.errorText {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if liveMode {
                        if !typing.lines.isEmpty { liveOutputCard }
                    } else if !vm.segments.isEmpty {
                        outputCard
                    }
                    if claude.isBusy || !vm.claudeOutput.isEmpty || vm.claudeError != nil {
                        claudeCard
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.input) { _, new in
                if liveMode { typing.textChanged(new) }
            }
            .onChange(of: vm.directionMode) { _, _ in
                if liveMode { typing.textChanged(vm.input) }
            }
            .onChange(of: liveMode) { _, on in
                if on {
                    vm.stop()
                    typing.textChanged(vm.input)
                } else {
                    typing.cancel()
                }
            }
            .onChange(of: vm.loadedModel) { _, _ in
                typing.invalidateCache()
                if liveMode { typing.textChanged(vm.input) }
            }
            .navigationTitle("Dịch GPB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { claudeToolbarButton }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Giọng đọc", systemImage: "waveform") { showVoiceLab = true }
                }
            }
            .overlay(alignment: .bottom) {
                if savedToast {
                    Label("Đã lưu vào tab Đã lưu", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $showVoiceLab) { VoiceLabView() }
            .sheet(isPresented: $showModels) { ModelPickerSheet() }
            .sheet(isPresented: $showHits) { HitsSheet(hits: vm.segments.isEmpty ? vm.liveHits : vm.allHits) }
            .sheet(isPresented: $showClaudeSettings) { ClaudeSettingsView() }
            .sheet(isPresented: $showImageText) { ImageTextView() }
            .sheet(isPresented: $showTermReview) { TermReviewView(glossary: vm.glossary) }
            .sheet(item: $vm.claudeRequest) { req in
                RedactionConfirmView(request: req) { confirmed in vm.sendClaude(confirmed) }
            }
        }
    }

    // MARK: Claude — nút kết nối / ngắt kết nối

    private var claudeToolbarButton: some View {
        Menu {
            Toggle(isOn: Binding(get: { claude.isEnabled }, set: { claude.isEnabled = $0 })) {
                Label("Kết nối Claude", systemImage: "cloud")
            }
            Button("Cài đặt Claude…", systemImage: "key") { showClaudeSettings = true }
            if !suggestions.pending.isEmpty {
                Button("Duyệt \(suggestions.pending.count) thuật ngữ đề xuất", systemImage: "checklist") {
                    showTermReview = true
                }
            }
            Text(claude.statusText)
        } label: {
            Image(systemName: claude.isEnabled ? (claude.isReady ? "cloud.fill" : "exclamationmark.icloud")
                                               : "icloud.slash")
                .foregroundStyle(claude.isEnabled ? (claude.isReady ? Color.accentColor : Color.orange) : Color.secondary)
        } primaryAction: {
            if !claude.hasKey { showClaudeSettings = true } else { claude.isEnabled.toggle() }
        }
        .accessibilityLabel(claude.isEnabled ? "Ngắt kết nối Claude" : "Kết nối Claude")
    }

    // MARK: Mô hình
    private var modelBar: some View {
        Button { showModels = true } label: {
            HStack {
                Image(systemName: vm.loadedModel == nil ? "cpu" : "checkmark.circle.fill")
                    .foregroundStyle(vm.loadedModel == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.loadedModel?.shortName ?? "Chưa nạp mô hình").font(.subheadline.bold())
                    Text(vm.isLoading ? "Đang nạp… \(Int(vm.loadProgress * 100))%"
                         : vm.loadedModel == nil ? "Chạm để chọn và nạp" : "Sẵn sàng · chạy trên máy")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if vm.tokensPerSecond > 0 {
                    Text(String(format: "%.0f tok/s", vm.tokensPerSecond))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: Chiều dịch
    private var directionBar: some View {
        @Bindable var vm = vm
        return HStack(spacing: 8) {
            Menu {
                Picker("Chiều dịch", selection: $vm.directionMode) {
                    ForEach(DirectionMode.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(vm.direction.sourceName).bold()
                    if vm.directionMode == .auto {
                        Text("tự nhận").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            Button { vm.swapDirection() } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .accessibilityLabel("Đảo chiều dịch")
            .disabled(vm.isTranslating)
            Text(vm.direction.targetName).bold()
        }
        .font(.subheadline)
    }

    // MARK: Nhập
    private var inputCard: some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: 8) {
            directionBar
            HStack {
                Toggle(isOn: $liveMode) { Text("Dịch khi gõ") }
                    .toggleStyle(.button)
                    .disabled(vm.loadedModel == nil)
                Spacer()
                Button("Ảnh", systemImage: "text.viewfinder") { showImageText = true }
                Button("Dán", systemImage: "doc.on.clipboard") { vm.pasteFromClipboard() }
                Button("Xoá", systemImage: "xmark.circle") {
                    vm.clear()
                    typing.reset()
                }
                .disabled(vm.input.isEmpty)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)

            TextEditor(text: $vm.input)
                .focused($editorFocused)
                .frame(minHeight: 140, maxHeight: 280)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if vm.input.isEmpty {
                        Text(vm.directionMode == .auto
                             ? "Nhập hoặc dán văn bản tiếng Anh hoặc tiếng Việt — app tự nhận chiều dịch (đại thể, vi thể, kết luận, bài báo, slide…)"
                             : "Nhập hoặc dán văn bản \(vm.direction.sourceName.lowercased()) (đại thể, vi thể, kết luận, bài báo, slide…)")
                            .foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                    }
                }

            let hits = vm.liveHits
            if !hits.isEmpty {
                Button { showHits = true } label: {
                    Label("\(hits.count) thuật ngữ glossary sẽ được chèn", systemImage: "text.book.closed")
                        .font(.caption)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack {
            if vm.isTranslating {
                Button(role: .destructive) { vm.stop() } label: {
                    Label("Dừng", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    editorFocused = false
                    vm.translate()
                } label: {
                    Label("Dịch sang \(vm.direction.targetName.lowercased())", systemImage: "character.book.closed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.loadedModel == nil || vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .controlSize(.large)
    }

    // MARK: Claude — hành động

    private var claudeRow: some View {
        let hasDraft = !vm.segments.isEmpty && !vm.isTranslating
        let empty = vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                editorFocused = false
                if claude.isReady { vm.prepareClaude() } else { showClaudeSettings = true }
            } label: {
                Label(hasDraft ? "Hiệu đính bằng Claude" : "Dịch bằng Claude", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(empty || claude.isBusy || vm.isTranslating)
            Text(claude.isReady
                 ? "Định danh (tên, PID, mã bệnh phẩm, ngày sinh…) được che trước khi gửi — bạn sẽ xem và xác nhận."
                 : claude.statusText)
                .font(.caption2)
                .foregroundStyle(claude.isReady ? Color.secondary : Color.orange)
        }
    }

    private var claudeCard: some View {
        let dir = vm.claudeDirection
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Claude — \(dir.targetName)", systemImage: "sparkles")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                if claude.isBusy {
                    ProgressView().controlSize(.mini)
                    if !claude.progressText.isEmpty {
                        Text(claude.progressText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if claude.isBusy {
                    Button("Huỷ", systemImage: "xmark") { vm.cancelClaude() }.font(.caption)
                } else if !vm.claudeOutput.isEmpty {
                    if dir == .enToVi { SpeakButton(text: vm.claudeOutput) }
                    Button("Chép", systemImage: "doc.on.doc") { UIPasteboard.general.string = vm.claudeOutput }
                        .font(.caption)
                    saveButton
                }
            }
            if let err = vm.claudeError {
                Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
            if claude.isBusy && vm.claudeOutput.isEmpty {
                Text("Đang gửi văn bản đã che định danh tới Claude…").foregroundStyle(.secondary)
            }
            if !vm.claudeOutput.isEmpty {
                Text(vm.claudeOutput)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 10))
                if !vm.claudeLostPlaceholders.isEmpty {
                    Label("Claude làm mất \(vm.claudeLostPlaceholders.joined(separator: ", ")) — kiểm tra lại định danh trong bản dịch.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !vm.claudeInfo.isEmpty {
                    Text(vm.claudeInfo).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !suggestions.pending.isEmpty {
                    Button { showTermReview = true } label: {
                        Label(vm.claudeNewTerms > 0
                              ? "Claude đề xuất \(vm.claudeNewTerms) thuật ngữ mới — duyệt để mô hình offline học"
                              : "\(suggestions.pending.count) thuật ngữ đang chờ duyệt",
                              systemImage: "graduationcap")
                            .font(.caption.bold())
                    }
                }
            }
        }
    }

    private var saveButton: some View {
        Button("Lưu", systemImage: "square.and.arrow.down") {
            if vm.saveCurrent() {
                withAnimation { savedToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation { savedToast = false }
                }
            }
        }
        .font(.caption)
        .disabled(!vm.canSave)
    }

    // MARK: Kết quả — dịch khi gõ
    private var liveOutputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(typing.direction.targetName).font(.caption.bold()).foregroundStyle(.secondary)
                if typing.isWorking { ProgressView().controlSize(.mini) }
                Spacer()
                if !typing.allMissing.isEmpty {
                    Label("\(typing.allMissing.count)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if typing.direction == .enToVi { SpeakButton(text: typing.outputText) }
                Button("Chép", systemImage: "doc.on.doc") { UIPasteboard.general.string = typing.outputText }
                    .font(.caption)
                Button("Lưu", systemImage: "square.and.arrow.down") { saveTyping() }
                    .font(.caption)
                    .disabled(typing.isWorking || typing.outputText.isEmpty)
            }
            // các câu ghép thành đoạn liền; câu chưa dịch xong hiển thị nhạt
            typing.lines.reduce(Text("")) { acc, line in
                let t = Text(line.output.isEmpty ? "…" : line.output)
                    .foregroundStyle(line.isDone ? (line.missing.isEmpty ? Color.primary : Color.orange) : Color.secondary)
                return Text("\(acc)\(t) ")
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))

            if !typing.allMissing.isEmpty {
                ForEach(typing.allMissing) { h in
                    Text("⚠︎ \(h.matched) → \(h.translations.joined(separator: " | "))")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Câu màu cam: chưa dùng đúng thuật ngữ glossary. Bản dịch máy — cần bác sĩ duyệt.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func saveTyping() {
        let source = vm.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        let item = SavedItem(kind: .text, title: SavedItem.autoTitle(source), direction: typing.direction,
                             engine: vm.loadedModel?.shortName ?? "—", source: source,
                             translation: typing.outputText)
        if SavedStore.shared.save(item) {
            withAnimation { savedToast = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { savedToast = false }
            }
        }
    }

    // MARK: Kết quả
    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(vm.outputDirection.targetName) · offline").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if vm.outputDirection == .enToVi {
                    SpeakButton(text: vm.outputText).disabled(vm.isTranslating)
                }
                Button("Chép", systemImage: "doc.on.doc") { vm.copyOutput() }
                    .font(.caption)
                    .disabled(vm.isTranslating)
                saveButton
            }
            if !vm.allMissing.isEmpty {
                Label("\(vm.allMissing.count) thuật ngữ chưa đúng glossary", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            ForEach(vm.segments.filter { !$0.passthrough }) { seg in
                SegmentRow(seg: seg, isActive: vm.currentSegment == seg.id) {
                    vm.retranslate(seg.id)
                }
            }

            if !vm.isTranslating, vm.lastRunSeconds > 0 {
                Text(String(format: "Tổng %.1f s · đọc prompt %.1f s · %.0f tok/s · %d đoạn",
                            vm.lastRunSeconds, vm.promptSeconds, vm.tokensPerSecond,
                            vm.segments.filter { !$0.passthrough }.count))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !vm.allHits.isEmpty {
                Button { showHits = true } label: {
                    Label("Xem \(vm.allHits.count) thuật ngữ đã áp dụng", systemImage: "list.bullet.rectangle")
                        .font(.caption)
                }
            }
            Text("Bản dịch máy chạy offline — cần bác sĩ duyệt trước khi dùng trong hồ sơ bệnh án.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Nút đọc / dừng đọc bản dịch tiếng Việt.
struct SpeakButton: View {
    let text: String
    private var speech: SpeechOutput { SpeechOutput.shared }

    var body: some View {
        Button(speech.isSpeaking ? "Dừng đọc" : "Đọc",
               systemImage: speech.isSpeaking ? "stop.circle" : "speaker.wave.2") {
            if speech.isSpeaking { speech.stop() } else { speech.speak(text) }
        }
        .font(.caption)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private struct SegmentRow: View {
    let seg: TranslatedSegment
    let isActive: Bool
    let retranslate: () -> Void
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if seg.output.isEmpty {
                HStack(spacing: 6) {
                    if isActive { ProgressView().controlSize(.small) }
                    Text(isActive ? "Đang dịch…" : "Chờ dịch").foregroundStyle(.secondary)
                }
            } else {
                Text(seg.output).textSelection(.enabled)
            }

            if seg.isDone, !seg.missing.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(seg.missing) { h in
                        Text("⚠︎ \(h.matched) → \(h.translations.joined(separator: " | "))")
                    }
                    Button("Dịch lại đoạn này", action: retranslate).padding(.top, 2)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if showSource {
                Text(seg.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground),
                    in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { showSource.toggle() }
    }
}

// MARK: - Chọn mô hình

private struct ModelPickerSheet: View {
    @Environment(TranslatorViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if vm.isLoading || vm.errorText != nil {
                    Section {
                        if vm.isLoading {
                            ProgressView(value: vm.loadProgress) {
                                Text("Đang nạp \(vm.selectedModel.shortName)… \(Int(vm.loadProgress * 100))%")
                            }
                        }
                        if let err = vm.errorText, !vm.isLoading {
                            Text(err).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    ForEach(ModelChoice.allCases) { m in
                        Button { vm.selectedModel = m } label: {
                            HStack(alignment: .top) {
                                Image(systemName: vm.selectedModel == m ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(m.shortName).font(.body.bold())
                                        Text(m.sizeLabel).font(.caption).foregroundStyle(.secondary)
                                        if vm.loadedModel == m {
                                            Text("đang dùng").font(.caption2.bold()).foregroundStyle(.green)
                                        }
                                    }
                                    Text(m.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Lần đầu cần Internet để tải mô hình (trừ khi đã đóng gói trong app). Sau đó dịch hoàn toàn offline, văn bản không rời khỏi máy.")
                }

            }
            .navigationTitle("Mô hình")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Nút Nạp ở góc trên phải, cạnh Xong — không phải cuộn xuống
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if vm.isLoading {
                        ProgressView()
                    } else {
                        Button(vm.loadedModel == vm.selectedModel ? "Đã nạp" : "Nạp") {
                            Task {
                                await vm.loadModel()
                                if vm.errorText == nil { dismiss() }
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(vm.loadedModel == vm.selectedModel || vm.isTranslating)
                    }
                    Button("Xong") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Danh sách thuật ngữ khớp

struct HitsSheet: View {
    let hits: [GlossaryHit]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(hits) { h in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(h.matched).font(.body.bold())
                        if h.isAmbiguous {
                            Text("nhiều nghĩa").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: .capsule)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(h.translations.joined(separator: "  |  "))
                    ForEach(h.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Thuật ngữ (\(hits.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }
}
