import AppKit
import Foundation

public struct UninstallPlan: Sendable {
    public let app: InstalledApp
    public let items: [RelatedItem]

    public var bundleSize: Int64 { items.first { $0.kind == .appBundle }?.size ?? 0 }
    public var relatedSize: Int64 { items.filter { $0.kind != .appBundle }.reduce(0) { $0 + $1.size } }
    public var defaultSelection: Set<RelatedItem.ID> { Set(items.filter(\.selectedByDefault).map(\.id)) }

    public func size(of selection: Set<RelatedItem.ID>) -> Int64 {
        items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
}

public enum UninstallError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 実行中のアプリは終了してもらう（仕様 9.6）。
    case appRunning(String)
    case nothingSelected

    public var description: String {
        switch self {
        case .appRunning(let name): "「\(name)」が実行中です。終了してから削除してください。"
        case .nothingSelected: "削除する項目が選択されていません。"
        }
    }
}

public struct UninstallReport: Sendable {
    public let sessionID: UUID
    public let result: TrashBatchResult
    /// 管理者権限が必要なため対象外にした項目（仕様 9.7）。
    public let skipped: [RelatedItem]

    public var status: OperationStatus { result.status }
    public var trashedSize: Int64 = 0
}

/// アプリ完全アンインストール（仕様 9）と残骸の削除（仕様 11）。
/// 削除はすべてゴミ箱への移動で、必ずユーザーの承認後に呼ぶこと。
public struct AppUninstaller: Sendable {
    public typealias RunningCheck = @Sendable (String) async -> Bool

    public static let runningCheck: RunningCheck = { bundleID in
        await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    let store: ShredderStore
    let engine: FileOperationEngine
    let locations: LibraryLocations
    let isRunning: RunningCheck

    public init(
        store: ShredderStore,
        engine: FileOperationEngine,
        locations: LibraryLocations = LibraryLocations(),
        isRunning: @escaping RunningCheck = AppUninstaller.runningCheck
    ) {
        self.store = store
        self.engine = engine
        self.locations = locations
        self.isRunning = isRunning
    }

    @concurrent
    public func plan(for app: InstalledApp, installedApps: [InstalledApp]) async -> UninstallPlan {
        let others = installedApps.filter { $0.id != app.id }
        let items = RelatedFileFinder(locations: locations, otherApps: others).find(for: app)
        return UninstallPlan(app: app, items: items)
    }

    public func uninstall(_ plan: UninstallPlan, selection: Set<RelatedItem.ID>) async throws(UninstallError) -> UninstallReport {
        if await isRunning(plan.app.bundleID) { throw .appRunning(plan.app.name) }
        let chosen = plan.items.filter { selection.contains($0.id) }
        let targets = chosen.filter(\.isSelectable)
        guard !targets.isEmpty else { throw .nothingSelected }

        // アプリ本体を先に移動し、失敗したら関連データは残す（アプリが使えなくなるのを防ぐ）。
        let ordered = targets.sorted { ($0.kind == .appBundle ? 0 : 1) < ($1.kind == .appBundle ? 0 : 1) }
        let sessionID = UUID()
        try? await store.insertUninstallSession(id: sessionID, bundleID: plan.app.bundleID, name: plan.app.name, status: "running")
        let result = await engine.moveToTrash(
            ordered.map(\.url),
            batchID: sessionID,
            validator: Self.validator(for: ordered),
            stopOnFirstFailure: ordered.first?.kind == .appBundle
        )
        return await finish(sessionID: sessionID, items: ordered, result: result, skipped: chosen.filter { !$0.isSelectable })
    }

    /// 削除済みアプリの残骸をゴミ箱へ移動する（仕様 11）。
    public func trashLeftovers(_ items: [RelatedItem], label: String) async throws(UninstallError) -> UninstallReport {
        let targets = items.filter(\.isSelectable)
        guard !targets.isEmpty else { throw .nothingSelected }
        let sessionID = UUID()
        try? await store.insertUninstallSession(id: sessionID, bundleID: label, name: "残骸: \(label)", status: "running")
        let result = await engine.moveToTrash(targets.map(\.url), batchID: sessionID, validator: Self.validator(for: targets))
        return await finish(sessionID: sessionID, items: targets, result: result, skipped: items.filter { !$0.isSelectable })
    }

    /// 選ばれた項目そのものだけを許可範囲にする。OS の中核領域は SafetyValidator が常に拒否する。
    static func validator(for items: [RelatedItem]) -> SafetyValidator {
        SafetyValidator(allowedRoots: items.map(\.url))
    }

    private func finish(sessionID: UUID, items: [RelatedItem], result: TrashBatchResult, skipped: [RelatedItem]) async -> UninstallReport {
        let byPath = Dictionary(uniqueKeysWithValues: result.items.map { ($0.url.path(percentEncoded: false), $0) })
        var trashedSize: Int64 = 0
        for item in items {
            let succeeded = byPath[item.id]?.succeeded == true
            if succeeded { trashedSize += item.size }
            try? await store.insertUninstallItem(
                sessionID: sessionID, path: item.id, type: item.kind.rawValue, size: item.size,
                status: succeeded ? "trashed" : "failed"
            )
        }
        for item in skipped {
            try? await store.insertUninstallItem(sessionID: sessionID, path: item.id, type: item.kind.rawValue, size: item.size, status: "skipped")
        }
        try? await store.updateUninstallSession(id: sessionID, status: result.status.rawValue)
        var report = UninstallReport(sessionID: sessionID, result: result, skipped: skipped)
        report.trashedSize = trashedSize
        return report
    }
}
