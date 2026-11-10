import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        @Bindable var trash = model.trash
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        HStack(spacing: 10) {
                            IconBadge(symbol: item.symbol, color: item.color, size: 24)
                            Text(item.title)
                            Spacer()
                            if let badge = badge(for: item) {
                                Text(badge)
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(item.color.opacity(0.2), in: .capsule)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(item)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.below.ecg").foregroundStyle(Theme.accent)
                        Text("Shredder").font(.headline).foregroundStyle(.primary)
                    }
                    .padding(.bottom, 6)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                SidebarShredderStatus()
                    .padding(10)
            }
        } detail: {
            Group {
                if let error = model.startupError {
                    ContentUnavailableView("起動できませんでした", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    switch model.selection ?? .home {
                    case .home:
                        HomeView()
                    case .organizer:
                        OrganizerView(organizer: model.organizer)
                    case .storage:
                        StorageView(model: model.storage)
                    case .applications:
                        ApplicationsView(model: model.applications)
                    case .history:
                        HistoryView(history: model.history)
                    case .settings:
                        SettingsView()
                    }
                }
            }
            .navigationTitle(model.selection?.title ?? "Shredder")
            .safeAreaInset(edge: .top, spacing: 0) {
                if let item = model.selection, item != .home {
                    ScreenHeader(symbol: item.symbol, color: item.color, title: item.title, subtitle: item.subtitle)
                    Divider()
                }
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear {
            model.openWindowAction = { openWindow(id: AppModel.mainWindowID) }
        }
        .overlay(alignment: .bottom) {
            TrashResultToast()
                .padding(20)
        }
        .overlay {
            if let intro = model.intro {
                Group {
                    switch intro {
                    case .setup(let withOpening):
                        OnboardingView(startAtOpening: withOpening) { model.completeOnboarding() }
                    case .openingOnly:
                        OpeningView { model.intro = nil }
                    }
                }
                .transition(.opacity)
            }
        }
        .sheet(item: $trash.confirmation, onDismiss: {
            if trash.phase == .confirming { trash.phase = .idle }
        }) { confirmation in
            TrashConfirmationView(confirmation: confirmation)
        }
    }
}

struct PlaceholderView: View {
    let item: SidebarItem
    let note: String

    var body: some View {
        ContentUnavailableView(item.title, systemImage: item.symbol, description: Text(note))
    }
}

extension RootView {
    func badge(for item: SidebarItem) -> String? {
        switch item {
        case .organizer:
            let count = model.organizer.candidateCount + model.automation.reviewItems.count
            return count > 0 ? "\(count)" : nil
        default:
            return nil
        }
    }
}

/// サイドバー下部: シュレッダーへのドロップ先と監視状態。
struct SidebarShredderStatus: View {
    @Environment(AppModel.self) private var app
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: targeted ? "doc.badge.arrow.up.fill" : "arrow.down.doc")
                    .font(.title3)
                    .foregroundStyle(targeted ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary))
                    .symbolEffect(.bounce, value: targeted)
                Text(targeted ? "離してシュレッダーへ" : "ここへドロップで削除")
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(targeted ? Color.pink : .secondary.opacity(0.5)))
            .dropDestination(for: URL.self) { urls, _ in
                app.trash.request(urls.filter(\.isFileURL))
                return true
            } isTargeted: { targeted = $0 }
            HStack(spacing: 6) {
                Circle().fill(app.automation.isWatching && !app.automation.isPaused ? Color.green : .secondary).frame(width: 7, height: 7)
                Text(app.automation.statusText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .animation(.snappy, value: targeted)
    }
}

/// ホーム以外の画面からシュレッダーへ送ったときの結果表示。
struct TrashResultToast: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.selection != .home, let content {
                HStack(spacing: 12) {
                    Image(systemName: content.symbol).foregroundStyle(content.color)
                    Text(content.text).lineLimit(2)
                    if app.trash.phase == .success {
                        Button("元に戻す") { app.trash.undoLast() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.25), value: app.trash.phase)
    }

    private var content: (symbol: String, text: String, color: Color)? {
        switch app.trash.phase {
        case .deleting: ("trash", "ゴミ箱へ移動しています…", .secondary)
        case .success: ("checkmark.circle.fill", "\(app.trash.lastTrashedNames.count) 項目をゴミ箱へ移動しました", .green)
        case .error(let message): ("exclamationmark.triangle.fill", message, .orange)
        default: nil
        }
    }
}
