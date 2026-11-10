import AppKit
import ShredderCore
import SwiftUI

/// 削除済みアプリの残骸（仕様 11）。既定ではどれも選択しない。
struct LeftoversView: View {
    @Bindable var model: ApplicationsModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isScanningLeftovers {
                ProgressView("~/Library を調べています…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.leftoversScanned {
                ContentUnavailableView {
                    Label("削除済みアプリの残骸を探す", systemImage: "magnifyingglass")
                } description: {
                    Text("アンインストール済みのアプリが残したキャッシュや設定ファイルを探します。見つかった項目は候補として表示するだけで、自動では削除しません。")
                } actions: {
                    Button("スキャン") { model.scanLeftovers() }
                        .buttonStyle(.glassProminent)
                }
            } else if model.leftovers.isEmpty {
                ContentUnavailableView("残骸は見つかりませんでした", systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(model.leftovers) { group in
                        Section {
                            ForEach(group.items) { item in
                                RelatedItemRow(item: item, isOn: Binding(
                                    get: { model.leftoverSelection.contains(item.id) },
                                    set: { on in if on { model.leftoverSelection.insert(item.id) } else { model.leftoverSelection.remove(item.id) } }
                                ))
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
                Divider()
                footer
            }
        }
        .toolbar {
            Button("再スキャン", systemImage: "arrow.clockwise") { model.scanLeftovers() }
                .disabled(model.isScanningLeftovers)
        }
    }

    private func groupHeader(_ group: LeftoverGroup) -> some View {
        let selectable = group.items.filter(\.isSelectable)
        let allSelected = !selectable.isEmpty && selectable.allSatisfy { model.leftoverSelection.contains($0.id) }
        return HStack {
            Toggle(isOn: Binding(get: { allSelected }, set: { model.toggleGroup(group, selected: $0) })) {
                Text(group.bundleID).font(.headline)
            }
            .toggleStyle(.checkbox)
            if let related = group.relatedInstalledApp {
                Label("同じ開発元の「\(related)」がインストール済み", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if group.recentlyUsed {
                Label("最近更新あり", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: group.totalSize, countStyle: .file))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        let selected = model.leftovers.flatMap(\.items).filter { model.leftoverSelection.contains($0.id) }
        let selectable = model.leftovers.flatMap(\.items).filter(\.isSelectable)
        return HStack {
            SelectAllControl(
                selected: selected.count,
                total: selectable.count,
                selectAll: { model.leftoverSelection = Set(selectable.map(\.id)) },
                deselectAll: { model.leftoverSelection = [] }
            )
            Text("\(model.leftovers.count) 件のアプリの残骸・選択 \(selected.count) 項目（\(ByteCountFormatter.string(fromByteCount: selected.reduce(0) { $0 + $1.size }, countStyle: .file))）")
                .foregroundStyle(.secondary)
            Spacer()
            Button("選択した項目をゴミ箱へ…", role: .destructive) { model.confirmLeftovers() }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(selected.isEmpty || model.isWorking)
        }
        .padding(12)
    }
}
