import SwiftUI

@main
struct ViPathTranslateApp: App {
    @State private var viewModel: TranslatorViewModel
    @State private var typing: LiveTypingTranslator
    @State private var captions: LiveCaptionsController
    @State private var transcribe: TranscribeController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let vm = TranslatorViewModel()
        _viewModel = State(initialValue: vm)
        _typing = State(initialValue: LiveTypingTranslator(vm: vm))
        _captions = State(initialValue: LiveCaptionsController(vm: vm))
        _transcribe = State(initialValue: TranscribeController(vm: vm))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Dịch", systemImage: "character.book.closed") { TranslatorView() }
                Tab("Phụ đề", systemImage: "captions.bubble") { LiveCaptionsView() }
                Tab("Chép lời", systemImage: "waveform") { TranscribeView() }
                Tab("Thuật ngữ", systemImage: "text.book.closed") { GlossaryView() }
                    .badge(TermSuggestionStore.shared.pending.count)
                Tab("Đã lưu", systemImage: "tray.full") { SavedListView() }
            }
            .environment(viewModel)
            .environment(typing)
            .environment(captions)
            .environment(transcribe)
        }
        .onChange(of: scenePhase) { _, phase in
            let active = (phase == .active)
            AppActivity.shared.isActive = active
            if !active {
                // iPhone không cho gửi lệnh GPU ở nền → dừng mọi lượt sinh trước khi app ra nền.
                viewModel.stop()
                typing.cancel()
                // (yêu cầu Claude đang chạy qua mạng vẫn được tiếp tục — không dùng GPU)
                captions.pauseGeneration()
                transcribe.stopTranslating()   // dịch tiếp bằng nút "Dịch tiếp" khi quay lại
            } else if UserDefaults.standard.bool(forKey: "liveTyping") {
                typing.textChanged(viewModel.input)   // dịch bù các câu bị dừng giữa chừng
            }
        }
    }
}
