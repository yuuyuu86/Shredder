import SwiftUI

/// 初回起動アニメーション（仕様 15）。
/// 暗い背景にシュレッダーが現れ、落ちてきたファイルを裁断し、ロゴとキャッチコピーを表示する。
/// 演出だけで、実際のファイルには一切触れない。
struct OpeningView: View {
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: ShredderPhase = .idle
    @State private var showShredder = false
    @State private var showLogo = false
    @State private var showButton = false
    @State private var sequence: Task<Void, Never>?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.04), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                ShredderStage(phase: phase, settings: ShredderSettings())
                    .frame(width: 420, height: 320)
                    .opacity(showShredder ? 1 : 0)
                    .scaleEffect(showShredder ? 1 : 0.85)
                    .environment(\.colorScheme, .dark)

                VStack(spacing: 10) {
                    Text("Shredder")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text("散らかったMacを、もっとスマートに。")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .opacity(showLogo ? 1 : 0)
                .offset(y: showLogo ? 0 : 12)

                Button(action: finish) {
                    Text("はじめる").frame(width: 160)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .opacity(showButton ? 1 : 0)
                .disabled(!showButton)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !showButton {
                Button("スキップ", action: finish)
                    .buttonStyle(.glass)
                    .padding(20)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear(perform: play)
        .onDisappear { sequence?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shredder へようこそ")
    }

    private func play() {
        // 視差効果を減らす設定では、動きのある演出を省略する（仕様 15.2）。
        if reduceMotion {
            showShredder = true
            showLogo = true
            showButton = true
            return
        }
        sequence = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.6)) { showShredder = true }
            try? await Task.sleep(for: .milliseconds(600))
            phase = .analyzing // ファイルが落ちてくる
            try? await Task.sleep(for: .milliseconds(800))
            phase = .deleting
            try? await Task.sleep(for: .milliseconds(300))
            phase = .success // 吸い込み・裁断・紙片
            try? await Task.sleep(for: .milliseconds(1_100))
            withAnimation(.easeOut(duration: 0.6)) { showLogo = true }
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.4)) { showButton = true }
            phase = .idle
        }
    }

    private func finish() {
        sequence?.cancel()
        onFinish()
    }
}
