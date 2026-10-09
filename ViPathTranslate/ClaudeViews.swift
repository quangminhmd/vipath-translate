import SwiftUI

// MARK: - Cài đặt Claude

struct ClaudeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranslatorViewModel.self) private var vm
    @State private var keyInput = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkOK = false
    private var claude: ClaudeService { ClaudeService.shared }
    private var suggestions: TermSuggestionStore { TermSuggestionStore.shared }

    var body: some View {
        @Bindable var claude = self.claude
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $claude.isEnabled) {
                        Label("Kết nối Claude", systemImage: claude.isEnabled ? "cloud.fill" : "icloud.slash")
                    }
                    .disabled(!claude.hasKey)
                    LabeledContent("Internet") {
                        Text(claude.networkAvailable ? "Có" : "Không có")
                            .foregroundStyle(claude.networkAvailable ? .green : .orange)
                    }
                    LabeledContent("Trạng thái", value: claude.statusText)
                } footer: {
                    Text("Khi ngắt kết nối, app không gửi bất kỳ dữ liệu nào ra ngoài — mọi bản dịch chạy offline trên iPhone.")
                }

                Section {
                    if claude.hasKey {
                        LabeledContent("Key đã lưu", value: claude.keyHint ?? "••••")
                        Button {
                            Task { await check() }
                        } label: {
                            HStack {
                                Text("Kiểm tra key")
                                if checking { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(checking || !claude.networkAvailable)
                        if let r = checkResult {
                            Text(r).font(.caption).foregroundStyle(checkOK ? .green : .red)
                        }
                        Button("Xoá key khỏi Keychain", role: .destructive) {
                            claude.deleteKey()
                            claude.isEnabled = false
                            checkResult = nil
                        }
                    }
                    SecureField(claude.hasKey ? "Nhập key mới để thay" : "sk-ant-…", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button("Lưu vào Keychain") {
                        if claude.saveKey(keyInput) {
                            keyInput = ""
                            claude.isEnabled = true
                            checkResult = nil
                        }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                } header: {
                    Text("API key Anthropic")
                } footer: {
                    Text("Key do bạn tự tạo tại console.anthropic.com và chỉ lưu trong Keychain của iPhone này (không đồng bộ iCloud, không sao lưu sang máy khác). App không nhúng key; chi phí tính vào tài khoản API của bạn.")
                }

                Section {
                    Picker("Mô hình", selection: $claude.model) {
                        ForEach(ClaudeModel.allCases) { Text($0.shortName).tag($0) }
                    }
                    Text(claude.model.summary).font(.caption).foregroundStyle(.secondary)
                    if claude.sessionInputTokens > 0 {
                        LabeledContent("Token phiên này",
                                       value: "\(claude.sessionInputTokens) vào · \(claude.sessionOutputTokens) ra")
                            .font(.caption)
                    }
                } header: {
                    Text("Mô hình")
                }

                Section {
                    Label("Tự động che họ tên, PID / mã hồ sơ, mã bệnh phẩm, ngày sinh, CCCD / hộ chiếu, SĐT, email, địa chỉ trước khi gửi.",
                          systemImage: "eye.slash")
                    Label("Bạn xem bản đã che và phải xác nhận trước mỗi lần gửi.", systemImage: "checkmark.shield")
                    Label("Giá trị thật chỉ nằm trên máy; app đặt lại vào bản dịch sau khi Claude trả kết quả.",
                          systemImage: "iphone")
                    Label("Chỉ dùng cho đại thể, vi thể, kết luận, bài báo, giáo trình, slide — không gửi hồ sơ bệnh án đầy đủ.",
                          systemImage: "doc.text")
                } header: {
                    Text("Bảo vệ thông tin bệnh nhân")
                }
                .font(.caption)

                Section {
                    LabeledContent("Đã học", value: "\(suggestions.approvedCount) thuật ngữ")
                    NavigationLink {
                        TermReviewView(glossary: vm.glossary, embedded: true)
                    } label: {
                        LabeledContent("Chờ duyệt", value: "\(suggestions.pending.count)")
                    }
                } header: {
                    Text("Vòng học thuật ngữ")
                } footer: {
                    Text("Khi Claude sửa một thuật ngữ hiếm, app đề xuất thêm vào glossary. Sau khi bác sĩ duyệt, mô hình offline dùng đúng thuật ngữ đó ở các lần sau — càng dùng càng ít phải gọi Claude.")
                }
            }
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            try await claude.verifyKey()
            checkOK = true
            checkResult = "Key hợp lệ."
        } catch {
            checkOK = false
            checkResult = error.localizedDescription
        }
    }
}

// MARK: - Xác nhận che định danh trước khi gửi

struct RedactionConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var request: ClaudeRequest
    @State private var confirmed = false
    @State private var extra = ""
    let onSend: (ClaudeRequest) -> Void
    private var claude: ClaudeService { ClaudeService.shared }

    init(request: ClaudeRequest, onSend: @escaping (ClaudeRequest) -> Void) {
        _request = State(initialValue: request)
        self.onSend = onSend
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let counts = request.redaction.counts
                    if counts.isEmpty {
                        Label("Không phát hiện thông tin định danh. Hãy đọc kỹ văn bản bên dưới trước khi gửi.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(counts) { c in
                            LabeledContent(c.kind.label) {
                                Text("\(c.count) đã che").foregroundStyle(.green)
                            }
                        }
                    }
                } header: {
                    Text("Đã che tự động")
                } footer: {
                    Text("\(request.draft == nil ? "Dịch" : "Hiệu đính bản dịch offline") · \(request.direction.label) · \(claude.model.shortName)")
                }

                Section {
                    Text(Self.highlight(request.redactedSource))
                        .font(.callout)
                        .textSelection(.enabled)
                    if let d = request.redactedDraft {
                        DisclosureGroup("Bản dịch offline gửi kèm") {
                            Text(Self.highlight(d)).font(.callout).textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Nội dung sẽ gửi tới Claude")
                }

                Section {
                    TextField("Cụm cần che thêm, ngăn bởi dấu phẩy", text: $extra, axis: .vertical)
                        .autocorrectionDisabled()
                    Button("Che thêm") {
                        let terms = extra.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        request.setExtraTerms(terms)
                        confirmed = false
                    }
                    .disabled(extra.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Còn sót thông tin định danh?")
                } footer: {
                    Text("Ví dụ: tên bác sĩ, tên bệnh viện, số giường… Mỗi cụm được thay bằng [ẨN_n].")
                }

                if !request.redaction.replacements.isEmpty {
                    Section {
                        DisclosureGroup("Bảng đối chiếu (\(request.redaction.replacements.count))") {
                            ForEach(request.redaction.replacements) { r in
                                LabeledContent(r.placeholder, value: r.original)
                                    .font(.caption)
                            }
                        }
                    } footer: {
                        Text("Bảng này chỉ nằm trên iPhone, không gửi đi. App dùng nó để đặt lại giá trị thật vào bản dịch.")
                    }
                }

                Section {
                    Toggle(isOn: $confirmed) {
                        Text("Tôi đã kiểm tra: nội dung trên không còn họ tên, PID, CCCD / hộ chiếu, mã bệnh phẩm, ngày sinh hay thông tin định danh nào khác của bệnh nhân.")
                            .font(.callout)
                    }
                    Button {
                        onSend(request)
                        dismiss()
                    } label: {
                        Label("Gửi tới Claude", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!confirmed || !claude.isReady)
                } footer: {
                    if !claude.isReady { Text(claude.statusText).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Xác nhận trước khi gửi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } } }
        }
        .interactiveDismissDisabled(false)
    }

    private static let placeholderRegex =
        try! NSRegularExpression(pattern: #"\[(?:TÊN|PID|MÃ_BP|NGÀY_SINH|NGÀY|GIẤY_TỜ|SĐT|EMAIL|ĐỊA_CHỈ|ẨN)_\d+\]"#)

    /// Tô màu các nhãn che để bác sĩ thấy rõ chỗ đã che.
    static func highlight(_ text: String) -> AttributedString {
        let ns = text as NSString
        var out = AttributedString()
        var last = 0
        for m in placeholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += AttributedString(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            var tag = AttributedString(ns.substring(with: m.range))
            tag.foregroundColor = Color.white
            tag.backgroundColor = Color.green
            tag.font = Font.callout.bold()
            out += tag
            last = m.range.location + m.range.length
        }
        out += AttributedString(ns.substring(from: last))
        return out
    }
}

// MARK: - Duyệt thuật ngữ Claude đề xuất

struct TermReviewView: View {
    let glossary: GlossaryStore
    let embedded: Bool
    @Environment(\.dismiss) private var dismiss
    private var store: TermSuggestionStore { TermSuggestionStore.shared }

    init(glossary: GlossaryStore, embedded: Bool = false) {
        self.glossary = glossary
        self.embedded = embedded
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
            }
        }
    }

    private var content: some View {
        List {
            if store.pending.isEmpty {
                ContentUnavailableView("Không có đề xuất chờ duyệt", systemImage: "checkmark.seal",
                                       description: Text("Đã học \(store.approvedCount) thuật ngữ từ Claude."))
            } else {
                Section {
                    ForEach(store.pending) { s in
                        TermReviewRow(suggestion: s, glossary: glossary)
                    }
                } footer: {
                    Text("Sửa lại nếu cần rồi bấm Duyệt. Thuật ngữ đã duyệt được thêm vào glossary của bạn (tab Thuật ngữ) và được chèn vào prompt của mô hình offline từ lần dịch sau.")
                }
            }
        }
        .navigationTitle("Duyệt thuật ngữ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TermReviewRow: View {
    let suggestion: TermSuggestion
    let glossary: GlossaryStore
    @State private var en: String
    @State private var vi: String
    private var store: TermSuggestionStore { TermSuggestionStore.shared }

    init(suggestion: TermSuggestion, glossary: GlossaryStore) {
        self.suggestion = suggestion
        self.glossary = glossary
        _en = State(initialValue: suggestion.english)
        _vi = State(initialValue: suggestion.vietnamese)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Tiếng Anh", text: $en).font(.body.bold()).autocorrectionDisabled()
            TextField("Tiếng Việt", text: $vi).autocorrectionDisabled()
            if let old = suggestion.existingVi {
                Label("Glossary hiện có: \(old) — duyệt sẽ thay bằng bản mới", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !suggestion.note.isEmpty {
                Text(suggestion.note).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(suggestion.model).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Bỏ qua", role: .destructive) { store.reject(suggestion) }
                    .buttonStyle(.glass)
                Button("Duyệt") {
                    store.approve(suggestion, english: en, vietnamese: vi, note: suggestion.note, glossary: glossary)
                }
                .buttonStyle(.glassProminent)
                .disabled(en.trimmingCharacters(in: .whitespaces).count < 2
                          || vi.trimmingCharacters(in: .whitespaces).count < 2)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
