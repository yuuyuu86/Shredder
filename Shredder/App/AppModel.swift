import AppKit
import Foundation
import FoundationModels
import Observation
import SwiftUI
import ShredderCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case home
    case organizer
    case storage
    case applications
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "ホーム"
        case .organizer: "ファイル整理"
        case .storage: "ストレージ"
        case .applications: "アプリケーション"
        case .history: "履歴"
        case .settings: "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .organizer: "folder.badge.gearshape"
        case .storage: "internaldrive"
        case .applications: "app.badge"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

extension OrganizationMode {
    var title: String {
        switch self {
        case .manual: "手動"
        case .semiAutomatic: "半自動"
        case .fullyAutomatic: "完全自動"
        }
    }

    var summary: String {
        switch self {
        case .manual: "すべての整理をあなたが承認します。"
        case .semiAutomatic: "確実で安全な移動だけを自動で行い、曖昧なものは確認待ちにします。"
        case .fullyAutomatic: "許可したフォルダ内で、移動とフォルダ作成を自動で行います。削除は行いません。"
        }
    }
}

/// アプリ全体の状態とサービスを保持する。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    static let mainWindowID = "main"
    enum SettingKey {
        static let mode = "organization.mode"
        static let learning = "learning.enabled"
        static let lastRoot = "organizer.lastRoot"
        static let lastOrganizerScan = "organizer.lastScanAt"
        static let lastCandidateCount = "organizer.lastCandidateCount"
        static let lastStorageAnalysis = "storage.lastAnalyzedAt"
        static let menuBar = "app.menuBar"
        static let onboarding = "onboarding.completed"
        static let appleIntelligence = "ai.appleIntelligence"
        static let appearance = "appearance.colorScheme"
        static let animation = "appearance.animation"
        static let completionEffect = "appearance.completionEffect"
        static let shredSound = "sound.shredder"
        static let dragSound = "sound.drag"
        static let completionSound = "sound.completion"
        static let oneClick = "organizer.oneClick"
    }

    var selection: SidebarItem? = .home
    var startupError: String?

    private(set) var store: ShredderStore?
    private(set) var engine: FileOperationEngine?

    var mode: OrganizationMode = .manual {
        didSet { persist(SettingKey.mode, mode.rawValue) }
    }
    var learningEnabled = true {
        didSet { persist(SettingKey.learning, learningEnabled ? "1" : "0") }
    }
    private(set) var jevConfigured = false
    var shredderSettings = ShredderSettings() {
        didSet {
            persist(SettingKey.animation, shredderSettings.animationEnabled ? "1" : "0")
            persist(SettingKey.completionEffect, shredderSettings.completionEffectEnabled ? "1" : "0")
        }
    }
    /// 外観（システムに合わせる / ライト / ダーク）。
    var appearance: AppAppearance = .system {
        didSet { persist(SettingKey.appearance, appearance.rawValue) }
    }
    /// メニューバー常駐。ウィンドウを閉じても監視を続ける（仕様 18）。
    var menuBarEnabled = true {
        didSet { persist(SettingKey.menuBar, menuBarEnabled ? "1" : "0") }
    }
    /// ログイン時起動（初期値 OFF、仕様 18.3）。状態はシステムの登録状況から読む。
    var launchAtLogin = LoginItem.isEnabled
    var loginItemMessage: String?
    /// SwiftUI のウィンドウを開くアクション（ビューから受け取る）。
    var openWindowAction: (() -> Void)?
    private var startTask: Task<Void, Never>?
    /// ワンクリック整理（初期値 ON、仕様 7.2）。
    var oneClickEnabled = true {
        didSet { persist(SettingKey.oneClick, oneClickEnabled ? "1" : "0") }
    }

    let keychain = KeychainStore()
    let organizer = OrganizerModel()
    let history = HistoryModel()
    let applications = ApplicationsModel()
    let storage = StorageModel()
    let trash = TrashCoordinator()
    let feedback = SoundFeedback()
    let automation = AutomationController()
    /// Apple Intelligence を使うか（利用可能なら ON、仕様 25）。
    var appleIntelligenceEnabled = true {
        didSet { persist(SettingKey.appleIntelligence, appleIntelligenceEnabled ? "1" : "0") }
    }

    enum IntroPresentation: Identifiable {
        case setup(withOpening: Bool)
        case openingOnly
        var id: String { switch self { case .setup(let opening): "setup\(opening)" case .openingOnly: "opening" } }
    }

    /// 初回起動アニメーションとオンボーディングの表示状態（仕様 15, 16）。
    var intro: IntroPresentation?
    private(set) var isReady = false

    /// ホーム画面用の最新ストレージ分析の要約。
    private(set) var lastStorageSummary: StorageSummary?
    private(set) var lastOrganizerScanAt: Date?
    private(set) var lastCandidateCount: Int?
    private(set) var lastStorageAnalysisAt: Date?

    var lastScanAt: Date? { [lastOrganizerScanAt, lastStorageAnalysisAt].compactMap { $0 }.max() }

    /// 複数の場所（ウィンドウ・メニューバー・Finder 連携）から呼ばれても1回だけ初期化する。
    func start() async {
        if let startTask { return await startTask.value }
        let task = Task { await performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        guard store == nil else { return }
        do {
            let store = try await ShredderStore.open(at: ShredderStore.defaultURL)
            self.store = store
            engine = FileOperationEngine(store: store, validator: SafetyValidator(allowedRoots: []))
            if let raw = try await store.setting(SettingKey.mode), let saved = OrganizationMode(rawValue: raw) {
                mode = saved
            }
            if let raw = try await store.setting(SettingKey.learning) {
                learningEnabled = raw == "1"
            }
            jevConfigured = keychain.read() != nil
            if let raw = try await store.setting(SettingKey.menuBar) { menuBarEnabled = raw == "1" }
            if let raw = try await store.setting(SettingKey.appleIntelligence) { appleIntelligenceEnabled = raw == "1" }
            if let raw = try await store.setting(SettingKey.appearance), let value = AppAppearance(rawValue: raw) { appearance = value }
            if let raw = try await store.setting(SettingKey.oneClick) { oneClickEnabled = raw == "1" }
            var shredder = ShredderSettings()
            if let raw = try await store.setting(SettingKey.animation) { shredder.animationEnabled = raw == "1" }
            if let raw = try await store.setting(SettingKey.completionEffect) { shredder.completionEffectEnabled = raw == "1" }
            shredderSettings = shredder
            if let raw = try await store.setting(SettingKey.shredSound) { feedback.shredderSoundEnabled = raw == "1" }
            if let raw = try await store.setting(SettingKey.dragSound) { feedback.dragReactionEnabled = raw == "1" }
            if let raw = try await store.setting(SettingKey.completionSound) { feedback.completionEnabled = raw == "1" }
            // 初回起動時のみ自動再生する。
            if try await store.setting(SettingKey.onboarding) != "1" {
                intro = .setup(withOpening: true)
            }
            organizer.app = self
            history.app = self
            applications.app = self
            storage.app = self
            trash.app = self
            storage.attach()
            organizer.attach()
            automation.app = self
            lastOrganizerScanAt = try await store.setting(SettingKey.lastOrganizerScan).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            lastStorageAnalysisAt = try await store.setting(SettingKey.lastStorageAnalysis).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            lastCandidateCount = try await store.setting(SettingKey.lastCandidateCount).flatMap(Int.init)
            await history.reload()
            if let path = try await store.setting(SettingKey.lastRoot), FileManager.default.fileExists(atPath: path) {
                organizer.root = URL(filePath: path, directoryHint: .isDirectory)
            }
            await automation.start()
            isReady = true
        } catch {
            startupError = "データベースを開けませんでした: \(error)"
        }
    }

    // MARK: - Jev

    func saveJevKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keychain.save(trimmed)
        jevConfigured = true
    }

    func deleteJevKey() {
        keychain.delete()
        jevConfigured = false
    }

    func testJevConnection() async -> String {
        guard let key = keychain.read() else { return JevError.notConfigured.description }
        do {
            let response = try await JevClient(apiKey: key).evaluate(JevRequest(
                state: .string("connection test"),
                questions: ["ok": .noul("Is this text a connection test?")]
            ))
            return "接続できました（モデル: \(response.model)）"
        } catch {
            return error.description
        }
    }

    // MARK: - Services

    /// 整理プランナーを作る。自動整理では書き込み完了をエンジン側で確認するため、
    /// 経過時間による判定を外し、省電力時は Apple Intelligence による内容解析を使わない。
    func makePlanner(root: URL, forAutomation: Bool = false, limitHeavyAnalysis: Bool = false) -> OrganizationPlanner? {
        guard let store else { return nil }
        let validator = SafetyValidator(allowedRoots: [root], minimumFileAge: forAutomation ? 0 : 10)
        let jev = keychain.read().map { JevClassifier(client: JevClient(apiKey: $0)) }
        let foundation: FoundationModelsClassifier? = (limitHeavyAnalysis || !appleIntelligenceEnabled) ? nil : FoundationModelsClassifier()
        let coordinator = ClassificationCoordinator(
            store: store,
            jev: jev,
            foundation: foundation,
            learningEnabled: learningEnabled
        )
        return OrganizationPlanner(
            coordinator: coordinator,
            validator: validator,
            recentActivityWindow: forAutomation ? 0 : 300
        )
    }

    func makeExecutor(root: URL, forAutomation: Bool = false) async -> OrganizationExecutor? {
        guard let store, let engine else { return nil }
        if forAutomation {
            return OrganizationExecutor(engine: engine, store: store, validator: SafetyValidator(allowedRoots: [root], minimumFileAge: 0))
        }
        await engine.updateValidator(SafetyValidator(allowedRoots: [root]))
        return OrganizationExecutor(engine: engine, store: store)
    }

    func completeOnboarding() {
        persist(SettingKey.onboarding, "1")
        intro = nil
        selection = .home
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == Self.mainWindowID && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?()
        }
        NSApp.activate()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginItemMessage = LoginItem.requiresApproval ? "システム設定の「ログイン項目」で Shredder を許可してください。" : nil
        } catch {
            loginItemMessage = "ログイン項目を変更できませんでした: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
    }

    func makeTrashService() -> TrashService? {
        engine.map { TrashService(engine: $0) }
    }

    /// .app がシュレッダーや Finder から渡されたときは完全アンインストール画面を開く。
    func showUninstaller(for url: URL) {
        selection = .applications
        NSApp.activate()
        Task { await applications.select(appAt: url) }
    }

    func showLeftovers() {
        selection = .applications
        applications.tab = .leftovers
        if !applications.leftoversScanned { applications.scanLeftovers() }
    }

    func recordOrganizerScan(candidates: Int) {
        lastOrganizerScanAt = Date()
        lastCandidateCount = candidates
        persist(SettingKey.lastOrganizerScan, String(Date().timeIntervalSince1970))
        persist(SettingKey.lastCandidateCount, String(candidates))
    }

    func recordStorageAnalysis(_ analysis: StorageAnalysis) {
        lastStorageAnalysisAt = Date()
        persist(SettingKey.lastStorageAnalysis, String(Date().timeIntervalSince1970))
        lastStorageSummary = StorageSummary(
            analyzedAt: Date(),
            totalSize: analysis.totalSize,
            largeFileSize: analysis.largeFiles.reduce(0) { $0 + $1.size },
            largeFileCount: analysis.largeFiles.count
        )
    }

    func makeUninstaller() -> AppUninstaller? {
        guard let store, let engine else { return nil }
        return AppUninstaller(store: store, engine: engine)
    }

    func rememberRoot(_ url: URL) {
        persist(SettingKey.lastRoot, url.path(percentEncoded: false))
    }

    func persist(_ key: String, _ value: String) {
        guard let store else { return }
        Task { try? await store.setSetting(key, value) }
    }
}

extension FoundationModelsClassifier {
    /// 設定画面に表示する Apple Intelligence の状態。
    @MainActor static var availabilityDescription: String {
        switch availability {
        case .available:
            "利用できます"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: "このMacは Apple Intelligence に対応していません"
            case .appleIntelligenceNotEnabled: "システム設定で Apple Intelligence がオフになっています"
            case .modelNotReady: "モデルを準備中です。しばらくしてから再度お試しください"
            @unknown default: "利用できません"
            }
        }
    }
}

struct StorageSummary {
    let analyzedAt: Date
    let totalSize: Int64
    let largeFileSize: Int64
    let largeFileCount: Int
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
