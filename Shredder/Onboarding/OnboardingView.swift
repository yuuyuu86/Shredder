import AppKit
import FoundationModels
import ShredderCore
import SwiftUI

/// 初回セットアップ（仕様 16）。Step 0 のオープニングから Step 7 の完了まで。
/// 初回スキャンではファイルの移動・削除を行わない。
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case opening, welcome, permissions, ai, mode, automation, initialScan, complete

        var title: String {
            switch self {
            case .opening: ""
            case .welcome: "ようこそ"
            case .permissions: "フォルダへのアクセス"
            case .ai: "AI の設定"
            case .mode: "整理モード"
            case .automation: "自動化"
            case .initialScan: "初回スキャン"
            case .complete: "準備完了"
            }
        }
    }

    @Environment(AppModel.self) private var app
    let startAtOpening: Bool
    let onComplete: () -> Void

    @State private var step: Step = .opening
    @State private var folders: [URL] = []
    @State private var apiKey = ""
    @State private var realtime = false
    @State private var schedule = false
    @State private var scanStarted = false

    var body: some View {
        Group {
            if step == .opening {
                OpeningView { step = .welcome }
            } else {
                VStack(spacing: 0) {
                    progress
                    Divider()
                    ScrollView {
                        content
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(32)
                            .frame(maxWidth: .infinity)
                    }
                    Divider()
                    navigation
                }
                .background(.background)
            }
        }
        .onAppear {
            if !startAtOpening { step = .welcome }
            if folders.isEmpty {
                folders = [URL.downloadsDirectory, URL.desktopDirectory].filter {
                    FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
                }
            }
        }
    }

    // MARK: - Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.dropFirst(), id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .accessibilityElement()
        .accessibilityLabel("ステップ \(step.rawValue) / \(Step.allCases.count - 1)")
    }

    private var navigation: some View {
        HStack {
            if step.rawValue > Step.welcome.rawValue && step != .complete {
                Button("戻る") { move(-1) }
            }
            Spacer()
            if step == .complete {
                Button("ホームへ") { finish() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .initialScan && !scanStarted ? "スキップ" : "続ける") { move(1) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func move(_ delta: Int) {
        if step == .ai, delta > 0, !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            app.saveJevKey(apiKey)
            apiKey = ""
        }
        if let next = Step(rawValue: step.rawValue + delta) {
            withAnimation(.easeInOut(duration: 0.2)) { step = next }
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(step.title).font(.largeTitle.weight(.semibold))
            switch step {
            case .opening: EmptyView()
            case .welcome: welcome
            case .permissions: permissions
            case .ai: aiSetup
            case .mode: modeSelection
            case .automation: automation
            case .initialScan: initialScan
            case .complete: complete
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shredder は、AI がファイルの内容と既存のフォルダ構成を理解して整理を提案し、不要なファイルやアプリを安全に片付けるアプリです。")
                .font(.title3)
            FeatureRow(symbol: "sparkles", title: "AI ファイル整理", text: "既存のフォルダを活かして整理先を提案します。")
            FeatureRow(symbol: "app.badge", title: "アプリ完全アンインストール", text: "アプリ本体と専用の関連ファイルをまとめて削除します。")
            FeatureRow(symbol: "internaldrive", title: "ストレージ分析", text: "大容量ファイルや重複ファイルを見つけます。")
            FeatureRow(symbol: "lock.shield", title: "安全第一", text: "削除はすべて macOS のゴミ箱へ。AI が勝手に削除することはありません。")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("整理するフォルダを選んでください。Shredder は許可したフォルダの中だけを変更します。")
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Label(folder.lastPathComponent, systemImage: "folder")
                    Text(folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("外す", systemImage: "minus.circle") { folders.removeAll { $0 == folder } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
            }
            Button("フォルダを追加…", systemImage: "plus") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK {
                    folders += panel.urls.filter { !folders.contains($0) }
                }
            }
            Divider()
            Text("ストレージ分析やアプリ削除で ~/Library などを調べるには、フルディスクアクセスの許可が必要な場合があります。許可しなくても、アクセスできる範囲で動作します。")
                .font(.callout).foregroundStyle(.secondary)
            Button("フルディスクアクセスの設定を開く") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var aiSetup: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Apple Intelligence: \(FoundationModelsClassifier.availabilityDescription)", systemImage: "apple.intelligence")
                    Toggle("Apple Intelligence でファイルの内容を解析する", isOn: $app.appleIntelligenceEnabled)
                        .disabled(!SystemLanguageModel.default.isAvailable)
                    Text("Mac 上で処理され、ファイルの内容が外部に送信されることはありません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(app.jevConfigured ? "Jev: API キー設定済み" : "Jev（任意）", systemImage: "bolt")
                    SecureField("TypeSafe の API キー", text: $apiKey)
                    Text("Jev は高速な一次分類に使うクラウド API です。ファイルの中身は送らず、ファイル名・種類・サイズ・フォルダ名だけを送ります。あとから設定画面でも変更できます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var modeSelection: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(OrganizationMode.allCases, id: \.self) { mode in
                Button {
                    app.mode = mode
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: app.mode == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(app.mode == mode ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title + (mode == .manual ? "（おすすめ）" : "")).font(.headline)
                            Text(mode.summary).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassEffect(app.mode == mode ? .regular.tint(.accentColor.opacity(0.25)) : .regular, in: .rect(cornerRadius: 12))
            }
        }
    }

    private var automation: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 14) {
            Toggle("選んだフォルダを監視し、新しいファイルを自動で整理する", isOn: $realtime)
            Toggle("毎日 9:00 にスケジュール整理する", isOn: $schedule)
            Toggle("メニューバーに常駐する", isOn: $app.menuBarEnabled)
            Toggle("ログイン時に起動", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            Text("自動整理は選んだ整理モードに従います。手動モードでは確認待ちにするだけで、ファイルは移動しません。いずれも設定画面からいつでも変更できます。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var initialScan: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("選んだフォルダとホームフォルダを調べ、整理候補と容量を確認します。この段階ではファイルの移動や削除は一切行いません。")
            if !scanStarted {
                Button("スキャンを開始") { startInitialScan() }
                    .buttonStyle(.glassProminent)
                    .disabled(folders.isEmpty)
            } else {
                ScanStatusRow(title: "整理候補", working: app.organizer.isWorking, detail: app.organizer.isWorking ? app.organizer.progressText : "\(app.organizer.candidateCount) 件の整理候補")
                ScanStatusRow(title: "ストレージ", working: app.storage.isAnalyzing || app.storage.isFindingDuplicates, detail: storageDetail)
                Text("スキャンは裏で続けられます。「続ける」で次へ進めます。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var storageDetail: String {
        if app.storage.isAnalyzing || app.storage.isFindingDuplicates { return app.storage.progressText }
        guard let analysis = app.storage.analysis else { return "-" }
        return "\(ByteCountFormatter.string(fromByteCount: analysis.totalSize, countStyle: .file))・重複 \(ByteCountFormatter.string(fromByteCount: app.storage.duplicateReclaimable, countStyle: .file)) 削減可能"
    }

    private var complete: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("セットアップが完了しました。").font(.title3)
            Label("整理モード: \(app.mode.title)", systemImage: "folder.badge.gearshape")
            Label("整理するフォルダ: \(folders.map(\.lastPathComponent).joined(separator: "、"))", systemImage: "folder")
            Label("自動整理: \(realtime ? "リアルタイム" : "オフ")\(schedule ? "・毎日 9:00" : "")", systemImage: "clock")
            Text("ファイルやアプリは、ホーム画面のシュレッダーへドラッグするか、Finder の右クリック >「サービス」>「Shredderで削除」から削除できます。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startInitialScan() {
        scanStarted = true
        if let first = folders.first {
            app.organizer.root = first
            app.rememberRoot(first)
            // 計画を作るだけで実行しない。
            app.organizer.scanAndPlan()
        }
        app.storage.target = .home
        app.storage.analyze()
    }

    private func finish() {
        let folders = folders
        let realtime = realtime
        let schedule = schedule
        Task {
            for folder in folders {
                await app.automation.addWatchFolder(folder, mode: app.mode)
            }
            if app.organizer.root == nil, let first = folders.first {
                app.organizer.root = first
                app.rememberRoot(first)
            }
            app.automation.realtimeEnabled = realtime
            if schedule {
                app.automation.addSchedule()
                app.automation.schedulesEnabled = true
            }
            onComplete()
        }
    }
}

struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}

struct ScanStatusRow: View {
    let title: String
    let working: Bool
    let detail: String

    var body: some View {
        HStack {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }
}
