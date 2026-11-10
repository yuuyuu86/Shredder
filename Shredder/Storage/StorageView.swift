import AppKit
import Charts
import ShredderCore
import SwiftUI

/// ストレージ分析画面（仕様 12, 13.5）。
struct StorageView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: StorageModel

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.message {
                HStack {
                    Label(message, systemImage: "info.circle").font(.callout)
                    Spacer()
                    Button("閉じる", systemImage: "xmark") { model.message = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .padding(10)
                Divider()
            }
            Group {
                if model.analysis == nil && !model.isAnalyzing {
                    ContentUnavailableView {
                        Label("ストレージを分析", systemImage: "internaldrive")
                    } description: {
                        Text("フォルダの容量・大容量ファイル・重複ファイルを調べます。分析中にファイルを変更することはありません。")
                    } actions: {
                        Button("\(model.target.title)を分析") { model.analyze() }
                            .buttonStyle(.glassProminent)
                    }
                } else if model.isAnalyzing {
                    VStack {
                        ProgressCard(
                            symbol: "internaldrive.fill",
                            color: .teal,
                            title: "\(model.target.title)を分析しています",
                            detail: model.progressText,
                            fraction: nil,
                            steps: ["容量の集計", "重複の確認"],
                            currentStep: 0,
                            cancel: { model.cancel() }
                        )
                        .frame(maxWidth: 620)
                        Spacer()
                    }
                    .padding(24)
                } else {
                    switch model.tab {
                    case .overview: StorageOverview(model: model)
                    case .treemap: TreemapScreen(model: model)
                    case .largeFiles: LargeFilesView(model: model)
                    case .duplicates: DuplicatesView(model: model)
                    case .leftovers:
                        ContentUnavailableView {
                            Label("アプリ残骸", systemImage: "app.badge")
                        } description: {
                            Text("削除済みアプリの残骸は、アプリケーション画面で確認・削除できます。")
                        } actions: {
                            Button("アプリ残骸を表示") { app.showLeftovers() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("表示", selection: $model.tab) {
                    ForEach(StorageTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.analysis == nil)
            }
            ToolbarItemGroup {
                if model.isFindingDuplicates {
                    ProgressView().controlSize(.small)
                    Text(model.progressText).font(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    Button("ホームフォルダ") { model.target = .home; model.analyze() }
                    Button("Mac 全体（アクセス可能な範囲）") { model.target = .wholeMac; model.analyze() }
                    Button("フォルダを選択…") { model.chooseFolder() }
                } label: {
                    Label(model.target.title, systemImage: "scope")
                }
                Button("再分析", systemImage: "arrow.clockwise") { model.analyze() }
                    .disabled(model.isAnalyzing)
            }
        }
    }
}

// MARK: - Overview

struct StorageOverview: View {
    let model: StorageModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let volume = model.volume {
                    VolumeCard(volume: volume, analyzedSize: model.analysis?.totalSize, targetTitle: model.target.title)
                }
                if let analysis = model.analysis {
                    HStack(alignment: .top, spacing: 20) {
                        KindChart(sizes: analysis.sizeByKind)
                            .frame(maxWidth: .infinity)
                        TopFolders(root: analysis.root, model: model)
                            .frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 16) {
                        SummaryTile(title: "大容量ファイル", value: "\(model.largeFiles.count) 件", detail: ByteCountFormatter.string(fromByteCount: model.largeFiles.reduce(0) { $0 + $1.size }, countStyle: .file), symbol: "doc.zipper") { model.tab = .largeFiles }
                        SummaryTile(title: "重複ファイル", value: "\(model.visibleDuplicates.count) グループ", detail: "\(ByteCountFormatter.string(fromByteCount: model.duplicateReclaimable, countStyle: .file)) 削減可能", symbol: "square.on.square") { model.tab = .duplicates }
                        SummaryTile(title: "アクセスできない場所", value: "\(analysis.inaccessible.count) 件", detail: "権限がないフォルダ", symbol: "lock") {}
                    }
                }
            }
            .padding(20)
        }
    }
}

struct VolumeCard: View {
    let volume: VolumeInfo
    let analyzedSize: Int64?
    let targetTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(volume.name, systemImage: "internaldrive").font(.headline)
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: volume.available, countStyle: .file)) 空き / \(ByteCountFormatter.string(fromByteCount: volume.total, countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
            Gauge(value: Double(volume.used), in: 0...Double(max(volume.total, 1))) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(Double(volume.used) / Double(max(volume.total, 1)) > 0.9 ? .red : .accentColor)
            if let analyzedSize {
                // OS の値と Shredder の集計値は異なることを明示する（仕様 12.2）。
                Text("使用済み \(ByteCountFormatter.string(fromByteCount: volume.used, countStyle: .file))（macOS の値）。そのうち Shredder がアクセスできた\(targetTitle)のファイルは \(ByteCountFormatter.string(fromByteCount: analyzedSize, countStyle: .file)) です。システムデータやスナップショットなどは集計に含まれません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

struct KindChart: View {
    let sizes: [FileKind: Int64]

    private var data: [(kind: FileKind, size: Int64)] {
        sizes.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("ファイルの種類別").font(.headline)
            Chart(data, id: \.kind) { entry in
                SectorMark(angle: .value("容量", entry.size), innerRadius: .ratio(0.6), angularInset: 1)
                    .foregroundStyle(by: .value("種類", entry.kind.displayName))
            }
            .chartLegend(position: .trailing, alignment: .center)
            .frame(height: 220)
            .accessibilityLabel("ファイルの種類別の容量")
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

struct TopFolders: View {
    let root: StorageNode
    let model: StorageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("フォルダ別").font(.headline)
            ForEach(root.children.prefix(8)) { node in
                Button {
                    model.tab = .treemap
                    model.drillDown(node)
                } label: {
                    HStack {
                        Image(systemName: node.isAggregate ? "ellipsis.circle" : (node.isDirectory ? "folder" : "doc"))
                            .foregroundStyle(.secondary)
                        Text(node.name).lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                ProgressView(value: Double(node.size), total: Double(max(root.size, 1)))
                    .progressViewStyle(.linear)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

struct SummaryTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}

extension FileKind {
    var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .document: "書類"
        case .spreadsheet: "表計算"
        case .presentation: "プレゼンテーション"
        case .text: "テキスト"
        case .image: "画像"
        case .screenshot: "スクリーンショット"
        case .video: "動画"
        case .audio: "オーディオ"
        case .archive: "圧縮ファイル"
        case .diskImage: "ディスクイメージ"
        case .installer: "インストーラ"
        case .sourceCode: "コード"
        case .application: "アプリ"
        case .other: "その他"
        }
    }

    var color: Color {
        switch self {
        case .pdf: .red
        case .document, .text: .blue
        case .spreadsheet: .green
        case .presentation: .orange
        case .image, .screenshot: .pink
        case .video: .purple
        case .audio: .teal
        case .archive, .diskImage, .installer: .brown
        case .sourceCode: .indigo
        case .application: .cyan
        case .other: .gray
        }
    }
}

// MARK: - Large files

struct LargeFilesView: View {
    @Bindable var model: StorageModel

    var body: some View {
        VStack(spacing: 0) {
            Table(model.largeFiles, selection: $model.largeFileSelection) {
                TableColumn("ファイル") { file in
                    HStack(spacing: 8) {
                        FileThumbnail(url: file.url, size: 22)
                        Text(file.url.lastPathComponent).lineLimit(1)
                    }
                }
                TableColumn("場所") { file in
                    Text(file.url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("種類") { file in Text(file.kind.displayName) }
                    .width(90)
                TableColumn("更新日") { file in Text(file.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "-") }
                    .width(100)
                TableColumn("サイズ") { file in
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).monospacedDigit()
                }
                .width(90)
            }
            .contextMenu(forSelectionType: StorageFile.ID.self) { ids in
                Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(filePath: $0) }) }
                Button("シュレッダーへ送る…") { model.shred(ids.map { URL(filePath: $0) }) }
            }
            Divider()
            HStack {
                SelectAllControl(
                    selected: model.largeFileSelection.count,
                    total: model.largeFiles.count,
                    selectAll: { model.largeFileSelection = Set(model.largeFiles.map(\.id)) },
                    deselectAll: { model.largeFileSelection = [] }
                )
                Text("100 MB 以上 \(model.largeFiles.count) 件").foregroundStyle(.secondary)
                Spacer()
                Button("選択した項目をシュレッダーへ…", role: .destructive) {
                    model.shred(model.largeFileSelection.map { URL(filePath: $0) })
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(model.largeFileSelection.isEmpty)
            }
            .padding(12)
        }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @Bindable var model: StorageModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isFindingDuplicates && model.duplicates.isEmpty {
                ProgressView(model.progressText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleDuplicates.isEmpty {
                ContentUnavailableView("重複ファイルはありません", systemImage: "checkmark.circle", description: Text("内容が完全に一致する 1 MB 以上のファイルを探しました。"))
            } else {
                List {
                    ForEach(model.visibleDuplicates) { group in
                        Section {
                            ForEach(group.files) { file in
                                HStack {
                                    Toggle(isOn: Binding(
                                        get: { model.duplicateSelection.contains(file.id) },
                                        set: { on in if on { model.duplicateSelection.insert(file.id) } else { model.duplicateSelection.remove(file.id) } }
                                    )) { EmptyView() }
                                    .toggleStyle(.checkbox)
                                    FileThumbnail(url: file.url, size: 30)
                                    VStack(alignment: .leading) {
                                        Text(file.url.lastPathComponent)
                                        Text(file.url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    if file.id == group.files.first?.id {
                                        Text("最も古い").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(file.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                .contextMenu {
                                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(group.files.count) 個のコピー・各 \(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file))")
                                if group.distinctStorageCount < group.files.count {
                                    Label("APFS クローンを含む（容量を共有）", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(ByteCountFormatter.string(fromByteCount: group.reclaimableSize, countStyle: .file)) 削減可能").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                SelectAllControl(
                    selected: model.duplicateSelection.count,
                    total: model.visibleDuplicates.reduce(0) { $0 + $1.files.count - 1 },
                    selectAll: { model.duplicateSelection = Set(model.visibleDuplicates.flatMap { $0.files.dropFirst().map(\.id) }) },
                    deselectAll: { model.duplicateSelection = [] }
                )
                Text("合計 \(ByteCountFormatter.string(fromByteCount: model.duplicateReclaimable, countStyle: .file)) 削減可能（各グループの最も古いファイルは残します）")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("選択したコピーをシュレッダーへ…", role: .destructive) { model.shredSelectedDuplicates() }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .disabled(model.duplicateSelection.isEmpty)
            }
            .padding(12)
        }
    }
}
