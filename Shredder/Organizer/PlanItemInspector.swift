import AppKit
import ShredderCore
import SwiftUI

/// 右カラム: ファイル詳細・AI判断理由・整理先変更・承認/保留/除外（仕様 13.4）。
struct PlanItemInspector: View {
    let item: PlanItem
    @Bindable var organizer: OrganizerModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.file.url.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(item.file.name).font(.headline).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("現在の場所", value: JevPathFormatter.relative(item.file.parentURL, root: organizer.root))
                if let modified = item.file.modifiedAt {
                    LabeledContent("更新日", value: modified.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([item.file.url]) }
            }

            Section("AI の提案") {
                LabeledContent("整理先", value: item.destinationFolder.map { JevPathFormatter.relative($0, root: organizer.root) } ?? "未定")
                LabeledContent("判断元", value: item.classification.source.title)
                LabeledContent("信頼性") { ReliabilityBadge(assessment: item.assessment) }
                Text(item.classification.reason)
                    .font(.callout)
                if !item.assessment.factors.isEmpty {
                    Text(item.assessment.factors.joined(separator: " ・ "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let probabilities = item.classification.probabilities, probabilities.count > 1 {
                    ForEach(probabilities.sorted { $0.value > $1.value }.prefix(3), id: \.key) { entry in
                        LabeledContent(entry.key, value: entry.value.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption)
                    }
                }
            }

            Section("結果の予測") {
                Text(prediction)
                    .font(.callout)
                if case .nameCollision(_, let suggested) = item.conflict {
                    Text("移動先に同じ名前のファイルがあります。上書きはしません。")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    Button("「\(suggested)」として移動する") { organizer.acceptSuggestedName(for: item) }
                }
                if case .blocked(let reason) = item.decision {
                    Text(reason).foregroundStyle(.red).font(.callout)
                }
            }

            Section {
                Button("整理先を変更…") { organizer.changeDestination(for: item) }
                HStack {
                    Button("承認") { organizer.setReview(.approved, for: [item.id]) }
                        .buttonStyle(.glassProminent)
                        .disabled(isBlocked)
                    Button("保留") { organizer.setReview(.held, for: [item.id]) }
                    Button("除外") { organizer.setReview(.excluded, for: [item.id]) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isBlocked: Bool {
        if case .blocked = item.decision { return true }
        return item.action == .keep || item.action == .requestReview
    }

    private var prediction: String {
        let destination = item.destinationFolder.map { JevPathFormatter.relative($0, root: organizer.root) } ?? ""
        return switch item.action {
        case .move: "「\(destination)」へ移動します。"
        case .createFolder: "フォルダ「\(destination)」を新しく作成し、そこへ移動します。"
        case .keep: "移動しません。"
        case .requestReview: "AI が判断できなかったため移動しません。整理先を指定すると移動できます。"
        }
    }
}

extension AnalysisSource {
    var title: String {
        switch self {
        case .userRule: "整理ルール"
        case .userCorrection: "あなたの修正履歴"
        case .history: "整理履歴"
        case .jev: "Jev"
        case .foundationModels: "Apple Intelligence"
        case .localHeuristic: "ファイルの種類"
        case .none: "なし"
        }
    }
}
