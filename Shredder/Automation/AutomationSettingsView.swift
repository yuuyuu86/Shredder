import ShredderCore
import SwiftUI

/// 監視・スケジュール・バックグラウンド処理の設定（仕様 7, 19）。
struct AutomationSettingsSection: View {
    enum Part { case monitoring, background }

    @Bindable var automation: AutomationController
    var part: Part = .monitoring

    var body: some View {
        switch part {
        case .monitoring: monitoring
        case .background: background
        }
    }

    @ViewBuilder
    private var monitoring: some View {
        Section {
            LabeledContent("状態") {
                HStack {
                    Text(automation.statusText).foregroundStyle(.secondary)
                    Button(automation.isPaused ? "再開" : "一時停止") { automation.setPaused(!automation.isPaused) }
                }
            }
            Toggle("リアルタイム整理（ファイルの追加を検知して整理）", isOn: $automation.realtimeEnabled)
            Toggle("スケジュール整理", isOn: $automation.schedulesEnabled)
            if automation.pendingCount > 0 {
                LabeledContent("処理待ち", value: "\(automation.pendingCount) 件")
            }
        } header: {
            Text("自動整理")
        } footer: {
            Text("ダウンロード中や書き込み中のファイルは、サイズと更新日時が変わらなくなるまで待ってから整理します。自動整理でもファイルを削除することはありません。")
        }

        Section {
            if automation.watchFolders.isEmpty {
                Text("監視するフォルダはまだありません。").foregroundStyle(.secondary)
            }
            ForEach(automation.watchFolders) { folder in
                HStack {
                    Toggle(isOn: Binding(get: { folder.enabled }, set: { var f = folder; f.enabled = $0; automation.update(f) })) {
                        Label(folder.url.lastPathComponent, systemImage: "folder")
                            .help(folder.path)
                    }
                    Spacer()
                    Picker("モード", selection: Binding(get: { folder.mode }, set: { var f = folder; f.mode = $0; automation.update(f) })) {
                        ForEach(OrganizationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("削除", systemImage: "minus.circle") { automation.remove(folder) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("フォルダを追加…", systemImage: "plus") { automation.addWatchFolder() }
                Spacer()
                Button("今すぐ整理") { automation.organizeWatchFoldersNow() }
                    .disabled(automation.watchFolders.isEmpty)
            }
        } header: {
            Text("監視フォルダ")
        } footer: {
            Text("フォルダごとに整理モードを選べます。手動モードのフォルダは、整理候補を確認待ちにするだけで移動しません。")
        }

        Section("スケジュール") {
            ForEach(automation.schedules) { schedule in
                ScheduleRow(schedule: schedule, automation: automation)
            }
            Button("スケジュールを追加", systemImage: "plus") { automation.addSchedule() }
        }

        if !automation.reviewItems.isEmpty || !automation.log.isEmpty {
            Section("最近の自動整理") {
                ForEach(automation.log.prefix(10)) { entry in
                    let summary = entry.event.summary
                    Label {
                        HStack {
                            Text(summary.text).lineLimit(1)
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: summary.symbol)
                    }
                    .font(.callout)
                }
                if !automation.reviewItems.isEmpty {
                    Text("確認待ち \(automation.reviewItems.count) 件はファイル整理画面で承認できます。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        Section {
            Toggle("Mac の負荷が低いときに監視フォルダを見直す", isOn: $automation.idleScanEnabled)
            Toggle("バッテリー使用中・低電力モードでは負荷の高い解析を控える", isOn: $automation.powerSavingEnabled)
            LabeledContent("電源") {
                Text(powerDescription).foregroundStyle(.secondary)
            }
        } header: {
            Text("バックグラウンド")
        } footer: {
            Text("省電力時は Apple Intelligence による内容解析を行わず、ファイル名などのメタデータだけで分類します。低電力モードかつバッテリー使用中、または Mac が高温のときは自動整理を待機します。")
        }

    }

    private var powerDescription: String {
        let c = automation.conditions
        var parts = [c.onBattery ? "バッテリー" : "電源アダプタ"]
        if c.lowPowerMode { parts.append("低電力モード") }
        if c.thermalPressure { parts.append("高温") }
        return parts.joined(separator: "・")
    }
}

struct ScheduleRow: View {
    let schedule: ScheduledOrganization
    let automation: AutomationController

    private static let weekdaySymbols = Calendar.current.veryShortWeekdaySymbols

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: binding(\.enabled)) {
                    Text(URL(filePath: schedule.targetFolder).lastPathComponent)
                }
                Button("変更…") { automation.chooseTarget(for: schedule) }
                    .buttonStyle(.borderless)
                Spacer()
                DatePicker("時刻", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Button("削除", systemImage: "minus.circle") { automation.remove(schedule) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { weekday in
                    Toggle(Self.weekdaySymbols[weekday - 1], isOn: Binding(
                        get: { schedule.schedule.weekdays.contains(weekday) },
                        set: { on in
                            var updated = schedule
                            if on { updated.schedule.weekdays.insert(weekday) } else { updated.schedule.weekdays.remove(weekday) }
                            automation.update(updated)
                        }
                    ))
                    .toggleStyle(.button)
                }
                Spacer()
                if let next = schedule.schedule.nextFire(after: Date()), schedule.enabled {
                    Text("次回: \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ScheduledOrganization, Bool>) -> Binding<Bool> {
        Binding(get: { schedule[keyPath: keyPath] }, set: { var s = schedule; s[keyPath: keyPath] = $0; automation.update(s) })
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: schedule.schedule.hour, minute: schedule.schedule.minute, second: 0, of: Date()) ?? Date() },
            set: { date in
                var s = schedule
                s.schedule.hour = Calendar.current.component(.hour, from: date)
                s.schedule.minute = Calendar.current.component(.minute, from: date)
                automation.update(s)
            }
        )
    }
}
