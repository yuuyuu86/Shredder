import AppKit
import ShredderCore
import SwiftUI

/// アプリ削除画面（仕様 9.5, 13.6）。
struct ApplicationsView: View {
    @Bindable var model: ApplicationsModel

    var body: some View {
        Group {
            switch model.tab {
            case .installed: installed
            case .leftovers: LeftoversView(model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("表示", selection: $model.tab) {
                    ForEach(ApplicationsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .sheet(item: $model.confirmation) { confirmation in
            TrashConfirmationView(confirmation: confirmation)
        }
        .sheet(item: $model.outcome) { outcome in
            UninstallOutcomeView(outcome: outcome, model: model)
        }
        .alert("処理できませんでした", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.loadApps() }
    }

    private var installed: some View {
        HSplitView {
            appList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            Group {
                if let app = model.selectedApp {
                    AppDetailView(app: app, model: model)
                } else {
                    ContentUnavailableView("アプリを選択", systemImage: "app.dashed", description: Text("アプリ本体と関連ファイルをまとめてゴミ箱へ移動できます。"))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var appList: some View {
        List(model.filteredApps, selection: Binding(get: { model.selectedAppID }, set: { model.select($0) })) { app in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).lineLimit(1)
                    Text(model.bundleSizes[app.id].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "計算中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(app.id)
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "アプリを検索")
        .overlay {
            if model.isLoadingApps { ProgressView() }
        }
    }
}

struct AppDetailView: View {
    let app: InstalledApp
    @Bindable var model: ApplicationsModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            if model.isLoadingPlan {
                ProgressView("関連ファイルを探しています…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = model.plan {
                RelatedItemList(items: plan.items, selection: $model.planSelection)
                Divider()
                footer(plan)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title2.weight(.semibold))
                Text(app.bundleID).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 16) {
                    if let version = app.version { Text("バージョン \(version)") }
                    if let plan = model.plan {
                        Text("本体 \(ByteCountFormatter.string(fromByteCount: plan.bundleSize, countStyle: .file))")
                        Text("関連データ \(ByteCountFormatter.string(fromByteCount: plan.relatedSize, countStyle: .file))")
                    }
                    Text("最終使用 " + (app.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? "不明"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if app.isAppStore {
                    Label("App Store からインストール", systemImage: "bag").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func footer(_ plan: UninstallPlan) -> some View {
        HStack {
            if model.isRunning {
                Label("このアプリは実行中です", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("終了を依頼") { model.requestQuit() }
            } else {
                SelectAllControl(
                    selected: model.planSelection.count,
                    total: plan.items.filter(\.isSelectable).count,
                    selectAll: { model.planSelection = Set(plan.items.filter(\.isSelectable).map(\.id)) },
                    deselectAll: { model.planSelection = [] }
                )
                Text(ByteCountFormatter.string(fromByteCount: plan.size(of: model.planSelection), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Button(role: .destructive) { model.confirmUninstall() } label: {
                Label("完全に削除…", systemImage: "doc.text.below.ecg")
            }
                .buttonStyle(.glassProminent)
                .tint(.pink)
                .disabled(model.isRunning || model.isWorking || model.planSelection.isEmpty)
        }
        .padding(12)
    }
}

/// 関連ファイルの一覧（種類ごとにまとめ、チェックで選択）。
struct RelatedItemList: View {
    let items: [RelatedItem]
    @Binding var selection: Set<RelatedItem.ID>

    var body: some View {
        List {
            ForEach(RelatedItemKind.allCases, id: \.self) { kind in
                let group = items.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section(kind.title) {
                        ForEach(group) { item in
                            RelatedItemRow(item: item, isOn: Binding(
                                get: { selection.contains(item.id) },
                                set: { on in if on { selection.insert(item.id) } else { selection.remove(item.id) } }
                            ))
                        }
                    }
                }
            }
        }
    }
}

struct RelatedItemRow: View {
    let item: RelatedItem
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(!item.isSelectable)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1)
                Text(item.url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.match.title)
                    switch item.safety {
                    case .safe: EmptyView()
                    case .shared(let reason): Label(reason, systemImage: "person.2").foregroundStyle(.orange)
                    case .requiresAdmin: Label("管理者権限が必要", systemImage: "lock").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }
}

/// 結果表示（3D シュレッダー演出は後のマイルストーンで差し替える）。
struct UninstallOutcomeView: View {
    let outcome: UninstallOutcome
    let model: ApplicationsModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var phase: ShredderPhase = .deleting

    var body: some View {
        VStack(spacing: 14) {
            if outcome.report.status == .success {
                // 成功時は 3D シュレッダーの裁断演出を再生する（仕様 9.4）。
                ShredderStage(phase: phase, settings: app.shredderSettings)
                    .frame(width: 260, height: 190)
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            phase = .success
                            app.feedback.playShredding()
                            try? await Task.sleep(for: .milliseconds(900))
                            app.feedback.playCompletion()
                        }
                    }
            } else {
                // 失敗・一部失敗では成功演出を再生しない。
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(color)
            }
            Text(headline).font(.title3.weight(.semibold))
            Text("\(ByteCountFormatter.string(fromByteCount: outcome.report.trashedSize, countStyle: .file)) をゴミ箱へ移動しました。")
                .foregroundStyle(.secondary)
            if !outcome.report.result.failures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("移動できなかった項目").font(.headline)
                    ForEach(outcome.report.result.failures, id: \.url) { failure in
                        VStack(alignment: .leading) {
                            Text(failure.url.lastPathComponent)
                            Text(failure.error ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !outcome.report.skipped.isEmpty {
                Text("管理者権限が必要な \(outcome.report.skipped.count) 項目は削除していません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if outcome.report.result.items.contains(where: \.succeeded) {
                    Button("元に戻す") {
                        dismiss()
                        model.undo(outcome)
                    }
                }
                Spacer()
                Button("完了") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var headline: String {
        switch outcome.report.status {
        case .success: "「\(outcome.title)」を削除しました"
        case .partialSuccess: "一部の項目を削除できませんでした"
        case .failed: "削除できませんでした"
        case .cancelled: "キャンセルしました"
        }
    }

    private var icon: String {
        outcome.report.status == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var color: Color {
        outcome.report.status == .success ? .green : .orange
    }
}
