import SwiftUI
import UIKit

struct LiveCaptionsView: View {
    @Environment(TranslatorViewModel.self) private var vm
    @Environment(LiveCaptionsController.self) private var cc
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !cc.isRunning { setupPanel }
                panes
                controlBar
            }
            .navigationTitle("Phụ đề trực tiếp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if cc.lastDelay > 0 {
                        Text(String(format: "trễ %.1fs", cc.lastDelay))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Lưu", systemImage: cc.lastSavedAt == nil ? "square.and.arrow.down" : "checkmark.circle") {
                        cc.saveSession()
                    }
                    .disabled(!cc.captions.contains { !$0.vi.isEmpty })
                    ShareLink(item: cc.transcriptText) { Image(systemName: "square.and.arrow.up") }
                        .disabled(cc.captions.isEmpty)
                    Button("Tuỳ chọn", systemImage: "textformat.size") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { settings }
        }
    }

    // MARK: Thiết lập trước khi nghe
    private var setupPanel: some View {
        @Bindable var cc = cc
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Nguồn âm thanh", selection: $cc.source) {
                ForEach(LiveCaptionsController.Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(cc.source.hint).font(.caption).foregroundStyle(.secondary)
            Button { showSettings = true } label: {
                FastStatusLabel(direction: .enToVi)
            }
            .buttonStyle(.plain)
            if vm.loadedModel == nil && FastTranslator.shared.isActive(.enToVi) {
                Label("Chưa nạp mô hình — chỉ dùng Dịch nhanh (Apple). Nạp Qwen ở tab Dịch để có bản chuẩn theo glossary.",
                      systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if vm.loadedModel == nil {
                Label("Chưa nạp mô hình dịch — vào tab Dịch để nạp (khuyên dùng Qwen3.5 2B/4B cho phụ đề), hoặc bật Dịch nhanh trong Tuỳ chọn.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if vm.loadedModel == .qwen35_9b {
                Label("9B có thể không theo kịp người nói và làm máy nóng; nên dùng 2B hoặc 4B.",
                      systemImage: "thermometer.medium")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let err = cc.errorText {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: Hai khung chạy song song: trên = nghe được (tiếng Anh), dưới = phụ đề tiếng Việt
    private var panes: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if cc.showEnglish {
                    paneHeader("Nghe được · tiếng Anh", systemImage: "ear", live: cc.isRunning && !cc.volatileText.isEmpty)
                    transcriptPane
                        .frame(height: max(80, geo.size.height * cc.topRatio - 28))
                    Divider()
                }
                paneHeader("Phụ đề · tiếng Việt", systemImage: "captions.bubble",
                           live: cc.captions.contains { $0.state == .translating })
                subtitlePane
                    .frame(maxHeight: .infinity)
            }
        }
        .overlay {
            if cc.captions.isEmpty && cc.volatileText.isEmpty {
                ContentUnavailableView(cc.isRunning ? "Đang nghe…" : "Chưa có phụ đề",
                                       systemImage: cc.isRunning ? "waveform" : "captions.bubble",
                                       description: Text(cc.isRunning ? cc.status
                                                         : "Khung trên: lời nói tiếng Anh nhận dạng được. Khung dưới: phụ đề tiếng Việt dịch ngay trên máy, không cần mạng."))
                    .background(Color(.systemBackground))
            }
        }
    }

    private func paneHeader(_ title: String, systemImage: String, live: Bool) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
            if live {
                Circle().fill(.red).frame(width: 6, height: 6)
            }
            Spacer()
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .frame(height: 28)
        .background(Color(.secondarySystemBackground))
    }

    /// Khung trên: văn bản nhận dạng — câu đã chốt + câu đang nói (xám nghiêng), tự cuộn.
    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(cc.captions) { c in
                        Text(c.en)
                            .font(.system(size: 15 * cc.fontScale))
                            .foregroundStyle(c.state == .done ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(c.id)
                    }
                    if !cc.volatileText.isEmpty {
                        Text(cc.volatileText)
                            .font(.system(size: 15 * cc.fontScale))
                            .foregroundStyle(.tertiary)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("enBottom")
                }
                .textSelection(.enabled)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: cc.captions.count) { proxy.scrollTo("enBottom", anchor: .bottom) }
            .onChange(of: cc.volatileText) { proxy.scrollTo("enBottom", anchor: .bottom) }
        }
    }

    /// Khung dưới: phụ đề tiếng Việt, cập nhật theo từng token, tự cuộn.
    private var subtitlePane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(cc.captions) { c in
                        SubtitleRow(caption: c, scale: cc.fontScale).id(c.id)
                    }
                    Color.clear.frame(height: 1).id("viBottom")
                }
                .padding()
            }
            .onChange(of: cc.captions.last?.vi) { proxy.scrollTo("viBottom", anchor: .bottom) }
            .onChange(of: cc.captions.count) { proxy.scrollTo("viBottom", anchor: .bottom) }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            if cc.isRunning {
                Text(cc.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(role: .destructive) { Task { await cc.stop() } } label: {
                    Label("Dừng", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Button("Xoá", systemImage: "trash") { cc.clear() }
                    .disabled(cc.captions.isEmpty)
                Spacer()
                Button { Task { await cc.start() } } label: {
                    Label("Bắt đầu nghe", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.loadedModel == nil && !FastTranslator.shared.isActive(.enToVi))
            }
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private var settings: some View {
        @Bindable var cc = cc
        return NavigationStack {
            Form {
                Section {
                    FastTranslateSettings(directions: [.enToVi])
                }
                Toggle("Hiện khung tiếng Anh (trên)", isOn: $cc.showEnglish)
                if cc.showEnglish {
                    VStack(alignment: .leading) {
                        Text("Chiều cao khung tiếng Anh")
                        Slider(value: $cc.topRatio, in: 0.2...0.6, step: 0.02)
                    }
                }
                Toggle("Tự lưu khi dừng nghe", isOn: $cc.autoSave)
                Section {
                    Toggle("Đọc bản dịch (thông dịch bằng giọng)", isOn: $cc.speakTranslations)
                        .onChange(of: cc.speakTranslations) { _, on in if !on { SpeechOutput.shared.stop() } }
                } footer: {
                    Text(SpeechOutput.shared.hasVietnameseVoice
                         ? "Đeo tai nghe để giọng đọc không lọt lại vào micro hoặc bản ghi âm thanh app."
                         : "Chưa có giọng tiếng Việt: Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt, tải giọng chất lượng cao.")
                }
                VStack(alignment: .leading) {
                    Text("Cỡ chữ phụ đề")
                    Slider(value: $cc.fontScale, in: 0.8...2.0, step: 0.1)
                }
                Section {
                    Text("Giữ ViPath ở màn hình chính khi nghe: iPhone không cho chạy mô hình dịch (GPU) ở nền. Nếu chuyển sang app khác, phụ đề tạm dừng và tự dịch bù khi quay lại.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tuỳ chọn phụ đề")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Xong") { showSettings = false } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Một dòng phụ đề tiếng Việt ở khung dưới.
private struct SubtitleRow: View {
    let caption: LiveCaptionsController.Caption
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if caption.state != .done && !caption.fast.isEmpty {
                // bản nhanh hiện ngay; bản chuẩn (mô hình + glossary) thay vào khi xong
                Text("\(Image(systemName: "bolt.fill")) \(caption.fast)")
                    .font(.system(size: 19 * scale, weight: .medium))
                    .foregroundStyle(Color.secondary)
            } else {
            switch caption.state {
            case .queued:
                Text("…").font(.system(size: 19 * scale)).foregroundStyle(.tertiary)
            case .translating, .done:
                Text(caption.vi.isEmpty ? "…" : caption.vi)
                    .font(.system(size: 19 * scale, weight: .medium))
                    .foregroundStyle(caption.state == .done ? Color.primary : Color.secondary)
            }
            }
            if !caption.missing.isEmpty {
                Text(caption.missing.map { "⚠︎ \($0.matched) → \($0.translations.first ?? "")" }.joined(separator: "  "))
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
