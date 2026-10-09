import SwiftUI

// MARK: - Nạp mô hình dùng chung cho mọi tab

/// Nạp một lần cho cả app: mô hình dịch (tab Dịch, Phụ đề, Chép lời) + Whisper (Đại thể, Chép lời).
@MainActor
enum ModelLoader {
    /// Whisper được nạp sẵn bằng nút "Nạp mô hình". Chưa chọn → theo bộ nhận dạng của tab Đại thể.
    static func preferredWhisper(gross: GrossDictationController) -> WhisperModelChoice? {
        switch UserDefaults.standard.string(forKey: "preloadWhisper") {
        case "none": return nil
        case let raw?: if let m = WhisperModelChoice(rawValue: raw) { return m }
        default: break
        }
        return gross.engine.whisperModel(for: gross.language)
    }

    /// Những gì còn cần nạp (để hiện trên nút).
    static func pending(vm: TranslatorViewModel, gross: GrossDictationController,
                        compute: WhisperRunner.Compute) -> [String] {
        var out: [String] = []
        if vm.loadedModel != vm.selectedModel { out.append(vm.selectedModel.shortName) }
        if let wm = preferredWhisper(gross: gross), WhisperModelStore.shared.isReady(wm),
           !WhisperStatus.shared.isLoaded(wm, compute) { out.append(wm.title) }
        return out
    }

    /// Nạp lần lượt (không cùng lúc để đỡ tốn RAM): mô hình dịch rồi Whisper.
    static func loadAll(vm: TranslatorViewModel, gross: GrossDictationController,
                        compute: WhisperRunner.Compute) async {
        if vm.loadedModel != vm.selectedModel, !vm.isLoading, !vm.isTranslating { await vm.loadModel() }
        if let wm = preferredWhisper(gross: gross), WhisperModelStore.shared.isReady(wm),
           !WhisperRunner.shared.isLoaded(wm, compute) {
            try? await WhisperRunner.shared.load(wm, compute: compute)
        }
    }
}

// MARK: - Trạng thái mô hình dịch

