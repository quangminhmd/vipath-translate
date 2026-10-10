import SwiftUI
import UIKit

enum AppTab: Hashable, CaseIterable {
    case translate, captions, transcribe, gross, glossary, saved, settings

    var title: String {
        switch self {
        case .translate: "Dịch"
        case .captions: "Phụ đề"
        case .transcribe: "Chép lời"
        case .gross: "Đại thể"
        case .glossary: "Thuật ngữ"
        case .saved: "Đã lưu"
        case .settings: "Cài đặt"
        }
    }
    var icon: String {
        switch self {
        case .translate: "character.book.closed"
        case .captions: "captions.bubble"
        case .transcribe: "waveform"
        case .gross: "scissors"
        case .glossary: "text.book.closed"
        case .saved: "tray.full"
        case .settings: "gearshape"
        }
    }
}

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
            RootView()
            .environment(viewModel)
            .environment(typing)
            .environment(captions)
            .environment(transcribe)
            .environment(gross)
            .environment(router)
            .task {
                // "Tự nạp khi mở app" (tab Cài đặt): nạp mô hình dịch + Whisper đã chọn
                if ModelLoader.autoLoadEnabled {
                    await ModelLoader.loadAll(vm: viewModel, gross: gross, compute: transcribe.whisperCompute,
                                              first: router.tab)
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

/// iPhone (và iPad khi chia đôi màn hình hẹp): thanh tab dưới.
/// iPad màn hình rộng: thanh bên luôn hiện ĐỦ 7 mục — không gom vào "Thêm", không phải mở menu.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns: NavigationSplitViewVisibility = .all

    private var useSidebar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }

    var body: some View {
        @Bindable var router = router
        if useSidebar {
            NavigationSplitView(columnVisibility: $columns) {
                List(selection: Binding<AppTab?>(get: { router.tab }, set: { if let t = $0 { router.tab = t } })) {
                    ForEach(AppTab.allCases, id: \.self) { t in
                        Label(t.title, systemImage: t.icon)
                            .badge(t == .glossary ? TermSuggestionStore.shared.pending.count : 0)
                            .tag(t as AppTab?)
                    }
                }
                .navigationTitle("ViPath")
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
            } detail: {
                Self.content(for: router.tab)
                    .id(router.tab)
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            TabView(selection: $router.tab) {
                ForEach(AppTab.allCases, id: \.self) { t in
                    Tab(t.title, systemImage: t.icon, value: t) { Self.content(for: t) }
                        .badge(t == .glossary ? TermSuggestionStore.shared.pending.count : 0)
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
        }
    }

    @ViewBuilder
    static func content(for tab: AppTab) -> some View {
        switch tab {
        case .translate: TranslatorView()
        case .captions: LiveCaptionsView()
        case .transcribe: TranscribeView()
        case .gross: GrossDictationView()
        case .glossary: GlossaryView()
        case .saved: SavedListView()
        case .settings: SettingsView()
        }
    }
}
