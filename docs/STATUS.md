# Shredder 実装状況

仕様書 [SPEC.md](SPEC.md) 第26章「統合テスト・完成条件」に対する実装状況。

- ✅ 実装済み・自動テストあり
- 🟢 実装済み（UI のため自動テストなし、ビルドと起動のみ確認）
- ⚠️ 実装済みだが制約あり（下の「制約と注意点」を参照）

## AIファイル整理

| 項目 | 状況 | 実装 |
|---|---|---|
| Jevによる分類 | ⚠️ | `AI/Jev/JevAPI.swift`, `JevClassifier.swift` |
| Foundation Modelsによる二次解析 | 🟢 | `AI/FoundationModelsClassifier.swift`, `ContentExtractor.swift` |
| 既存フォルダを優先して整理 | ✅ | `FolderIntelligence`, `ReliabilityEvaluator` |
| 必要な場合に新規フォルダを作成 | ✅ | `OrganizationAction.createFolder` |
| 分類不能なファイルを保留 | ✅ | `OrganizationTests.undecidableFilesAreNotMoved` |
| 整理履歴を学習に利用 | ✅ | `HistoryClassifier` |
| ユーザーの修正を次回に反映 | ✅ | `CorrectionClassifier` |
| フォルダ別ルール | ✅ | `RuleClassifier`、設定 > 整理 > フォルダ別ルール |

## 整理モード・整理対象・自動化

| 項目 | 状況 | 実装 |
|---|---|---|
| 手動 / 半自動 / 完全自動モード | ✅ | `OrganizationPlanner.decide` |
| モード切り替え | 🟢 | ホーム、ファイル整理、設定、監視フォルダごと |
| 自動モードでも危険な操作を防止 | ✅ | `SafetyValidator`、危険度判定、上書き禁止 |
| 指定フォルダ / Mac全体 / 監視フォルダ | ✅ | `FileScanner`, `StorageTarget.wholeMac`, `AutomationEngine` |
| リアルタイム整理 | ✅ | `FolderWatcher`（FSEvents）+ `AutomationEngine` |
| スケジュール整理 | ✅ | `ScheduleSpec`, `scheduled_tasks` |
| ワンクリック整理 | 🟢 | `OrganizerModel.oneClickOrganize` |
| 監視の停止・再開 | ✅ | メニューバー、設定 > 監視 |
| ダウンロード中のファイルを処理しない | ✅ | 一時拡張子と2回観測による安定判定 |
| 省電力モード | ✅ | `PowerPolicy`, `SystemConditions` |
| 処理キューの永続化・再開 | ✅ | `task_queue`（スキーマ v2） |

## アプリ削除・ストレージ分析

| 項目 | 状況 | 実装 |
|---|---|---|
| アプリ一覧 / Bundle ID | ✅ | `AppDiscovery` |
| 関連ファイル検出・専用データ | ✅ | `RelatedFileFinder` |
| 共有データの保護 | ✅ | App Group 共有、別アプリの Bundle ID、launchd の所有関係 |
| 最終確認 / ゴミ箱へ移動 / 部分失敗 | ✅ | `AppUninstaller`, `TrashConfirmationView` |
| アプリ残骸の検出 | ✅ | `LeftoverScanner` |
| ストレージ使用状況 | 🟢 | `VolumeInfo`（OS の値と集計値を区別して表示） |
| 大容量ファイル / 重複ファイル | ✅ | `StorageAnalyzer`, `DuplicateFinder`（APFS クローン・ハードリンク対応） |
| ツリーマップ | ✅ | `TreemapLayout`（squarified）、`TreemapView` |

## 3Dシュレッダー・Finder連携・UI

| 項目 | 状況 | 実装 |
|---|---|---|
| 3Dモデル / ドラッグに反応 / ドロップ | 🟢 | `ShredderStage`（RealityKit）、`ShredderPanel` |
| 削除確認 / 裁断演出 / 動作音 / LED | 🟢 | `TrashCoordinator`, `SoundFeedback` |
| 演出を設定で変更 | 🟢 | 設定 > 外観・サウンド、「視差効果を減らす」に対応 |
| Finderからドラッグ＆ドロップ | 🟢 | シュレッダー、Dock アイコン |
| アプリ内から選択 | 🟢 | ファイル整理・大容量・重複・ツリーマップ・アプリ一覧 |
| Finderクイックアクション | ⚠️ | `NSServices`「Shredderで削除」→ 確認画面を開くだけ |
| 6画面 / ライト・ダーク / Liquid Glass | 🟢 | `RootView`、`glassEffect`、外観設定 |

## オンボーディング・メニューバー・履歴

| 項目 | 状況 | 実装 |
|---|---|---|
| 初回起動アニメーション | 🟢 | `OpeningView`（スキップ可、設定から再生可） |
| ウェルカム〜完了の7ステップ | 🟢 | `OnboardingView`（初回スキャンは移動・削除なし） |
| メニューバー常駐・各操作 | 🟢 | `MenuBarContent` |
| ログイン時起動 | 🟢 | `SMAppService.mainApp`（初期値 OFF） |
| すべての変更操作を記録 / Undo / ゴミ箱から復元 | ✅ | `FileOperationEngine`, `operations` |
| 権限不足 / AIが勝手に削除しない / 上書きしない / システム保護 | ✅ | `SafetyValidator`, `TrashService`, `ProtectedPaths` |

## 制約と注意点

- **Jev はクラウド API**（`POST https://api.typesafe.ai/v1/systemone`）です。仕様 22.1 と両立させるため、ファイルの中身は送らず、ファイル名・種類・サイズ・フォルダ名だけを送ります。API キーがない場合は、Apple Intelligence とローカルのルールで分類します。実際の API キーでの接続は未確認です。
- **Apple Intelligence** は対応する Mac で有効なときだけ使います。使えない場合は Jev とルールで処理を続けます。
- **Finder のクイックアクション**は macOS のサービスとして登録しています。右クリック >「サービス」（またはクイックアクション）に「Shredderで削除」が表示されます。表示されない場合は、システム設定 > キーボード > キーボードショートカット > サービスで有効にしてください。
- **管理者権限が必要な項目**（`/Library` 配下、root 所有のアプリ本体）は削除しません。一覧には表示します。
- **Launch Agent** はゴミ箱へ移すだけで、`launchctl` での停止はしません（次回ログイン時に無効になります）。
- **残骸検出**では、他アプリのデータへのアクセス確認が出ないよう、Containers と Group Containers を対象外にしています。
- **配布**: 直接配布（App Sandbox なし、Hardened Runtime）を前提にしています。公証には Developer ID での署名が必要です。
- **UI の表示確認**: 3D シュレッダーを含め、画面の見た目と操作は実機で確認していません（ビルドと起動・終了のみ確認済み）。

## 開発

```bash
xcodegen generate
```

```bash
xcodebuild -project Shredder.xcodeproj -scheme Shredder -configuration Debug build
```

```bash
cd Packages/ShredderCore && swift test
```
