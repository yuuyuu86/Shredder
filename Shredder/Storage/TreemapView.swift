import AppKit
import ShredderCore
import SwiftUI

/// フォルダ容量のツリーマップ（仕様 12.4）。クリックで下位フォルダへ移動する。
struct TreemapScreen: View {
    @Bindable var model: StorageModel
    @State private var hovered: StorageNode?
    @State private var sortedList = false

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            if let node = model.currentNode {
                if sortedList {
                    // サイズ順表示（ツリーマップの代替: キーボード・VoiceOver でも操作しやすい）。
                    List(node.children) { child in
                        row(child)
                    }
                } else {
                    TreemapCanvas(node: node, hovered: $hovered) { child in
                        if child.isDirectory && !child.children.isEmpty { model.drillDown(child) }
                    } menu: { child in
                        nodeMenu(child)
                    }
                    .padding(8)
                }
            }
            Divider()
            footer
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(model.analysis?.root.name ?? "") { model.goUp(to: nil) }
                    .buttonStyle(.borderless)
                ForEach(Array(model.treemapPath.enumerated()), id: \.element.id) { index, node in
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    Button(node.name) { model.goUp(to: index) }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Picker("表示", selection: $sortedList) {
                    Label("ツリーマップ", systemImage: "square.grid.3x3.square").tag(false)
                    Label("サイズ順", systemImage: "list.number").tag(true)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            if let hovered {
                Image(systemName: hovered.isAggregate ? "ellipsis.circle" : (hovered.isDirectory ? "folder" : "doc"))
                Text(hovered.isAggregate ? "\(hovered.name)（\(hovered.fileCount) 件）" : hovered.url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: hovered.size, countStyle: .file)).monospacedDigit()
            } else if let node = model.currentNode {
                Text("\(node.name): \(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))・\(node.fileCount.formatted()) ファイル")
                Spacer()
                Text("クリックでフォルダを開く・右クリックでシュレッダーへ").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(10)
    }

    private func row(_ child: StorageNode) -> some View {
        HStack {
            Image(systemName: child.isAggregate ? "ellipsis.circle" : (child.isDirectory ? "folder" : "doc"))
                .foregroundStyle(.secondary)
            Text(child.name)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: child.size, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { model.drillDown(child) }
        .contextMenu { nodeMenu(child) }
    }

    @ViewBuilder
    private func nodeMenu(_ node: StorageNode) -> some View {
        if !node.isAggregate {
            if node.isDirectory && !node.children.isEmpty {
                Button("開く") { model.drillDown(node) }
            }
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("シュレッダーへ送る…") { model.shred([node.url]) }
        }
    }
}

struct TreemapCanvas<MenuContent: View>: View {
    let node: StorageNode
    @Binding var hovered: StorageNode?
    let open: (StorageNode) -> Void
    @ViewBuilder let menu: (StorageNode) -> MenuContent

    var body: some View {
        GeometryReader { proxy in
            let children = node.children.filter { $0.size > 0 }
            let rects = TreemapLayout.squarify(children.map { Double($0.size) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(children, rects)), id: \.0.id) { child, rect in
                    TreemapTile(node: child, isHovered: hovered?.id == child.id)
                        .frame(width: max(rect.width - 2, 0), height: max(rect.height - 2, 0))
                        .offset(x: rect.minX + 1, y: rect.minY + 1)
                        .onHover { inside in
                            if inside { hovered = child } else if hovered?.id == child.id { hovered = nil }
                        }
                        .onTapGesture { open(child) }
                        .contextMenu { menu(child) }
                        .accessibilityElement()
                        .accessibilityLabel("\(child.name)、\(ByteCountFormatter.string(fromByteCount: child.size, countStyle: .file))")
                        .accessibilityAddTraits(child.isDirectory ? .isButton : [])
                }
            }
        }
    }
}

struct TreemapTile: View {
    let node: StorageNode
    let isHovered: Bool

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 6)
                .fill(color.gradient.opacity(isHovered ? 0.95 : 0.75))
                .overlay(alignment: .topLeading) {
                    if proxy.size.width > 70 && proxy.size.height > 34 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)).font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .padding(6)
                    }
                }
        }
    }

    private var color: Color {
        if node.isAggregate { return .gray }
        if let kind = node.kind, !node.isDirectory || node.children.isEmpty { return kind.color }
        // フォルダは名前から安定した色相を決める。
        let hue = Double(node.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return Color(hue: hue, saturation: 0.45, brightness: 0.7)
    }
}
