import SwiftUI

/// Màn hình "Giọng đọc": thử VieNeu-TTS, đo tốc độ trên máy, so với giọng iOS và chọn giọng mặc định.
struct VoiceLabView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var speech = SpeechOutput.shared
    @State private var player = LabPlayer()

    @State private var loading = false
    @State private var loadSeconds: Double?
    @State private var busyIndex: Int?
    @State private var results: [Int: VieNeuTiming] = [:]
    @State private var phonemes: [Int: String] = [:]
    @State private var errorText: String?
    @State private var custom = ""
    @State private var busySince: Date?
    @State private var busyLabel = ""

    private let samples = [
        "Hoá mô miễn dịch cho thấy các ổ tế bào u, phù hợp với u màng não thoái sản, WHO độ 3.",
        "Dấu ấn CD20 dương tính lan toả, CD3 âm tính, Ki-67 khoảng 80%.",
        "Đột biến IDH1 p.R132H dương tính; đồng mất đoạn 1p/19q; phân giai đoạn pT1aN1b.",
        "Sarcôm sợi niêm độ thấp, 12 phân bào trên 10 vi trường, không có hoại tử.",
    ]

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if speech.vieneuAvailable { benchmarkSection }
                compareSection
                defaultSection
            }
            .navigationTitle("Giọng đọc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }

    // MARK: Trạng thái

    private var statusSection: some View {
        Section {
            if !VieNeuEngine.isCompiledIn {
                Label("VieNeu chưa được build vào app", systemImage: "hammer")
                Text("Trên Mac: thoát Xcode, mở Terminal và chạy\n`cd ~/Developer/ViPathTranslate && bash Tools/build_vieneu_ios.sh`\nrồi build lại app.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !VieNeuResources.missing.isEmpty {
                Label("Thiếu tệp mô hình VieNeu", systemImage: "exclamationmark.triangle")
                Text(VieNeuResources.missing.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("VieNeu-TTS v3 Turbo (Q8, CPU)", systemImage: "waveform")
                    Spacer()
                    if let s = loadSeconds {
                        Text(String(format: "nạp %.1f s", s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Picker("Luồng CPU", selection: $speech.vieneuThreads) {
                    ForEach([2, 4, 6], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: speech.vieneuThreads) { loadSeconds = nil; results = [:] }
                Picker("Độ ổn định giọng", selection: $speech.vieneuTemperature) {
                    Text("Chắc (0.4)").tag(0.4)
                    Text("Cân bằng (0.6)").tag(0.6)
                    Text("Tự nhiên (0.8)").tag(0.8)
                }
                .pickerStyle(.segmented)
                Button(loading ? "Đang nạp…" : (loadSeconds == nil ? "Nạp VieNeu" : "Nạp lại")) {
                    Task { await load() }
                }
                .disabled(loading || busyIndex != nil)
            }
            if let e = errorText ?? speech.lastVieNeuError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("VieNeu-TTS")
        } footer: {
            Text("RTF < 1: tổng hợp nhanh hơn thời gian nói, đủ cho phụ đề/thông dịch bằng giọng. Thời gian chờ câu đầu = âm vị + tổng hợp câu đó.")
        }
    }

    // MARK: Đo tốc độ

    private var benchmarkSection: some View {
        Section("Đo tốc độ — câu GPB mẫu") {
            if let since = busySince {
                TimelineView(.periodic(from: since, by: 0.5)) { ctx in
                    Label("\(busyLabel) \(String(format: "%.1f", ctx.date.timeIntervalSince(since))) s",
                          systemImage: "hourglass")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(samples.indices, id: \.self) { i in
                sampleRow(i, text: samples[i])
            }
            VStack(alignment: .leading) {
                TextField("Câu tiếng Việt tự nhập…", text: $custom, axis: .vertical)
                    .lineLimit(1...4)
                if !custom.trimmingCharacters(in: .whitespaces).isEmpty {
                    sampleRow(99, text: custom)
                }
            }
            if !results.isEmpty { summary }
        }
    }

    private func sampleRow(_ i: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if i != 99 { Text(text).font(.subheadline) }
            HStack {
                Button {
                    Task { await synthesize(i, text) }
                } label: {
                    if busyIndex == i { ProgressView().controlSize(.small) } else { Label("Tổng hợp & phát", systemImage: "play.fill") }
                }
                .buttonStyle(.glass)
                .disabled(busyIndex != nil || loading)
                Spacer()
                if let r = results[i] {
                    Text(String(format: "%.2fs → %.1fs âm thanh · RTF %.2f", r.g2p + r.synthesis, r.audio, r.rtf))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(r.rtf < 1 ? .green : .orange)
                }
            }
            if let p = phonemes[i] {
                DisclosureGroup("Văn bản đọc & âm vị") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(GPBSpeechNormalizer.normalize(i == 99 ? custom : samples[i]))
                            .font(.caption)
                        Text(p).font(.caption2).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
                    .font(.caption)
            }
        }
    }

    private var summary: some View {
        let all = Array(results.values)
        let audio = all.map(\.audio).reduce(0, +)
        let synth = all.map(\.synthesis).reduce(0, +)
        let g2p = all.map(\.g2p).reduce(0, +) / Double(all.count)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Tổng: \(String(format: "%.1f", audio)) s âm thanh trong \(String(format: "%.1f", synth)) s")
            Text("RTF trung bình \(String(format: "%.2f", synth / max(audio, 0.001))) · âm vị \(String(format: "%.0f", g2p * 1000)) ms/câu")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    // MARK: So sánh với giọng iOS

    private var compareSection: some View {
        Section {
            ForEach(samples.indices, id: \.self) { i in
                Button {
                    speech.stop()
                    let wasVieNeu = speech.useVieNeu
                    speech.useVieNeu = false
                    speech.speak(samples[i])
                    speech.useVieNeu = wasVieNeu
                } label: {
                    Label("Câu \(i + 1)", systemImage: "speaker.wave.2")
                }
            }
            if !speech.hasVietnameseVoice {
                Text("Chưa có giọng tiếng Việt chất lượng cao: Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Nghe giọng iOS để so sánh")
        }
    }

    // MARK: Chọn giọng mặc định

    private var defaultSection: some View {
        Section {
            Toggle("Dùng VieNeu cho nút Đọc và thông dịch bằng giọng", isOn: $speech.useVieNeu)
                .disabled(!speech.vieneuAvailable)
        } footer: {
            Text("Khi VieNeu gặp lỗi, app tự đọc bằng giọng iOS. VieNeu chạy trên CPU nên không làm chậm mô hình dịch (GPU).")
        }
    }

    // MARK: Hành động

    private func load() async {
        loading = true
        errorText = nil
        busyLabel = "Đang nạp mô hình…"
        busySince = Date()
        defer { loading = false; busySince = nil }
        do {
            loadSeconds = try await VieNeuEngine.shared.load(threads: speech.vieneuThreads)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func synthesize(_ i: Int, _ text: String) async {
        busyIndex = i
        errorText = nil
        defer { busyIndex = nil }
        do {
            if loadSeconds == nil { await load() }
            busyLabel = "Đang tổng hợp…"
            busySince = Date()
            defer { busySince = nil }
            let engine = VieNeuEngine.shared
            phonemes[i] = try await engine.phonemes(for: text)
            let (audio, timing) = try await engine.synthesize(text, temperature: speech.vieneuTemperature)
            results[i] = timing
            await VieNeuPlayer.preparePlaybackSession()
            try player.play(audio)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Bọc VieNeuPlayer cho màn hình thử (dừng đoạn cũ trước khi phát đoạn mới).
@MainActor
@Observable
final class LabPlayer {
    private let player = VieNeuPlayer()
    func play(_ audio: VieNeuAudio) throws {
        player.stop()
        try player.schedule(audio)
    }
}
