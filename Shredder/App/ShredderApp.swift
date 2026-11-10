import AppKit
import SwiftUI

@main
struct ShredderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Shredder", id: AppModel.mainWindowID) {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { model.selection = .settings }
                    .keyboardShortcut(",")
            }
        }

        MenuBarExtra("Shredder", systemImage: model.automation.isPaused ? "doc.badge.ellipsis" : "doc.text.below.ecg", isInserted: $model.menuBarEnabled) {
            MenuBarContent()
                .environment(model)
                .task { await model.start() }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// ウィンドウを閉じたときの動作（仕様 18.4）とサービス（Finder 連携）を扱う。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = FinderServiceProvider.shared
        NSUpdateDynamicServices()
    }

    /// 常駐が有効ならウィンドウを閉じても終了せず、監視を続ける。
    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let model = AppModel.shared
        if model.menuBarEnabled {
            // Dock からアイコンを隠し、メニューバーだけに残す。
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 明示的に終了した場合は監視も止める。
        Task { @MainActor in
            await AppModel.shared.automation.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        FinderServiceProvider.shared.handle(urls: urls)
    }
}
