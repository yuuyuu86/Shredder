import AppKit
import ShredderCore
import SwiftUI

/// ファイル整理画面（仕様 13.4）: 左=対象とフィルター、中央=ファイル一覧、右=詳細。
struct OrganizerView: View {
    @Environment(AppModel.self) private var app
    @Bindable var organizer: OrganizerModel
    @State private var showInspector = true

    var body: some View {
        HStack(spacing: 0) {
            sidePanel
                .frame(width: 230)
            Divider()
            content
        }
        .animation(.smooth, value: organizer.isWorking)
        .inspector(isPresented: $showInspector) {
            Group {
                if let item = organizer.selectedItem {
                    PlanItemInspector(item: item, organizer: organizer)
                } else {
                    ContentUnavailableView("ファイルを選択", systemImage: "doc.text.magnifyingglass", description: Text("AI の判断理由や整理先を確認できます。"))
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300)
        }
        .toolbar {
            ToolbarItemGroup {
                if organizer.isWorking {
                    ProgressView().controlSize(.small)
                    Text(organizer.progressText).foregroundStyle(.secondary)
                    Button("キャンセル", systemImage: "xmark.circle") { organizer.cancel() }
                } else {
                    Button("スキャン", systemImage: "sparkle.magnifyingglass") { organizer.scanAndPlan() }
                        .disabled(organizer.root == nil)
                }
                Button("詳細", systemImage: "sidebar.right") { showInspector.toggle() }
            }
        }
    }

    // MARK: - Left

    private var sidePanel: some View {
        @Bindable var app = app
        return Form {
            Section("整理対象") {
                if let root = organizer.root {
                    Label(root.lastPathComponent, systemImage: "folder")
                        .help(root.path(percentEncoded: false))
                }
                Button(organizer.root == nil ? "フォルダを選択…" : "変更…") { organizer.chooseFolder() }
                Toggle("サブフォルダも含める", isOn: $organizer.includeSubfolders)
            }
            if !app.automation.reviewItems.isEmpty {
                Section("自動整理の確認待ち") {
                    Label("\(app.automation.reviewItems.count) 件", systemImage: "questionmark.circle")
                    Button("確認する") { app.automation.reviewPending() }
                }
            }
            Section("整理モード") {
                Picker("モード", selection: $app.mode) {
                    ForEach(OrganizationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(app.mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("フィルター") {
                Picker("表示", selection: $organizer.filter) {
                    ForEach(PlanFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Center

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if organizer.isWorking {
                ProgressCard(
                    symbol: ["magnifyingglass", "sparkles", "folder.fill.badge.plus"][min(organizer.stage, 2)],
                    color: [.blue, .indigo, .purple][min(organizer.stage, 2)],
                    title: organizer.stageTitle,
                    detail: organizer.currentName,
                    fraction: organizer.fraction,
                    steps: ["スキャン", "AI 分類", "整理"],
                    currentStep: organizer.stage,
                    cancel: { organizer.cancel() }
                )
                .padding(16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if organizer.root == nil {
                ContentUnavailableView {
                    Label("整理するフォルダを選びましょう", systemImage: "folder.badge.plus")
                } description: {
                    Text("ダウンロードやデスクトップなど、散らかったフォルダを選ぶと AI が整理先を提案します。")
                } actions: {
                    Button("フォルダを選択…") { organizer.chooseFolder() }
                        .buttonStyle(.glassProminent)
                }
            } else if organizer.items.isEmpty && organizer.isWorking {
                Spacer()
            } else if organizer.items.isEmpty && !organizer.isWorking {
                ContentUnavailableView {
                    Label(organizer.justOrganized > 0 ? "\(organizer.justOrganized) 件を整理しました" : "整理候補はありません", systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                        .symbolEffect(.bounce, value: organizer.justOrganized)
                } description: {
                    Text("「スキャン」を押すと、このフォルダのファイルを分類します。ファイルの移動は承認するまで行いません。")
                } actions: {
                    Button("スキャン") { organizer.scanAndPlan() }
                        .buttonStyle(.glassProminent)
                }
            } else {
                planTable
            }
            if let message = organizer.message {
                Divider()
                HStack {
                    Image(systemName: "info.circle.fill").foregroundStyle(.indigo)
                    Text(message).font(.callout)
                    Spacer()
                    if organizer.lastBatchID != nil {
                        Button("元に戻す") { organizer.undoLastBatch() }
                    }
                    Button("閉じる", systemImage: "xmark") { organizer.message = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(10)
            }
            if !organizer.items.isEmpty {
                Divider()
                actionBar
            }
        }
    }

    private var planTable: some View {
        Table(organizer.visibleItems, selection: $organizer.selection) {
            TableColumn("ファイル") { item in
                HStack(spacing: 8) {
                    FileThumbnail(url: item.file.url, size: 22)
                    Text(item.file.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("カテゴリ") { item in
                Text(item.classification.category).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("整理先") { item in
                Text(destinationText(item)).lineLimit(1)
            }
            .width(min: 120, ideal: 200)
            TableColumn("信頼性") { item in
                ReliabilityBadge(assessment: item.assessment)
            }
            .width(70)
            TableColumn("状態") { item in
                StatusLabel(item: item, review: organizer.review[item.id] ?? .undecided)
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: PlanItem.ID.self) { ids in
            Button("承認") { organizer.setReview(.approved, for: ids) }
            Button("保留") { organizer.setReview(.held, for: ids) }
            Button("除外") { organizer.setReview(.excluded, for: ids) }
            Divider()
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting(organizer.items.filter { ids.contains($0.id) }.map(\.file.url))
            }
            Button("シュレッダーへ送る…") {
                app.trash.request(organizer.items.filter { ids.contains($0.id) }.map(\.file.url), source: "ファイル整理")
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            SelectAllControl(
                selected: organizer.selection.count,
                total: organizer.visibleItems.count,
                selectAll: { organizer.selectAllVisible() },
                deselectAll: { organizer.deselectAll() }
            )
            if !organizer.selection.isEmpty {
                Menu("選択した \(organizer.selection.count) 件") {
                    Button("承認") { organizer.setReview(.approved, for: organizer.selection) }
                    Button("保留") { organizer.setReview(.held, for: organizer.selection) }
                    Button("除外") { organizer.setReview(.excluded, for: organizer.selection) }
                    Divider()
                    Button("シュレッダーへ送る…") {
                        app.trash.request(organizer.items.filter { organizer.selection.contains($0.id) }.map(\.file.url), source: "ファイル整理")
                    }
                }
                .fixedSize()
            }
            Spacer()
            Text("承認 \(organizer.approvedCount) 件")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Button("提案をすべて承認") { organizer.approveAllSuggestions() }
                .buttonStyle(.glass)
            if app.mode != .manual {
                Button("自動実行可の項目も含めて整理 (\(organizer.automaticCount + organizer.approvedCount))") {
                    organizer.execute(includeAutomatic: true)
                }
                .disabled(organizer.isWorking)
            }
            Button {
                organizer.execute(includeAutomatic: false)
            } label: {
                Label("承認した項目を整理", systemImage: "wand.and.stars")
            }
                .buttonStyle(.glassProminent)
                .tint(.indigo)
                .disabled(organizer.approvedCount == 0 || organizer.isWorking)
        }
        .padding(12)
        .animation(.snappy, value: organizer.approvedCount)
    }

    private func destinationText(_ item: PlanItem) -> String {
        switch item.action {
        case .keep: "現在の場所のまま"
        case .requestReview: "要確認"
        case .move: item.destinationFolder.map { JevPathFormatter.relative($0, root: organizer.root) } ?? "-"
        case .createFolder: (item.destinationFolder.map { JevPathFormatter.relative($0, root: organizer.root) } ?? "-") + "（新規）"
        }
    }
}

enum JevPathFormatter {
    static func relative(_ url: URL, root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let path = url.path(percentEncoded: false)
        let rootPath = root.path(percentEncoded: false)
        guard path.hasPrefix(rootPath) else { return path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        let relative = path.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? root.lastPathComponent : relative
    }
}

struct ReliabilityBadge: View {
    let assessment: ReliabilityAssessment

    var body: some View {
        let (text, color): (String, Color) = switch assessment.level {
        case .high: ("高", .green)
        case .medium: ("中", .orange)
        case .low: ("低", .secondary)
        }
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .help(String(format: "スコア %.0f%%", assessment.score * 100))
    }
}

struct StatusLabel: View {
    let item: PlanItem
    let review: ReviewState

    var body: some View {
        switch review {
        case .approved: Label("承認", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .held: Label("保留", systemImage: "pause.circle").foregroundStyle(.orange)
        case .excluded: Label("除外", systemImage: "minus.circle").foregroundStyle(.secondary)
        case .undecided:
            switch item.decision {
            case .automatic: Label("自動実行可", systemImage: "bolt.circle").foregroundStyle(.blue)
            case .needsApproval: Label("確認待ち", systemImage: "questionmark.circle").foregroundStyle(.orange)
            case .blocked: Label("対象外", systemImage: "nosign").foregroundStyle(.secondary)
            case .nothingToDo: Label("変更なし", systemImage: "equal.circle").foregroundStyle(.secondary)
            }
        }
    }
}
