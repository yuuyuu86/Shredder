import AppKit
import FoundationModels
import ShredderCore
import SwiftUI

/// 設定画面（仕様 13.8）。AI・整理・監視・学習・安全性・外観・サウンド・バックグラウンドの8カテゴリ。
struct SettingsView: View {
    enum Category: String, CaseIterable, Identifiable {
        case ai, organization, monitoring, learning, safety, appearance, sound, background

        var id: String { rawValue }
        var title: String {
            switch self {
            case .ai: "AI"
            case .organization: "整理"
            case .monitoring: "監視"
            case .learning: "学習"
            case .safety: "安全性"
            case .appearance: "外観"
            case .sound: "サウンド"
            case .background: "バックグラウンド"
            }
        }
        var symbol: String {
            switch self {
            case .ai: "sparkles"
            case .organization: "folder.badge.gearshape"
            case .monitoring: "eye"
            case .learning: "brain"
            case .safety: "lock.shield"
            case .appearance: "paintpalette"
            case .sound: "speaker.wave.2"
            case .background: "moon.zzz"
            }
        }
    }

    @State private var category: Category = .ai

    var body: some View {
        HStack(spacing: 0) {
            List(Category.allCases, selection: $category) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Form {
                switch category {
                case .ai: AISettings()
                case .organization: OrganizationSettings()
                case .monitoring: MonitoringSettings()
                case .learning: LearningSettings()
                case .safety: SafetySettings()
                case .appearance: AppearanceSettings()
                case .sound: SoundSettings()
                case .background: BackgroundSettings()
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - AI

struct AISettings: View {
    @Environment(AppModel.self) private var app
    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var app = app
        Section {
            LabeledContent("状態") {
                Label(app.jevConfigured ? "API キー設定済み" : "未設定",
                      systemImage: app.jevConfigured ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(app.jevConfigured ? .green : .secondary)
            }
            SecureField("API キー", text: $apiKey, prompt: Text("TypeSafe コンソールで発行したキー"))
            HStack {
                Button("保存") {
                    app.saveJevKey(apiKey)
                    apiKey = ""
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("接続テスト") {
                    testing = true
                    Task {
                        testResult = await app.testJevConnection()
                        testing = false
                    }
                }
                .disabled(!app.jevConfigured || testing)
                if app.jevConfigured {
                    Button("キーを削除", role: .destructive) { app.deleteJevKey() }
                }
                if testing { ProgressView().controlSize(.small) }
            }
            if let testResult {
                Text(testResult).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Jev（一次分類）")
        } footer: {
            Text("Jev は TypeSafe のクラウド API です。ファイルの中身は送信せず、ファイル名・種類・サイズ・フォルダ名だけを送ります。キーはキーチェーンに保存されます。未設定や接続できない場合は、Apple Intelligence とローカルのルールで分類します。")
        }

        Section {
            LabeledContent("状態", value: FoundationModelsClassifier.availabilityDescription)
            Toggle("Apple Intelligence でファイルの内容を解析する", isOn: $app.appleIntelligenceEnabled)
                .disabled(!SystemLanguageModel.default.isAvailable)
        } header: {
            Text("Apple Foundation Models（二次解析）")
        } footer: {
            Text("Jev で判断できなかったファイルだけ、Mac 上でファイルの内容（PDF・テキスト・Word・画像内の文字）を必要な分だけ読み取って解析します。内容が外部に送信されることはありません。")
        }
    }
}

// MARK: - Organization

struct OrganizationSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var organizer = app.organizer
        Section {
            Picker("整理モード", selection: $app.mode) {
                ForEach(OrganizationMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(app.mode.summary).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("整理モード")
        }
        Section {
            Toggle("ワンクリック整理を使う", isOn: $app.oneClickEnabled)
            LabeledContent("整理するフォルダ") {
                HStack {
                    Text(app.organizer.root?.lastPathComponent ?? "未設定").foregroundStyle(.secondary)
                    Button("変更…") { app.organizer.chooseFolder() }
                }
            }
            Toggle("サブフォルダのファイルも整理する", isOn: $organizer.includeSubfolders)
        } header: {
            Text("整理の実行")
        } footer: {
            Text("整理では既存のフォルダを優先し、合うものがない場合だけ新しいフォルダを作ります。同名ファイルを上書きすることはありません。")
        }
        RulesSection()
    }
}

/// フォルダ別の整理ルール（仕様 8.1 の3）。
struct RulesSection: View {
    @Environment(AppModel.self) private var app
    @State private var rules: [OrganizationRule] = []
    @State private var editing: OrganizationRule?

    var body: some View {
        Section {
            if rules.isEmpty {
                Text("ルールはありません。ルールは AI の判断より優先されます。").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack {
                    Toggle(isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; save(r) })) {
                        VStack(alignment: .leading) {
                            Text(rule.condition.summary)
                            Text("\(URL(filePath: rule.folderPath).lastPathComponent) → \(URL(filePath: rule.destination).lastPathComponent)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("編集") { editing = rule }.buttonStyle(.borderless)
                    Button("削除", systemImage: "minus.circle") { delete(rule) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            Button("ルールを追加", systemImage: "plus") {
                let folder = app.organizer.root?.path(percentEncoded: false) ?? URL.downloadsDirectory.path(percentEncoded: false)
                editing = OrganizationRule(folderPath: folder, condition: RuleCondition(extensions: ["pdf"]), destination: folder)
            }
        } header: {
            Text("フォルダ別ルール")
        }
        .task { await reload() }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { save($0) }
        }
    }

    private func reload() async {
        rules = (try? await app.store?.rules()) ?? []
    }

    private func save(_ rule: OrganizationRule) {
        Task {
            try? await app.store?.saveRule(rule)
            await reload()
        }
    }

    private func delete(_ rule: OrganizationRule) {
        Task {
            try? await app.store?.deleteRule(id: rule.id)
            await reload()
        }
    }
}

struct RuleEditor: View {
    @State var rule: OrganizationRule
    let onSave: (OrganizationRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var extensions = ""
    @State private var nameContains = ""
    @State private var kind: FileKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("対象") {
                    folderRow("元のフォルダ", path: rule.folderPath) { rule.folderPath = $0 }
                    TextField("拡張子（カンマ区切り）", text: $extensions, prompt: Text("pdf, docx"))
                    TextField("ファイル名に含む文字", text: $nameContains, prompt: Text("請求書"))
                    Picker("ファイルの種類", selection: $kind) {
                        Text("指定しない").tag(FileKind?.none)
                        ForEach(FileKind.allCases, id: \.self) { Text($0.displayName).tag(FileKind?.some($0)) }
                    }
                }
                Section("整理先") {
                    folderRow("移動先フォルダ", path: rule.destination) { rule.destination = $0 }
                    Stepper("優先度: \(rule.priority)", value: $rule.priority, in: 0...100)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("指定した条件をすべて満たすファイルに適用します。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    rule.condition = condition
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(condition.extensions == nil && condition.nameContains == nil && condition.kind == nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
        .onAppear {
            extensions = rule.condition.extensions?.joined(separator: ", ") ?? ""
            nameContains = rule.condition.nameContains ?? ""
            kind = rule.condition.kind
        }
    }

    private var condition: RuleCondition {
        let exts = extensions.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        let name = nameContains.trimmingCharacters(in: .whitespaces)
        return RuleCondition(extensions: exts.isEmpty ? nil : exts, nameContains: name.isEmpty ? nil : name, kind: kind)
    }

    private func folderRow(_ title: String, path: String, set: @escaping (String) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(URL(filePath: path).lastPathComponent).foregroundStyle(.secondary).help(path)
                Button("選択…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(filePath: path)
                    if panel.runModal() == .OK, let url = panel.url { set(url.path(percentEncoded: false)) }
                }
            }
        }
    }
}

extension RuleCondition {
    var summary: String {
        var parts: [String] = []
        if let extensions { parts.append(extensions.map { ".\($0)" }.joined(separator: " ")) }
        if let nameContains { parts.append("名前に「\(nameContains)」") }
        if let kind { parts.append(kind.displayName) }
        return parts.isEmpty ? "条件なし" : parts.joined(separator: "・")
    }
}

// MARK: - Monitoring / Background

struct MonitoringSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Section {
            Toggle("メニューバーに常駐する", isOn: $app.menuBarEnabled)
            Toggle("ログイン時に起動", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            if let message = app.loginItemMessage {
                HStack {
                    Text(message).font(.callout).foregroundStyle(.orange)
                    Button("システム設定を開く") { LoginItem.openSystemSettings() }
                }
            }
        } header: {
            Text("起動と常駐")
        } footer: {
            Text("常駐中はウィンドウを閉じても監視を続けます。Shredder を終了すると監視も止まります。")
        }
        AutomationSettingsSection(automation: app.automation, part: .monitoring)
    }
}

struct BackgroundSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AutomationSettingsSection(automation: app.automation, part: .background)
    }
}

// MARK: - Learning

struct LearningSettings: View {
    @Environment(AppModel.self) private var app
    @State private var corrections = 0
    @State private var confirmClear = false

    var body: some View {
        @Bindable var app = app
        Section {
            Toggle("整理履歴とあなたの修正から学習する", isOn: $app.learningEnabled)
            LabeledContent("記録された修正", value: "\(corrections) 件")
            Button("学習データを消去…", role: .destructive) { confirmClear = true }
        } header: {
            Text("学習")
        } footer: {
            Text("AI モデル自体は再学習しません。整理履歴・あなたの修正・フォルダ別ルールを検索し、分類時の参考にします。学習データはこの Mac の中にだけ保存されます。")
        }
        .task { corrections = (try? await app.store?.correctionCount()) ?? 0 }
        .confirmationDialog("学習データを消去しますか？", isPresented: $confirmClear) {
            Button("消去", role: .destructive) {
                Task {
                    try? await app.store?.clearLearningData()
                    corrections = 0
                }
            }
        } message: {
            Text("あなたの修正履歴と解析キャッシュを消去します。整理ルールと操作履歴は残ります。")
        }
    }
}

// MARK: - Safety

struct SafetySettings: View {
    var body: some View {
        Section {
            LabeledContent("削除方式", value: "macOS のゴミ箱へ移動のみ")
            LabeledContent("ゴミ箱を空にする", value: "自動では行いません")
            LabeledContent("アプリ削除の確認", value: "必須")
            LabeledContent("AI による削除", value: "行いません")
            LabeledContent("同名ファイルの上書き", value: "行いません")
            LabeledContent("管理者権限が必要な操作", value: "実行しません")
        } header: {
            Text("安全性")
        } footer: {
            Text("これらは安全のため変更できません。ゴミ箱に残っている項目は、履歴画面の「元に戻す」で元の場所へ戻せます。")
        }
        Section("保護されている場所") {
            ForEach(ProtectedPaths.system + ProtectedPaths.userProtected(), id: \.self) { path in
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.callout.monospaced())
            }
        }
    }
}

// MARK: - Appearance / Sound

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Section("外観") {
            Picker("テーマ", selection: $app.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section {
            Toggle("3D アニメーション", isOn: $app.shredderSettings.animationEnabled)
            Toggle("完了演出（裁断パーティクル・LED）", isOn: $app.shredderSettings.completionEffectEnabled)
        } header: {
            Text("3D シュレッダー")
        } footer: {
            Text("システム設定の「視差効果を減らす」がオンの場合は、動きのある演出を自動的に控えます。")
        }
        Section("オープニングとセットアップ") {
            Button("オープニングを再生") { app.intro = .openingOnly }
            Button("セットアップをやり直す") { app.intro = .setup(withOpening: false) }
        }
    }
}

struct SoundSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            Toggle("シュレッダー動作音", isOn: sound(\.shredderSoundEnabled, key: AppModel.SettingKey.shredSound))
            Toggle("ドラッグ時のリアクション", isOn: sound(\.dragReactionEnabled, key: AppModel.SettingKey.dragSound))
            Toggle("完了音", isOn: sound(\.completionEnabled, key: AppModel.SettingKey.completionSound))
            Button("動作音を試す") { app.feedback.playShredding() }
        } header: {
            Text("サウンド")
        } footer: {
            Text("音量とミュートは macOS のサウンド設定に従います。")
        }
    }

    private func sound(_ keyPath: ReferenceWritableKeyPath<SoundFeedback, Bool>, key: String) -> Binding<Bool> {
        Binding(
            get: { app.feedback[keyPath: keyPath] },
            set: {
                app.feedback[keyPath: keyPath] = $0
                app.persist(key, $0 ? "1" : "0")
            }
        )
    }
}
