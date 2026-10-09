import SwiftUI

enum AppTab: Hashable { case translate, gross, captions, settings, transcribe, glossary, saved }

/// Chuyển tab từ trong app (vd. Đại thể → Dịch sang tiếng Anh).
@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .translate
}

@main
struct ViPathTranslateApp: App {
    @State private var viewModel: TranslatorViewModel
    @State private var typing: LiveTypingTranslator
    @State private var captions: LiveCaptionsController
    @State private var transcribe: TranscribeController
    @State private var gross = GrossDictationController()
    @State private var router = AppRouter()
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
            TabView(selection: $router.tab) {
                Tab("Dịch", systemImage: "character.book.closed", value: AppTab.translate) { TranslatorView() }
                Tab("Đại thể", systemImage: "scissors", value: AppTab.gross) { GrossDictationView() }
                Tab("Phụ đề", systemImage: "captions.bubble", value: AppTab.captions) { LiveCaptionsView() }
                Tab("Cài đặt", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
                Tab("Chép lời", systemImage: "waveform", value: AppTab.transcribe) { TranscribeView() }
                Tab("Thuật ngữ", systemImage: "text.book.closed", value: AppTab.glossary) { GlossaryView() }
                    .badge(TermSuggestionStore.shared.pending.count)
                Tab("Đã lưu", systemImage: "tray.full", value: AppTab.saved) { SavedListView() }
            }
            .environment(viewModel)
            .environment(typing)
            .environment(captions)
            .environment(transcribe)
            .environment(gross)
            .environment(router)
            .task {
                // "Tự nạp khi mở app" (tab Cài đặt): nạp mô hình dịch + Whisper đã chọn
                if UserDefaults.standard.bool(forKey: "autoLoadModels") {
                    await ModelLoader.loadAll(vm: viewModel, gross: gross, compute: transcribe.whisperCompute)
                }
            }
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
