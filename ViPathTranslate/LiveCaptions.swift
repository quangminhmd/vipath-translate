import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// Kiểu 2 — phụ đề trực tiếp: âm thanh → nhận dạng tiếng Anh trên máy → tách câu →
/// khớp glossary → LLM dịch → phụ đề song ngữ. Mọi thứ chạy offline.
@MainActor
@Observable
final class LiveCaptionsController {
    enum Source: String, CaseIterable, Identifiable {
        case microphone, broadcast
        var id: String { rawValue }
        var title: String {
            switch self {
            case .microphone: "Micro"
            case .broadcast: "Âm thanh app (Zoom/Teams)"
            }
        }
        var hint: String {
            switch self {
            case .microphone:
                "Nghe giảng / hội thảo tại chỗ, hoặc đặt iPhone cạnh loa máy tính đang họp Zoom/Teams."
            case .broadcast:
                "Họp Zoom/Teams ngay trên iPhone này: bật Phát sóng màn hình → chọn ViPath, rồi để cuộc họp ở chế độ Hình trong hình (PiP) và mở lại app này."
            }
        }
    }

    enum CaptionState { case queued, translating, done }

    /// Cân bằng tốc độ / độ chính xác của phụ đề.
    enum Mode: String, CaseIterable, Identifiable {
        case fastest, balanced, accurate
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fastest: "Nhanh nhất"
            case .balanced: "Cân bằng"
            case .accurate: "Chính xác"
            }
        }
        var detail: String {
            switch self {
            case .fastest: "Chỉ dùng Dịch nhanh (Apple) — gần như tức thì, không theo glossary."
            case .balanced: "⚡ hiện ngay, mô hình + glossary thay vào. Khi người nói nhanh hơn mô hình, câu cũ giữ bản ⚡ để phụ đề không bị tụt lại."
            case .accurate: "Mọi câu đều qua mô hình + glossary; có thể trễ vài giây khi nói nhanh."
            }
        }
    }

    struct Caption: Identifiable {
        let id: Int
        var en: String
        var vi: String = ""
        /// Bản dịch nhanh (Apple Translation) hiện tạm trong lúc chờ mô hình + glossary
        var fast: String = ""
        var hits: [GlossaryHit] = []
        var missing: [GlossaryHit] = []
        var state: CaptionState = .queued
        let heardAt: Date
        var delay: TimeInterval?
        /// Bản cuối là bản ⚡ (bỏ qua mô hình để đuổi kịp người nói)
        var fastFinal = false
    }

    // Trạng thái hiển thị
    var source: Source = .microphone
    var isRunning = false
    var status = ""
    var volatileText = ""        // câu đang nói, chưa chốt (chữ xám)
    /// Bản dịch nhanh của câu đang nói — phụ đề xuất hiện trước khi câu chốt
    var volatileFast = ""
    var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "captionsMode") ?? "") ?? .balanced {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "captionsMode") }
    }
    /// Phụ đề lớn: chỉ hiện vài câu cuối, chữ to (chiếu lên màn hình, xem từ xa)
    var bigMode: Bool = UserDefaults.standard.bool(forKey: "captionsBigMode") {
        didSet { UserDefaults.standard.set(bigMode, forKey: "captionsBigMode") }
    }
    var captions: [Caption] = []
    var errorText: String?
    var lastDelay: TimeInterval = 0
    var fontScale: Double = 1.0
    var showEnglish = true
    /// Thông dịch bằng giọng: đọc to từng câu tiếng Việt (cần tai nghe để micro không thu lại).
    var speakTranslations = false

    private let vm: TranslatorViewModel
    private var transcriber: EnglishTranscriber?
    private var audio: AudioSource?
    private var pendingText = ""                 // phần đã chốt nhưng chưa thành câu trọn
    private var lastFinalAt = Date()
    private var queue: [Int] = []                // id phụ đề chờ dịch
    private var worker: Task<Void, Never>?
    private var flusher: Task<Void, Never>?
    private var current: Task<Void, Never>?      // lượt dịch đang chạy (để huỷ khi app ra nền)
    private var currentID: Int?
    private var nextID = 0
    private var stopping = false
    private var starting = false                 // chặn bấm "Bắt đầu" hai lần khi đang xin quyền

    /// Câu nói không có dấu chấm (rất thường gặp khi nói) → ép cắt khi quá dài / im lặng.
    private let maxWordsPerCaption = 24
    /// Câu dài có dấu phẩy → cắt ở dấu phẩy cuối khi đạt số từ này (câu ngắn dịch nhanh hơn).
    private let clauseWords = 14
    private let silenceFlush: TimeInterval = 0.9
    /// Chế độ Chính xác: tồn đọng ≥ số câu này → gộp lại dịch một lượt để đuổi kịp người nói.
    private let catchUpThreshold = 3
    /// Chế độ Cân bằng: câu chờ lâu hơn ngưỡng này mà đã có bản ⚡ → giữ bản ⚡.
    private let staleAfter: TimeInterval = 6
    private var volatileTask: Task<Void, Never>?
    /// Chế độ thực tế: "Nhanh nhất" chỉ khi Dịch nhanh sẵn sàng; không có mô hình → như Nhanh nhất.
    private var effectiveMode: Mode {
        let fastOK = FastTranslator.shared.isActive(.enToVi)
        if vm.loadedModel == nil { return .fastest }
        if mode == .fastest && !fastOK { return .balanced }
        return mode
    }

    init(vm: TranslatorViewModel) { self.vm = vm }

    /// Tự lưu phiên phụ đề khi bấm Dừng (tab Đã lưu).
    var autoSave: Bool = UserDefaults.standard.object(forKey: "captionsAutoSave") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSave, forKey: "captionsAutoSave") }
    }
    /// Tỉ lệ chiều cao khung tiếng Anh (trên) so với toàn màn hình phụ đề.
    var topRatio: Double = UserDefaults.standard.object(forKey: "captionsTopRatio") as? Double ?? 0.38 {
        didSet { UserDefaults.standard.set(topRatio, forKey: "captionsTopRatio") }
    }
    private(set) var lastSavedAt: Date?
    /// Bản lưu tương ứng với danh sách phụ đề hiện tại (lưu lại thì ghi đè, không tạo bản trùng).
    private var savedID: UUID?
    private var savedCreatedAt: Date?

    /// Lưu toàn bộ phụ đề đang hiển thị. Trả về false nếu chưa có câu nào dịch xong.
    @discardableResult
    func saveSession() -> Bool {
        let done = captions.filter { !$0.vi.isEmpty }
        guard let first = done.first else { return false }
        let pairs = done.map {
            SavedItem.Pair(source: $0.en, translation: $0.vi, offset: $0.heardAt.timeIntervalSince(first.heardAt))
        }
        let id = savedID ?? UUID()
        let created = savedCreatedAt ?? first.heardAt
        let title = "Phụ đề \(created.formatted(date: .numeric, time: .shortened)) — "
            + SavedItem.autoTitle(first.en)
        // giữ tiêu đề người dùng đã đổi
        let keptTitle = SavedStore.shared.items.first { $0.id == id }?.title ?? title
        let item = SavedItem(id: id, kind: .captions, createdAt: created, title: keptTitle, direction: .enToVi,
                             engine: vm.loadedModel?.shortName ?? "—",
                             source: done.map(\.en).joined(separator: "\n"),
                             translation: done.map(\.vi).joined(separator: "\n"),
                             pairs: pairs, duration: pairs.last?.offset)
        guard SavedStore.shared.save(item) else { return false }
        savedID = id
        savedCreatedAt = created
        lastSavedAt = Date()
        return true
    }

    var transcriptText: String {
        captions.map { showEnglish ? "\($0.en)\n\($0.vi)" : $0.vi }.joined(separator: "\n\n")
    }

    // MARK: Bắt đầu / dừng

    func start() async {
        guard !isRunning, !starting else { return }
        starting = true
        defer { starting = false }
        errorText = nil
        guard vm.loadedModel != nil || FastTranslator.shared.isActive(.enToVi) else {
            errorText = "Hãy nạp mô hình dịch (tab Dịch) hoặc bật Dịch nhanh trong Tuỳ chọn."
            return
        }
        if source == .microphone {
            guard await AVAudioApplication.requestRecordPermission() else {
                errorText = "Chưa cấp quyền micro (Cài đặt → ViPath → Micro)."
                return
            }
        }
        guard await EnglishTranscriber.requestAuthorization() else {
            errorText = "Chưa cấp quyền nhận dạng giọng nói (Cài đặt → ViPath)."
            return
        }

        isRunning = true
        stopping = false
        pendingText = ""
        volatileText = ""
        volatileFast = ""
        queue = []
        status = "Đang chuẩn bị…"
        UIApplication.shared.isIdleTimerDisabled = true   // không khoá màn hình khi đang nghe

        let transcriber = EnglishTranscriber()
        self.transcriber = transcriber
        do {
            try await transcriber.start(
                status: { s in Task { @MainActor in self.status = s } },
                onResult: { text, isFinal in Task { @MainActor in self.handle(text: text, isFinal: isFinal) } }
            )
            // người dùng bấm Dừng trong lúc đang tải mô hình nhận dạng → không bật micro nữa
            guard !stopping else {
                await teardown()
                status = "Đã dừng"
                return
            }
            guard let format = transcriber.analyzerFormat else { throw CaptionError.noFormat }
            let audio: AudioSource = (source == .microphone) ? MicrophoneSource() : BroadcastSource()
            try audio.start(format: format) { buffer in transcriber.feed(buffer) }
            self.audio = audio
            if source == .broadcast, !BroadcastSource.isBroadcastLive {
                status = "Chờ phát sóng: vuốt mở Trung tâm điều khiển → giữ nút Ghi màn hình → chọn ViPath"
            }
        } catch {
            errorText = error.localizedDescription
            await teardown()
            return
        }
        if vm.loadedModel != nil { startWorker() }   // không có mô hình → chỉ Dịch nhanh
        startFlusher()
    }

    func stop() async {
        guard isRunning else { return }
        if stopping {
            // bấm Dừng lần hai khi đang "dịch nốt" → bỏ hàng đợi, dừng ngay
            if !starting {
                queue = []
                worker?.cancel()
                current?.cancel()
            }
            return
        }
        stopping = true
        // start() còn đang chuẩn bị (xin quyền / tải mô hình) → để start() tự dọn, tránh hai nơi
        // cùng thao tác trên một EnglishTranscriber
        if starting {
            status = "Đang dừng…"
            return
        }
        audio?.stop()
        audio = nil
        await transcriber?.finish()
        transcriber = nil
        flushPending()
        flusher?.cancel()
        status = queue.isEmpty ? "Đã dừng" : "Đang dịch nốt…"
        await worker?.value                 // worker tự thoát khi hết hàng đợi
        await teardown()
        status = "Đã dừng"
        if autoSave, saveSession() { status = "Đã dừng · đã lưu vào tab Đã lưu" }
    }

    private func teardown() async {
        audio?.stop()
        audio = nil
        await transcriber?.finish()
        transcriber = nil
        worker?.cancel()
        current?.cancel()          // lượt dịch là Task riêng, không bị huỷ theo worker
        flusher?.cancel()
        volatileTask?.cancel()
        volatileTask = nil
        isRunning = false
        volatileText = ""
        volatileFast = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func clear() {
        guard !isRunning else { return }
        captions = []
        queue = []
        savedID = nil
        savedCreatedAt = nil
        lastSavedAt = nil
    }

    /// Gọi khi app sắp rời tiền cảnh: huỷ lượt sinh đang chạy (iPhone không cho dùng GPU ở nền),
    /// đưa câu đó về đầu hàng đợi để dịch lại khi quay về.
    func pauseGeneration() {
        guard let id = currentID else { return }
        current?.cancel()
        if let i = index(of: id), captions[i].state != .done {
            captions[i].state = .queued
            if !queue.contains(id) { queue.insert(id, at: 0) }
        }
    }

    // MARK: Nhận dạng → câu

    private func handle(text: String, isFinal: Bool) {
        guard isRunning else { return }   // kết quả trễ của phiên đã dừng
        if isFinal {
            volatileText = ""
            volatileFast = ""
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            pendingText = pendingText.isEmpty ? t : pendingText + " " + t
            lastFinalAt = Date()
            let (complete, rest) = SentenceSplitter.completeSentences(in: pendingText)
            for s in complete { enqueue(s) }   // tránh đổi hàm @MainActor sang kiểu closure không cô lập
            pendingText = rest.trimmingCharacters(in: .whitespaces)
            splitLongClause()
            if pendingText.split(separator: " ").count >= maxWordsPerCaption { flushPending() }
        } else {
            volatileText = text
            translateVolatile()
        }
    }

    /// Câu dài chưa có dấu chấm: cắt tại dấu phẩy / chấm phẩy cuối cùng (vế trái ≥ 8 từ).
    private func splitLongClause() {
        let words = pendingText.split(separator: " ")
        guard words.count >= clauseWords else { return }
        var cut: String.Index?
        var count = 0
        var i = pendingText.startIndex
        while i < pendingText.endIndex {
            let ch = pendingText[i]
            if ch == " " { count += 1 }
            if (ch == "," || ch == ";"), count >= 7 { cut = pendingText.index(after: i) }
            i = pendingText.index(after: i)
        }
        guard let cut else { return }
        let left = String(pendingText[..<cut]).trimmingCharacters(in: .whitespaces)
        let right = String(pendingText[cut...]).trimmingCharacters(in: .whitespaces)
        guard right.split(separator: " ").count >= 2 else { return }   // vế phải quá ngắn → đợi thêm
        enqueue(left)
        pendingText = right
    }

    /// Dịch nhanh câu đang nói (chưa chốt): một lượt chạy tại một thời điểm, luôn lấy bản mới nhất.
    private func translateVolatile() {
        guard volatileTask == nil, FastTranslator.shared.isActive(.enToVi) else { return }
        volatileTask = Task {
            var last = ""
            while !Task.isCancelled {
                let src = (pendingText.isEmpty ? "" : pendingText + " ") + volatileText
                guard !volatileText.isEmpty, src != last else { break }
                last = src
                if let t = try? await FastTranslator.shared.translate(src, .enToVi), !volatileText.isEmpty {
                    volatileFast = t
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            volatileTask = nil
        }
    }

    private func flushPending() {
        let t = pendingText.trimmingCharacters(in: .whitespaces)
        pendingText = ""
        if !t.isEmpty { enqueue(t) }
        // bản xem trước gồm cả phần vừa chốt → dịch lại phần còn đang nói
        if volatileText.isEmpty { volatileFast = "" } else { translateVolatile() }
    }

    private func enqueue(_ sentence: String) {
        guard sentence.contains(where: \.isLetter) else { return }
        let c = Caption(id: nextID, en: sentence, heardAt: Date())
        nextID += 1
        captions.append(c)
        let useModel = effectiveMode != .fastest
        if useModel { queue.append(c.id) }
        if FastTranslator.shared.isActive(.enToVi) { fastTranslate(c.id, sentence, final: !useModel) }
    }

    /// Giữ bản ⚡ làm bản cuối (kèm kiểm tra glossary) cho câu không kịp qua mô hình.
    private func finalizeWithFast(_ id: Int) {
        guard let j = index(of: id), !captions[j].fast.isEmpty, captions[j].state != .done else { return }
        let hits = vm.glossary.matcher.hits(in: captions[j].en)
        captions[j].hits = hits
        captions[j].vi = captions[j].fast
        captions[j].missing = GlossaryQA.missing(hits: hits, source: captions[j].en, output: captions[j].fast)
        captions[j].state = .done
        captions[j].fastFinal = true
        let d = Date().timeIntervalSince(captions[j].heardAt)
        captions[j].delay = d
        lastDelay = d
        if speakTranslations { SpeechOutput.shared.speak(captions[j].fast, enqueue: true) }
    }

    /// Dịch nhanh bằng Apple Translation (chạy song song với mô hình, không dùng GPU).
    /// `final`: không có mô hình offline → bản nhanh là bản cuối.
    private func fastTranslate(_ id: Int, _ text: String, final: Bool) {
        Task {
            guard let t = try? await FastTranslator.shared.translate(text, .enToVi),
                  let j = index(of: id), captions[j].state != .done else { return }
            captions[j].fast = t
            if final {
                let hits = vm.glossary.matcher.hits(in: captions[j].en)
                captions[j].hits = hits
                captions[j].vi = t
                captions[j].missing = GlossaryQA.missing(hits: hits, source: captions[j].en, output: t)
                captions[j].state = .done
                captions[j].fastFinal = true
                let d = Date().timeIntervalSince(captions[j].heardAt)
                captions[j].delay = d
                lastDelay = d
                if speakTranslations { SpeechOutput.shared.speak(t, enqueue: true) }
            }
        }
    }

    private func startFlusher() {
        flusher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                if !pendingText.isEmpty, Date().timeIntervalSince(lastFinalAt) > silenceFlush {
                    flushPending()
                }
                if source == .broadcast, isRunning, BroadcastSource.isBroadcastLive, status.hasPrefix("Chờ") {
                    status = "Đang nghe âm thanh app"
                }
            }
        }
    }

    // MARK: Dịch theo hàng đợi

    private func index(of id: Int) -> Int? { captions.firstIndex { $0.id == id } }

    private func startWorker() {
        let engine = vm.engine
        worker = Task {
            while !Task.isCancelled {
                if queue.isEmpty {
                    // chỉ thoát khi stop() đã nhận xong kết quả cuối (transcriber == nil);
                    // kết quả cuối có thể đến sau flushPending() trong stop()
                    if stopping, transcriber == nil {
                        if !pendingText.isEmpty { flushPending(); continue }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                await AppActivity.shared.waitUntilActive()
                guard !Task.isCancelled, !queue.isEmpty else { continue }

                // Cân bằng: câu cũ đã có bản ⚡ (tồn đọng, hoặc chờ quá lâu) → giữ bản ⚡,
                // mô hình chỉ dịch câu mới nhất → phụ đề bám sát người nói.
                // (đổi sang Nhanh nhất giữa phiên → mọi câu đang chờ giữ bản ⚡)
                if effectiveMode != .accurate {
                    let newest = effectiveMode == .fastest ? nil : queue.last
                    let skip = queue.filter { id in
                        guard let j = index(of: id), !captions[j].fast.isEmpty else { return false }
                        return id != newest || Date().timeIntervalSince(captions[j].heardAt) > staleAfter
                    }
                    for id in skip { finalizeWithFast(id) }
                    queue.removeAll { skip.contains($0) }
                    if queue.isEmpty { continue }
                }

                // Tồn đọng nhiều → gộp các câu chờ vào câu đầu tiên, dịch một lượt.
                if queue.count >= catchUpThreshold {
                    let ids = queue
                    queue = [ids[0]]
                    if let first = index(of: ids[0]) {
                        let idx = ids.compactMap { index(of: $0) }
                        captions[first].en = idx.map { captions[$0].en }.joined(separator: " ")
                        captions[first].fast = idx.map { captions[$0].fast }.filter { !$0.isEmpty }.joined(separator: " ")
                    }
                    captions.removeAll { ids.dropFirst().contains($0.id) }
                }

                let id = queue.removeFirst()
                guard let i = index(of: id) else { continue }
                captions[i].hits = vm.glossary.matcher.hits(in: captions[i].en)
                captions[i].state = .translating
                let en = captions[i].en
                let hits = captions[i].hits
                // style guide làm prompt dài thêm → chỉ dùng ở chế độ Chính xác
                let style = effectiveMode == .accurate ? vm.glossary.styleGuide : ""
                currentID = id

                let job = Task {
                    do {
                        let stats = try await engine.translate(en, hits: hits, styleGuide: style) { t in
                            Task { @MainActor in
                                if let j = self.index(of: id), self.captions[j].state == .translating {
                                    self.captions[j].vi = t
                                }
                            }
                        }
                        guard !Task.isCancelled, let j = index(of: id) else { return }
                        captions[j].vi = stats.text
                        captions[j].missing = GlossaryQA.missing(hits: hits, source: en, output: stats.text)
                        captions[j].state = .done
                        if speakTranslations { SpeechOutput.shared.speak(stats.text, enqueue: true) }
                        let d = Date().timeIntervalSince(captions[j].heardAt)
                        captions[j].delay = d
                        lastDelay = d
                        vm.tokensPerSecond = stats.tokensPerSecond
                    } catch {
                        // bị huỷ do app ra nền → pauseGeneration đã đưa câu về hàng đợi;
                        // lỗi thật (vd. đang đổi mô hình) → báo lỗi thay vì treo "…" mãi
                        if !Task.isCancelled, let j = index(of: id), captions[j].state == .translating {
                            captions[j].vi = "⚠︎ \(error.localizedDescription)"
                            captions[j].state = .done
                        }
                    }
                }
                current = job
                await job.value
                current = nil
                currentID = nil
            }
        }
    }

    enum CaptionError: LocalizedError {
        case noFormat
        var errorDescription: String? { "Không xác định được định dạng âm thanh cho bộ nhận dạng." }
    }
}
