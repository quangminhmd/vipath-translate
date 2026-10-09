import SwiftUI
import UIKit

/// Tab "Đã lưu": bản dịch văn bản và phiên phụ đề đã lưu trên máy.
struct SavedListView: View {
    @State private var query = ""
    @State private var filter: Filter = .all
    private var store: SavedStore { SavedStore.shared }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tất cả", text = "Văn bản", captions = "Phụ đề", gross = "Đại thể"
        var id: String { rawValue }
    }

    private var items: [SavedItem] {
        store.items.filter { item in
            switch filter {
            case .all: true
            case .text: item.kind == .text
            case .captions: item.kind == .captions || item.kind == .transcript
            case .gross: item.kind == .gross
            }
        }
        .filter { item in
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(q)
                || item.source.localizedCaseInsensitiveContains(q)
                || item.translation.localizedCaseInsensitiveContains(q)
                || (item.claudeTranslation ?? "").localizedCaseInsensitiveContains(q)
                || (item.pairs ?? []).contains { $0.source.localizedCaseInsensitiveContains(q)
                                                  || $0.translation.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Loại", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                ForEach(items) { item in
                    NavigationLink(value: item.id) { SavedRow(item: item) }
                }
                .onDelete { idx in
                    let list = items
                    for i in idx { store.delete(list[i]) }
                }
            }
            .overlay {
                if store.items.isEmpty {
                    ContentUnavailableView("Chưa lưu gì", systemImage: "tray",
                                           description: Text("Bấm Lưu ở tab Dịch, hoặc dừng phiên Phụ đề để lưu tự động."))
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Tìm trong bản lưu")
            .navigationTitle("Đã lưu")
            .navigationDestination(for: UUID.self) { id in
                if let item = store.items.first(where: { $0.id == id }) {
                    SavedDetailView(item: item)
                }
            }
            .onAppear { store.reload() }
        }
    }
}

private struct SavedRow: View {
    let item: SavedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.kind == .captions ? "captions.bubble" : item.kind == .transcript ? "waveform" : item.kind == .gross ? "scissors" : "doc.text")
                    .foregroundStyle(.secondary)
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(item.direction.label)
                if item.claudeTranslation != nil { Image(systemName: "sparkles") }
                if item.kind == .captions || item.kind == .transcript, let n = item.pairs?.count { Text("· \(n) đoạn") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct SavedDetailView: View {
    let item: SavedItem
    @State private var title: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private var store: SavedStore { SavedStore.shared }

    init(item: SavedItem) {
        self.item = item
        _title = State(initialValue: item.title)
    }

    var body: some View {
        List {
            Section {
                TextField("Tiêu đề", text: $title)
                    .font(.headline)
                    .onSubmit { store.rename(item, to: title) }
                Text("\(item.createdAt.formatted(date: .long, time: .shortened)) · \(item.direction.label) · \(item.engine)"
                     + (item.duration.map { " · " + SavedItem.timestamp($0) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }

            switch item.kind {
            case .gross:
                textSection("Mô tả đại thể", item.source, speak: true)
                if !item.translation.isEmpty { textSection(item.direction.targetName, item.translation) }
            case .text:
                textSection(item.direction.sourceName, item.source)
                if !item.translation.isEmpty {
                    textSection("\(item.direction.targetName) · offline", item.translation, speak: item.direction == .enToVi)
                }
                if let c = item.claudeTranslation, !c.isEmpty {
                    textSection("\(item.direction.targetName) · \(item.claudeModel ?? "Claude")", c,
                                speak: item.direction == .enToVi)
                }
            case .captions, .transcript:
                Section {
                    ForEach(Array((item.pairs ?? []).enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SavedItem.timestamp(p.offset)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            Text(p.source).font(.subheadline).foregroundStyle(.secondary)
                            Text(p.translation)
                        }
                        .textSelection(.enabled)
                    }
                } header: {
                    HStack {
                        Text("\(item.direction.sourceName) → \(item.direction.targetName)")
                        Spacer()
                        SpeakButton(text: item.translationOnly)
                    }
                }
            }
        }
        .navigationTitle(item.kind == .captions ? "Phụ đề" : item.kind == .transcript ? "Chép lời" : item.kind == .gross ? "Đại thể" : "Bản dịch")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { if title != item.title { store.rename(item, to: title) } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: item.exportText, subject: Text(item.title)) {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button("Chép tất cả", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.exportText }
                    Button("Chép bản dịch", systemImage: "doc.on.clipboard") {
                        UIPasteboard.general.string = item.translationOnly
                    }
                    if item.kind == .captions || item.kind == .transcript {
                        Section("Xuất phụ đề") {
                            ForEach(SubtitleContent.allCases) { c in
                                ShareLink(item: SubtitleFile(fileName: "\(item.title.prefix(40)).\(c.rawValue).srt",
                                                             content: SubtitleWriter.render(item.segments, format: .srt, content: c)),
                                          preview: SharePreview("SRT \(c.label)")) {
                                    Label("SRT · \(c.label)", systemImage: "captions.bubble")
                                }
                            }
                        }
                    }
                    Button("Xoá", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Xoá bản lưu này?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) {
                store.delete(item)
                dismiss()
            }
        }
    }

    private func textSection(_ header: String, _ text: String, speak: Bool = false) -> some View {
        Section {
            Text(text).textSelection(.enabled)
        } header: {
            HStack {
                Text(header)
                Spacer()
                if speak { SpeakButton(text: text) }
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                    .font(.caption)
            }
        }
    }
}
