import SwiftUI

/// Tra cứu glossary và thêm thuật ngữ riêng (lưu trong máy, ưu tiên hơn glossary gốc).
struct GlossaryView: View {
    @Environment(TranslatorViewModel.self) private var vm
    @State private var query = ""
    @State private var showAdd = false

    private var store: GlossaryStore { vm.glossary }

    private var filtered: [GlossaryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.allEntries
        guard !q.isEmpty else { return all }
        return all.filter { $0.en.lowercased().contains(q) || $0.vi.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let err = store.loadError {
                    Text(err).foregroundStyle(.red)
                }
                if query.isEmpty, !TermSuggestionStore.shared.pending.isEmpty || TermSuggestionStore.shared.approvedCount > 0 {
                    Section {
                        NavigationLink {
                            TermReviewView(glossary: store, embedded: true)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(TermSuggestionStore.shared.pending.count) thuật ngữ Claude đề xuất chờ duyệt")
                                        .font(.subheadline.bold())
                                    Text("Đã học \(TermSuggestionStore.shared.approvedCount) thuật ngữ · mô hình offline dùng ngay sau khi duyệt")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "graduationcap.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                if !store.userEntries.isEmpty, query.isEmpty {
                    Section("Thuật ngữ của tôi") {
                        ForEach(store.userEntries) { row($0) }
                            .onDelete { idx in idx.map { store.userEntries[$0] }.forEach { store.deleteUserEntry($0) } }
                    }
                }
                Section(query.isEmpty ? "Glossary Vitranslate (\(store.base?.entries.count ?? 0))" : "Kết quả (\(filtered.count))") {
                    ForEach(query.isEmpty ? (store.base?.entries ?? []) : filtered) { row($0) }
                }
            }
            .searchable(text: $query, prompt: "Tìm tiếng Anh hoặc tiếng Việt")
            .navigationTitle("Thuật ngữ")
            .toolbar {
                Button("Thêm", systemImage: "plus") { showAdd = true }
            }
            .sheet(isPresented: $showAdd) { AddTermSheet() }
        }
    }

    private func row(_ e: GlossaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(e.en).font(.subheadline.bold())
                if e.isUser == true { Image(systemName: "person.fill").font(.caption2).foregroundStyle(.tint) }
            }
            Text(e.vi).font(.subheadline)
            if !e.note.isEmpty { Text(e.note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct AddTermSheet: View {
    @Environment(TranslatorViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var en = ""
    @State private var vi = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("English (nhiều biến thể: a / b)", text: $en)
                        .textInputAutocapitalization(.never)
                    TextField("Tiếng Việt", text: $vi)
                    TextField("Ghi chú (tuỳ chọn)", text: $note)
                } footer: {
                    Text("Thuật ngữ của bạn được ưu tiên khi chèn vào prompt và lưu ngay trên máy.")
                }
            }
            .navigationTitle("Thêm thuật ngữ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        vm.glossary.addUserEntry(en: en, vi: vi, note: note)
                        dismiss()
                    }
                    .disabled(en.trimmingCharacters(in: .whitespaces).isEmpty || vi.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