/// "Qwen3.5 4B · Đã nạp" / "Đang nạp 45%" / "Chưa nạp [Nạp]" — dùng ở tab Phụ đề và Cài đặt.
struct TranslationModelStatusRow: View {
    @Environment(TranslatorViewModel.self) private var vm
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed").foregroundStyle(.secondary)
                Text(vm.selectedModel.shortName).font(.subheadline.bold())
                if vm.isLoading {
                    ProgressView().controlSize(.mini)
                    Text("Đang nạp \(Int(vm.loadProgress * 100))%").font(.caption).foregroundStyle(.secondary)
                } else if vm.loadedModel == vm.selectedModel {
                    Label("Đã nạp", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else {
                    Text(vm.loadedModel.map { "Đang dùng \($0.shortName)" } ?? "Chưa nạp")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if !vm.isLoading && vm.loadedModel != vm.selectedModel {
                    Button("Nạp") { Task { await vm.loadModel() } }
                        .buttonStyle(.glassProminent).controlSize(.small)
                        .disabled(vm.isTranslating)
                }
            }
            if vm.isLoading { ProgressView(value: vm.loadProgress) }
            if !compact, let e = vm.errorText, !vm.isLoading {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Trạng thái Whisper

/// Tải / nạp một mô hình Whisper và cho biết đang chạy trên Neural Engine hay GPU.
struct WhisperModelStatusRow: View {
    let model: WhisperModelChoice
    var showCompute = true
    @Environment(TranscribeController.self) private var tc

    private var store: WhisperModelStore { WhisperModelStore.shared }
    private var status: WhisperStatus { WhisperStatus.shared }

    var body: some View {
        @Bindable var tc = tc
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text(model.title).font(.subheadline.bold()).lineLimit(1)
                stateLabel
                Spacer(minLength: 4)
                actionButton
            }
            if case .downloading(let p) = store.state(model) { ProgressView(value: p) }
            if showCompute, store.isReady(model) {
                Picker("Chạy trên", selection: $tc.whisperCompute) {
                    ForEach(WhisperRunner.Compute.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(status.loading != nil)
            }
            if let e = status.lastError, status.loading == nil, status.failedModel == model {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var stateLabel: some View {
        switch store.state(model) {
        case .notDownloaded:
            Text("Chưa tải · \(model.sizeLabel)").font(.caption).foregroundStyle(.orange)
        case .downloading(let p):
            Text("Đang tải \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
        case .ready:
            if status.isLoaded(model, tc.whisperCompute) {
                Label("Đã nạp · \(tc.whisperCompute.label)", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if status.loading == model, let since = status.loadingSince {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(since))
                        Text("Đang nạp · \(status.loadingCompute?.label ?? "") \(s / 60):\(String(format: "%02d", s % 60))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else if status.loaded == model, let c = status.compute {
                Text("Đã nạp trên \(c.label) — bấm Nạp để chuyển").font(.caption).foregroundStyle(.orange)
            } else {
                Text("Đã tải · chưa nạp").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch store.state(model) {
        case .notDownloaded:
            Button("Tải") { store.download(model) }.buttonStyle(.glass).controlSize(.small)
        case .downloading:
            Button("Huỷ") { store.cancel(model) }.controlSize(.small)
        case .ready:
            if !status.isLoaded(model, tc.whisperCompute) && status.loading != model {
                Button("Nạp") {
                    let c = tc.whisperCompute
                    Task { try? await WhisperRunner.shared.load(model, compute: c) }
                }
                .buttonStyle(.glassProminent).controlSize(.small)
                .disabled(status.loading != nil || tc.isBusy)
            }
        }
    }
}

// MARK: - Tab Cài đặt

struct SettingsView: View {
    @Environment(TranslatorViewModel.self) private var vm
    @Environment(TranscribeController.self) private var tc
    @Environment(GrossDictationController.self) private var gross
    @AppStorage("autoLoadModels") private var autoLoad = false
    @AppStorage("preloadWhisper") private var preloadWhisper = ""
    @State private var loadingAll = false

    private var whisperChoice: Binding<String> {
        Binding(get: { preloadWhisper.isEmpty ? (ModelLoader.preferredWhisper(gross: gross)?.rawValue ?? "none") : preloadWhisper },
                set: { preloadWhisper = $0 })
    }

    var body: some View {
        @Bindable var vm = vm
        @Bindable var tc = tc
        @Bindable var gross = gross
        let pending = ModelLoader.pending(vm: vm, gross: gross, compute: tc.whisperCompute)
        NavigationStack {
            Form {
                Section {
                    Button {
                        loadingAll = true
                        Task {
                            await ModelLoader.loadAll(vm: vm, gross: gross, compute: tc.whisperCompute)
                            loadingAll = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: pending.isEmpty ? "checkmark.circle.fill" : "bolt.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pending.isEmpty ? "Đã nạp đủ mô hình" : "Nạp mô hình").font(.headline)
                                Text(pending.isEmpty ? "Dùng được ngay ở mọi tab" : pending.joined(separator: " + "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if loadingAll { ProgressView() }
                        }
                    }
                    .disabled(pending.isEmpty || loadingAll || vm.isLoading || WhisperStatus.shared.loading != nil)
                    Toggle("Tự nạp khi mở app", isOn: $autoLoad)
                } footer: {
                    Text("Một nút nạp chung cho các tab. Mô hình dịch và Whisper được nạp lần lượt để tiết kiệm RAM.")
                }

                Section {
                    Picker("Mô hình dịch", selection: $vm.selectedModel) {
                        ForEach(ModelChoice.allCases) { m in
                            Text("\(m.shortName) · \(m.sizeLabel)").tag(m)
                        }
                    }
                    TranslationModelStatusRow()
                    Text(vm.selectedModel.summary).font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Dịch · dùng cho Dịch, Phụ đề, Chép lời")
                }

                Section {
                    Picker("Nạp sẵn", selection: whisperChoice) {
                        Text("Không").tag("none")
                        ForEach(WhisperModelChoice.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    ForEach(WhisperModelChoice.allCases) { m in
                        WhisperModelStatusRow(model: m, showCompute: false)
                    }
                    Picker("Chạy trên", selection: $tc.whisperCompute) {
                        ForEach(WhisperRunner.Compute.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(WhisperStatus.shared.loading != nil)
                } header: {
                    Text("Nhận dạng giọng nói (Whisper) · Đại thể, Chép lời")
                } footer: {
                    Text(tc.whisperCompute == .neuralEngine
                         ? "Neural Engine: nhanh, mát máy; lần nạp ĐẦU TIÊN iOS phải tối ưu mô hình (vài phút), các lần sau vài giây."
                         : "GPU: nạp trong vài giây; chạy chung GPU với mô hình dịch nên dịch song song sẽ chậm hơn.")
                }

                Section("Bộ nhận dạng mặc định") {
                    Picker("Đại thể", selection: $gross.engine) {
                        ForEach(GrossEngine.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Chép lời · tiếng Việt", selection: $tc.engineVI) {
                        ForEach(ASREngine.options(for: .vi)) { Text($0.title).tag($0) }
                    }
                    Picker("Chép lời · tiếng Anh", selection: $tc.engineEN) {
                        ForEach(ASREngine.options(for: .en)) { Text($0.title).tag($0) }
                    }
                }

                Section {
                    FastStatusLabel(direction: .enToVi)
                    FastStatusLabel(direction: .viToEn)
                    FastTranslateSettings(directions: [.enToVi, .viToEn])
                } header: {
                    Text("Dịch nhanh (Apple) · Phụ đề, Chép lời")
                }
            }
            .navigationTitle("Cài đặt")
        }
    }
}
