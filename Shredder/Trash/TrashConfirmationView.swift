import AppKit
import QuickLook
import SwiftUI

/// 削除時の確認（仕様 10.3）: 対象名・ファイル数・合計サイズ・場所・関連ファイル・共有データの注意。
/// サムネイルとプレビューで中身を確かめ、削除する項目を選び直せる。
struct TrashConfirmationView: View {
    let confirmation: TrashConfirmation
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<TrashCandidate.ID> = []
    @State private var focused: TrashCandidate.ID?
    @State private var quickLookURL: URL?

    private var chosen: [TrashCandidate] { confirmation.items.filter { selected.contains($0.id) } }
    private var chosenSize: Int64 { chosen.reduce(0) { $0 + $1.size } }
    private var focusedItem: TrashCandidate? { confirmation.items.first { $0.id == focused } ?? confirmation.items.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list
                    .frame(minWidth: 340)
                Divider()
                preview
                    .frame(width: 300)
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 600)
        .onAppear {
            selected = Set(confirmation.items.map(\.id))
            focused = confirmation.items.first?.id
        }
        .quickLookPreview($quickLookURL, in: confirmation.items.map(\.url))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.danger).frame(width: 46, height: 46)
                Image(systemName: "doc.text.below.ecg").font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
            .shadow(color: .pink.opacity(0.4), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(confirmation.title).font(.title3.weight(.bold))
                Text("選んだ項目を macOS のゴミ箱へ移動します。ゴミ箱を空にするまでは元に戻せます。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(LinearGradient(colors: [.pink.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing))
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                SelectAllControl(
                    selected: selected.count,
                    total: confirmation.items.count,
                    selectAll: { selected = Set(confirmation.items.map(\.id)) },
                    deselectAll: { selected = [] }
                )
                Spacer()
            }
            .padding(10)
            List(confirmation.items, selection: $focused) { item in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { selected.contains(item.id) },
                        set: { on in if on { selected.insert(item.id) } else { selected.remove(item.id) } }
                    )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    FileThumbnail(url: item.url, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent).lineLimit(1)
                        Text(item.url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let note = item.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .opacity(selected.contains(item.id) ? 1 : 0.45)
                .padding(.vertical, 2)
                .tag(item.id)
                .contextMenu {
                    Button("Quick Look") { quickLookURL = item.url }
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
                .accessibilityElement(children: .combine)
            }
            .onKeyPress(.space) {
                quickLookURL = focusedItem?.url
                return .handled
            }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 14) {
            if let item = focusedItem {
                FileThumbnail(url: item.url, size: 220)
                    .frame(maxWidth: .infinity, minHeight: 230)
                    .padding(.top, 18)
                    .id(item.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.url.lastPathComponent).font(.headline).lineLimit(2)
                    detail("サイズ", ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    detail("種類", kindName(item.url))
                    if let modified = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        detail("更新日", modified.formatted(date: .abbreviated, time: .shortened))
                    }
                    detail("場所", item.url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button { quickLookURL = item.url } label: { Label("Quick Look", systemImage: "eye") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Label("Finder", systemImage: "folder") }
                }
                .buttonStyle(.glass)
                Text("スペースキーでもプレビューできます").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .background(Color.secondary.opacity(0.04))
        .animation(.smooth(duration: 0.2), value: focused)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).lineLimit(2).truncationMode(.middle)
        }
        .font(.caption)
    }

    private func kindName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? "-"
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(confirmation.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(chosen.count) 項目").font(.headline.monospacedDigit()).contentTransition(.numericText())
                    Text("合計 \(ByteCountFormatter.string(fromByteCount: chosenSize, countStyle: .file))")
                        .font(.callout).foregroundStyle(.secondary).contentTransition(.numericText())
                }
                Spacer()
                Button("キャンセル", role: .cancel) {
                    dismiss()
                    confirmation.onCancel?()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                Button(role: .destructive) {
                    let items = chosen
                    dismiss()
                    confirmation.perform(items)
                } label: {
                    Label("シュレッダーにかける", systemImage: "doc.text.below.ecg")
                        .font(.headline)
                }
                .buttonStyle(.glassProminent)
                .tint(.pink)
                .controlSize(.large)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(16)
        .animation(.snappy, value: selected)
    }
}
