import AppKit
import ShredderCore
import SwiftUI

/// メニューバーのメニュー（仕様 18.2）。
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Shredder を開く") { open() }

        Divider()

        Text(app.automation.statusText)
        if app.automation.pendingCount > 0 {
            Text("処理待ち \(app.automation.pendingCount) 件")
        }
        if app.automation.isPaused {
            Button("自動整理を再開") { app.automation.setPaused(false) }
        } else {
            Button("自動整理を一時停止") { app.automation.setPaused(true) }
        }

        Divider()

        Button("監視フォルダを今すぐ整理") { app.automation.organizeWatchFoldersNow() }
            .disabled(app.automation.watchFolders.isEmpty)
        Button("ワンクリック整理") {
            open(.organizer)
            app.organizer.oneClickOrganize()
        }
        .disabled(!app.oneClickEnabled)
        Button("ストレージをスキャン") {
            open(.storage)
            app.storage.analyze()
        }

        Menu("最近の整理結果") {
            let recent = app.automation.organizedRecently.prefix(8)
            if recent.isEmpty {
                Text("まだありません")
            }
            ForEach(Array(recent)) { entry in
                if case .organized(_, let destination) = entry.event {
                    Button(entry.event.summary.text) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: destination)])
                    }
                }
            }
            Divider()
            Button("履歴を表示") { open(.history) }
        }
        if !app.automation.reviewItems.isEmpty {
            Button("確認待ち \(app.automation.reviewItems.count) 件を確認…") {
                open(.organizer)
                app.automation.reviewPending()
            }
        }

        Divider()

        Button("設定…") { open(.settings) }
            .keyboardShortcut(",")
        Button("Shredder を終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ item: SidebarItem? = nil) {
        if let item { app.selection = item }
        NSApp.setActivationPolicy(.regular)
        openWindow(id: AppModel.mainWindowID)
        NSApp.activate()
    }
}
