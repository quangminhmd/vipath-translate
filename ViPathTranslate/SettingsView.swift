import SwiftUI

// MARK: - Thời gian nạp (đo trên máy, lưu lại để so sánh)

@MainActor @Observable
final class LoadTimings {
    static let shared = LoadTimings()
    struct Entry: Codable, Equatable { var load: Double; var warm: Double; var at: Date }
    private(set) var latest: [String: Entry] = [:]
    private(set) var previous: [String: Entry] = [:]
    /// Lần "Nạp mô hình" gần nhất: tổng thời gian + nạp song song hay lần lượt.
    private(set) var lastBatch: (seconds: Double, parallel: Bool)?

    private init() {
        let d = UserDefaults.standard
        if let a = d.data(forKey: "loadTimings.latest"), let v = try? JSONDecoder().decode([String: Entry].self, from: a) { latest = v }
        if let a = d.data(forKey: "loadTimings.previous"), let v = try? JSONDecoder().decode([String: Entry].self, from: a) { previous = v }
    }

    static func key(_ m: ModelChoice) -> String { "t:\(m.rawValue)" }
    static func key(_ m: WhisperModelChoice, _ c: WhisperRunner.Compute) -> String { "w:\(m.rawValue):\(c.rawValue)" }

    func record(_ key: String, load: Double, warm: Double) {
        if let old = latest[key] { previous[key] = old }
        latest[key] = Entry(load: load, warm: warm, at: Date())
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(latest), forKey: "loadTimings.latest")
        d.set(try? JSONEncoder().encode(previous), forKey: "loadTimings.previous")
    }

    func recordBatch(seconds: Double, parallel: Bool) { lastBatch = (seconds, parallel) }

    /// "Nạp 4,2 s + làm nóng 0,8 s · lần trước 3:05"
    func summary(_ key: String) -> String? {
        guard let e = latest[key] else { return nil }
        var s = "Nạp \(Self.format(e.load)) + làm nóng \(Self.format(e.warm))"
        if let p = previous[key] { s += " · lần trước \(Self.format(p.load + p.warm))" }
        return s
    }

    static func format(_ t: Double) -> String {
        if t < 60 { return String(format: "%.1f s", t).replacingOccurrences(of: ".", with: ",") }
        let s = Int(t.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

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

    /// Mặc định BẬT: mở app là nạp nền ngay.
    static var autoLoadEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoLoadModels") as? Bool ?? true
    }

    /// Những gì còn cần nạp (để hiện trên nút).
    static func pending(vm: TranslatorViewModel, gross: GrossDictationController,
                        compute: WhisperRunner.Compute) -> [String] {
        var out: [String] = []
        if vm.loadedModel != vm.selectedModel { out.append(vm.selectedModel.shortName) }
        if vm.selectedModel.requiredFreeBytes < UInt64(6 * 1_073_741_824),
           let wm = preferredWhisper(gross: gross), WhisperModelStore.shared.isReady(wm),
           !WhisperStatus.shared.isLoaded(wm, compute) { out.append(wm.title) }
        return out
    }

    /// Nạp song song khi Whisper chạy trên Neural Engine (khác phần cứng với mô hình dịch trên GPU)
    /// và mô hình dịch không quá lớn; mô hình ≥ 9B hoặc Whisper trên GPU → nạp lần lượt cho an toàn RAM/GPU.
    static func canParallel(vm: TranslatorViewModel, compute: WhisperRunner.Compute) -> Bool {
        !DeviceMemory.isLowRAM      // máy 8 GB: luôn nạp lần lượt
            && compute == .neuralEngine && vm.selectedModel.requiredFreeBytes < UInt64(6 * 1_073_741_824)
    }

    /// - first: tab đang mở → mô hình tab đó cần được nạp trước (khi phải nạp lần lượt).
    static func loadAll(vm: TranslatorViewModel, gross: GrossDictationController,
                        compute: WhisperRunner.Compute, first: AppTab = .translate) async {
        let t0 = Date()
        let needTranslation = vm.loadedModel != vm.selectedModel && !vm.isLoading && !vm.isTranslating
            && vm.selectedModel.deviceFit != .tooBig
        var whisper: WhisperModelChoice?
        if let wm = preferredWhisper(gross: gross), WhisperModelStore.shared.isReady(wm),
           !WhisperRunner.shared.isLoaded(wm, compute) { whisper = wm }
        // Mô hình dịch ≥ 9B gần hết RAM của app → không nạp sẵn Whisper (tab cần thì tự nạp khi bấm mic)
        if needTranslation || vm.loadedModel == vm.selectedModel,
           vm.selectedModel.requiredFreeBytes >= UInt64(6 * 1_073_741_824) { whisper = nil }
        guard needTranslation || whisper != nil else { return }

        let loadTranslation: @MainActor () async -> Void = { if needTranslation { await vm.loadModel() } }
        let loadWhisper: @MainActor () async -> Void = {
            if let wm = whisper { try? await WhisperRunner.shared.load(wm, compute: compute) }
        }
        let parallel = needTranslation && whisper != nil && canParallel(vm: vm, compute: compute)
        if parallel {
            // Mô hình dịch bắt đầu trước (kiểm tra RAM trống khi chưa có gì khác chiếm), Whisper chạy song song.
            async let t: Void = loadTranslation()
            async let w: Void = loadWhisper()
            _ = await (t, w)
        } else if first == .gross || first == .transcribe {
            await loadWhisper(); await loadTranslation()
        } else {
            await loadTranslation(); await loadWhisper()
        }
        if needTranslation && whisper != nil {
            LoadTimings.shared.recordBatch(seconds: Date().timeIntervalSince(t0), parallel: parallel)
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
                    Text(vm.loadStageText).font(.caption).foregroundStyle(.secondary)
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
            if !vm.isLoading, let t = LoadTimings.shared.summary(LoadTimings.key(vm.selectedModel)) {
                Text(t).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
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
            if status.loading != model, let t = LoadTimings.shared.summary(LoadTimings.key(model, tc.whisperCompute)) {
                Text(t).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
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
                        Text("\(status.warming ? "Đang làm nóng" : "Đang nạp") · \(status.loadingCompute?.label ?? "") \(s / 60):\(String(format: "%02d", s % 60))")
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
    @Environment(LiveCaptionsController.self) private var cc
    @AppStorage("autoLoadModels") private var autoLoad = true
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
        @Bindable var cc = cc
        let pending = ModelLoader.pending(vm: vm, gross: gross, compute: tc.whisperCompute)
        NavigationStack {
            Form {
                Section {
                    Button {
                        loadingAll = true
                        Task {
                            await ModelLoader.loadAll(vm: vm, gross: gross, compute: tc.whisperCompute, first: .settings)
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
                    if let b = LoadTimings.shared.lastBatch {
                        LabeledContent("Lần nạp gần nhất",
                                       value: "\(LoadTimings.format(b.seconds)) · \(b.parallel ? "song song" : "lần lượt")")
                            .font(.footnote)
                    }
                } footer: {
                    Text(ModelLoader.canParallel(vm: vm, compute: tc.whisperCompute)
                         ? "Whisper chạy trên Neural Engine, mô hình dịch trên GPU → nạp song song. Khi tự nạp, mô hình của tab đang mở được ưu tiên."
                         : DeviceMemory.isLowRAM
                            ? "Máy \(DeviceMemory.label): nạp lần lượt để an toàn RAM. Khi tự nạp, mô hình của tab đang mở được nạp trước."
                            : "Đang nạp lần lượt (Whisper trên GPU hoặc mô hình dịch ≥ 9B) để an toàn RAM. Khi tự nạp, mô hình của tab đang mở được nạp trước.")
                }

                Section {
                    Picker("Mô hình dịch", selection: $vm.selectedModel) {
                        ForEach(ModelChoice.allCases.filter { $0.deviceFit != .tooBig }) { m in
                            Text("\(m.shortName) · \(m.sizeLabel)" + (m.deviceFit == .tight ? " ⚠︎" : "")).tag(m)
                        }
                    }
                    if let note = vm.selectedModel.deviceFitNote {
                        Text(note).font(.caption).foregroundStyle(.orange)
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
                    Text("Nhận dạng giọng nói (Whisper) · Đại thể, Phụ đề, Chép lời")
                } footer: {
                    Text(tc.whisperCompute == .neuralEngine
                         ? "Neural Engine: nhanh, mát máy; lần nạp ĐẦU TIÊN iOS phải tối ưu mô hình (vài phút), các lần sau vài giây."
                         : "GPU: nạp trong vài giây; chạy chung GPU với mô hình dịch nên dịch song song sẽ chậm hơn.")
                }

                Section("Bộ nhận dạng mặc định") {
                    Picker("Đại thể", selection: $gross.engine) {
                        ForEach(GrossEngine.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Phụ đề · tiếng Việt", selection: $cc.engineVI) {
                        ForEach(LiveCaptionsController.engines(for: .viToEn)) { Text($0.title).tag($0) }
                    }
                    Picker("Phụ đề · tiếng Anh", selection: $cc.engineEN) {
                        ForEach(LiveCaptionsController.engines(for: .enToVi)) { Text($0.title).tag($0) }
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
