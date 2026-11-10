import AppKit
import ShredderCore
import SwiftUI

/// ホーム画面（仕様 13.3）。
struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                stats
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        if let volume = app.storage.volume {
                            StorageRing(volume: volume, analyzedSize: app.lastStorageSummary?.totalSize)
                        }
                        modeCard
                    }
                    recentOperations
                }
            }
            .padding(24)
        }
        .background(alignment: .top) {
            // 背景にやわらかい色のにじみを置く。
            ZStack {
                Circle().fill(Color.indigo.opacity(0.18)).frame(width: 520).blur(radius: 120).offset(x: -260, y: -160)
                Circle().fill(Color.pink.opacity(0.14)).frame(width: 420).blur(radius: 120).offset(x: 320, y: -60)
            }
            .allowsHitTesting(false)
        }
        .onAppear { app.storage.volume = VolumeInfo.current() }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Text(greeting)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("散らかったMacを、\nもっとスマートに。")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Text(app.lastScanAt.map { "最終スキャン \($0.formatted(.relative(presentation: .named)))" } ?? "まだスキャンしていません。まずはワンクリック整理から始めましょう。")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        app.selection = .organizer
                        app.organizer.oneClickOrganize()
                    } label: {
                        Label("ワンクリック整理", systemImage: "wand.and.stars")
                            .font(.headline)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.indigo)
                    .controlSize(.large)
                    .disabled(!app.oneClickEnabled)

                    Button {
                        app.selection = .storage
                        app.storage.analyze()
                    } label: {
                        Label("ストレージをスキャン", systemImage: "internaldrive")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            ShredderPanel()
                .frame(width: 300, height: 330)
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [Color.indigo.opacity(0.16), Color.purple.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return "おはようございます"
        case 11..<18: return "こんにちは"
        default: return "こんばんは"
        }
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(spacing: 14) {
            StatTile(
                symbol: "folder.badge.gearshape", color: .indigo, title: "整理候補",
                value: app.lastCandidateCount.map { "\($0)" } ?? "–",
                detail: app.organizer.root.map { $0.lastPathComponent } ?? "フォルダ未設定"
            ) { app.selection = .organizer }
            StatTile(
                symbol: "square.on.square", color: .teal, title: "削除候補",
                value: ByteCountFormatter.string(fromByteCount: deletionCandidateSize, countStyle: .file),
                detail: "重複ファイル・アプリ残骸"
            ) { app.selection = .storage; app.storage.tab = .duplicates }
            StatTile(
                symbol: "doc.zipper", color: .orange, title: "大容量ファイル",
                value: app.lastStorageSummary.map { "\($0.largeFileCount)" } ?? "–",
                detail: app.lastStorageSummary.map { ByteCountFormatter.string(fromByteCount: $0.largeFileSize, countStyle: .file) } ?? "未分析"
            ) { app.selection = .storage; app.storage.tab = .largeFiles }
            StatTile(
                symbol: "app.badge", color: .pink, title: "アプリ残骸",
                value: app.applications.leftoversScanned ? "\(app.applications.leftovers.count)" : "–",
                detail: app.applications.leftoversScanned ? "削除済みアプリのデータ" : "タップしてスキャン"
            ) { app.showLeftovers() }
        }
    }

    private var deletionCandidateSize: Int64 {
        app.storage.duplicateReclaimable + app.applications.leftovers.reduce(0) { $0 + $1.totalSize }
    }

    // MARK: - Mode

    private var modeCard: some View {
        @Bindable var app = app
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    IconBadge(symbol: "dial.medium", color: .purple)
                    Text("整理モード").font(.headline)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(app.automation.isWatching && !app.automation.isPaused ? Color.green : .secondary).frame(width: 7)
                        Text(app.automation.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("整理モード", selection: $app.mode) {
                    ForEach(OrganizationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(app.mode.summary).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Recent

    private var recentOperations: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconBadge(symbol: "clock.arrow.circlepath", color: .orange)
                    Text("最近の操作").font(.headline)
                    Spacer()
                    Button("すべて表示") { app.selection = .history }.buttonStyle(.borderless)
                }
                if app.history.records.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Theme.accent)
                        Text("まだ操作はありません").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    ForEach(app.history.records.prefix(7)) { record in
                        HStack(spacing: 10) {
                            Image(systemName: record.type.symbol)
                                .foregroundStyle(record.status == .failed ? .red : record.type == .trash ? .pink : .indigo)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(filePath: record.sourcePath).lastPathComponent).lineLimit(1)
                                Text("\(record.type.title)・\(record.status.title)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.createdAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// ドーナツ型の容量表示。
struct StorageRing: View {
    let volume: VolumeInfo
    let analyzedSize: Int64?

    private var fraction: Double { Double(volume.used) / Double(max(volume.total, 1)) }

    var body: some View {
        Card {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(fraction > 0.9 ? Theme.danger : Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(fraction, format: .percent.precision(.fractionLength(0))).font(.title3.weight(.bold).monospacedDigit())
                        Text("使用中").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text(volume.name).font(.headline)
                    Label("\(ByteCountFormatter.string(fromByteCount: volume.available, countStyle: .file)) 空き", systemImage: "circle.fill")
                        .font(.callout).foregroundStyle(.green)
                    Text("合計 \(ByteCountFormatter.string(fromByteCount: volume.total, countStyle: .file))").font(.callout).foregroundStyle(.secondary)
                    if let analyzedSize {
                        Text("分析済み \(ByteCountFormatter.string(fromByteCount: analyzedSize, countStyle: .file))（Shredder の集計）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

extension OperationType {
    var symbol: String {
        switch self {
        case .move: "arrow.right.doc.on.clipboard"
        case .rename: "pencil"
        case .createFolder: "folder.badge.plus"
        case .trash: "trash"
        case .restore: "arrow.uturn.backward"
        }
    }
}
