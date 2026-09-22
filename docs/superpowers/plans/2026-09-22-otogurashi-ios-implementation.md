# オトグラシ iOS優先 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 生活の音付き動画3〜6本から15秒の音楽動画を作成し、iPhoneで保存・共有・再編集できる初版を完成させる。

**Architecture:** Flutter/Dartが画面・編集状態・決定的な編曲recipeを担当し、Swiftの媒体サービスが撮影・音声解析・音声/映像のレンダリングを担当する。端末内保存とiOS共有を接続し、OS依存箇所を境界の内側に閉じる。Androidは今回ビルドも動作保証もしない。

**Tech Stack:** Flutter stable / Dart、Swift、AVFoundation / AVFAudio、Accelerate、SQLite、GitHub Actions macOS、TestFlight。

**Spec:** ../specs/2026-09-21-otogurashi-ios-design.md

**Repository:** https://github.com/yurashu2-droid/OtoGrashi
**Build environment:** ../../delivery/build-environment.md（Flutter 3.47.5 / Dart 3.13.4、macos-26を第一候補。実装時にXcode実在を検証）
**Workspace:** C:/Programer___Amano/OtoGrashi
**Status:** 実装前のレビュー用計画。ここに記載するコード・コマンドは実装時の契約と検証手順であり、実行済みではない。

## Global Constraints

- 対象: iPhone / iOS 18以降を提案。
- 当面のビルド・端末テスト・品質保証はiOSのみ。Androidは将来転用しやすい程度に備え、同時対応を進めない。
- 3〜6クリップを使う。初回は3つに案内する。
- 15秒 / 縦9:16 / 1080p / 30fpsを初版の完成動画の基準とする。
- 初版は内部テンポ128 BPM、4拍子、8小節 = 15秒。
- 48kHz音声では720,000サンプル、30fps映像では450フレーム。
- 初版には公開フィードやコメント欄を作らず、iOS共有シートとリミックス用ファイルで人に渡す。
- 「道具をタップして演奏する別のアプリ」は保留。今回の操作体系に入れない。
- 画面は普通の長方形。撮影画面だけ上に開いた蓋、下に飲み口。左右にカップ側面を置かない。
- 音・映像連動エフェクトは初版後。初版に未完成の選択メニューを置かない。
- サブエージェントはユーザーが許可したgpt-5.6-luna / maxとgpt-5.6-sol / mediumのみ。モデル制約をレビュー役にも適用。
- 現在の別Webアプリのコード・ビルド設定を変更しない。
- 共有プレビューと出力は同じ編曲・映像recipeを使う。無関係なBGMを載せるだけの代替実装は禁止。
- コアはオフライン。アカウント、外部生成AI API、サーバーは初版に要求しない。
- 実機未検証の項目を合格扱いしない。

## Review Focus

1. iCloud未取得・音声なし・HDR・可変フレームレートの取り込み動画でも、原本を失わず取り込み可否と変換結果が分かる — Task 3。
2. 古い編集revisionの生成完了が、新しい作品や選択へ上書きされない — Task 6。
3. 着信・Bluetooth切断・バックグラウンド移動中に不意の再生や録画成功表示をしない — Task 3/6/10。
4. 原本を複数作品から使う場合、1作品の削除で他作品が壊れない — Task 2/8。
5. リミックスのZIPパストラバーサル・巨大展開・未知版を安全に拒否し、既存作品を変更しない — Task 9。

## ファイル構成

```text
lib/
  main.dart
  app/otogurashi_app.dart
  app/app_dependencies.dart
  domain/clip_asset.dart
  domain/project.dart
  domain/arrangement.dart
  domain/video_recipe.dart
  domain/arrangement_engine.dart
  domain/project_reducer.dart
  media/media_gateway.dart
  media/platform_media_gateway.dart
  media/media_messages.dart
  storage/project_database.dart
  storage/asset_repository.dart
  storage/project_repository.dart
  storage/remix_archive.dart
  features/onboarding/
  features/capture/
  features/create/
  features/arrange/
  features/library/
  features/export/
  features/settings/
  design/tokens.dart
  design/pressable.dart
  design/capture_chrome.dart
  design/clipboard_chrome.dart
  design/playback_chrome.dart
ios/
  Runner/Media/MediaPlugin.swift
  Runner/Media/CaptureService.swift
  Runner/Media/AudioSessionCoordinator.swift
  Runner/Media/AudioAnalyzer.swift
  Runner/Media/AudioRenderer.swift
  Runner/Media/VideoRenderer.swift
  Runner/Media/MediaValidator.swift
  Runner/Media/JobRegistry.swift
  RunnerTests/
test/
  domain/
  storage/
  features/
  media/
integration_test/
  sample_project_flow_test.dart
assets/demo/
  manifest.json
  source/
  preview.mp4
docs/testing/iphone-checklist.md
docs/delivery/testflight.md
.github/workflows/ios-check.yml
.github/workflows/testflight.yml
```

画面のファイルは役割ごとにView、Controller、Stateへ分ける。小さな静的部品まで無意味に分割しない。
DartのDomainはFlutter・AVFoundation・OSの絶対パスに依存しない。
媒体処理に渡すファイル参照はアプリ管理下の相対IDから解決する。

## 実行順序と最初の縦断確認

Task番号は責務の識別子。実行順序は **1 → 2 → 4 → 5 → 6 → 3 → 7 → 8 → 9 → 10** とする。
Task 4の前にTask 3のmedia_messages.dart / MediaGatewayの型契約だけを作成し、録画機能はまだ接続しない。
Task 6までで「同梱3素材 → 編曲 → 15秒MP4 → Flutter再生」を実際に通す。撮影UIだけが動く状態を最初の完成としない。
Task 7まではレイアウトを3段に絞って検証可能。Task 7完了時に3レイアウトと全アレンジをそろえる。

## Task 1: 起動できるFlutter iOSアプリと検証環境

**Files:** Create pubspec.yaml, pubspec.lock, analysis_options.yaml, lib/main.dart, lib/app/otogurashi_app.dart, lib/design/tokens.dart, ios/Runner configuration, test/app_smoke_test.dart, .github/workflows/ios-check.yml, README.md.

**Interfaces:** produces OtogurashiApp、基本テーマ、iOS build scheme Runner。後続はapp_dependencies.dartからサービスを受け取る。

- [ ] Flutterを固定版で導入し、空リポジトリにiOSのみの標準構成を作る。生成前のdocsを維持する。

```sh
flutter create --platforms=ios --project-name otogurashi .
flutter --version
flutter doctor -v
```

生成された仮Bundle IDはSimulator用の開発識別子としてのみ扱う。署名配布前に実際のApp Store Connect設定へ置き換え、仮のままアップロードしない。

- [ ] 既定カウンター画面を置き換える前に、アプリの入口を確認するテストを用意する。

```dart
testWidgets('first launch offers a sample and personal recording', (tester) async {
  await tester.pumpWidget(const OtogurashiApp());
  expect(find.text('聴いてみる'), findsOneWidget);
  expect(find.text('自分の音でつくる'), findsOneWidget);
});
```

- [ ] flutter test test/app_smoke_test.dartでテストが入口の欠落を示すことを確認する。
- [ ] OtogurashiAppをMaterialAppベースで実装し、テーマ・日本語・文字拡大・ルートを設定する。装飾は後のDesignSystemへ委譲する。
- [ ] CIはFlutterの固定版導入→pub get→analyze→test→iOS Simulatorビルドの順にする。署名情報は使わない。

```sh
flutter pub get
flutter analyze --fatal-infos
flutter test
flutter build ios --simulator --debug
```

- [ ] CIの実行環境、Flutter/Dart/Xcode版とcommit SHAをログに残し、失敗ログを成果物にする。Windowsのflutter testだけでiOSビルドを合格にしない。
- [ ] 変更ファイルのみcommit: feat: bootstrap iOS-first Flutter app and checks

## Task 2: 原本・編集データ・下書きを壊さない保存

**Files:** lib/domain/clip_asset.dart, project.dart, project_reducer.dart; lib/storage/project_database.dart, asset_repository.dart, project_repository.dart; test/storage/project_repository_test.dart.

**Interfaces:**

```dart
abstract interface class ProjectRepository {
  Future<Project> create(String title);
  Future<Project?> load(String id);
  Future<void> save(Project project, {required int expectedRevision});
  Future<void> deleteProject(String id);
  Future<List<Project>> list();
}
abstract interface class AssetRepository {
  Future<ClipAsset> importFile(String sourcePath);
  Future<String> resolvePath(String assetId);
  Future<List<String>> referencingProjectIds(String assetId);
  Future<void> deleteUnreferenced(String assetId);
}
```

Projectはid/title/revision/clipIds/arrangement/videoRecipe/createdAt/updatedAtを持つ不変値。
ClipAssetはid/relativePath/durationUs/width/height/rotation/sha256/labelを持つ。
ProjectReducerは編集コマンドからrevisionを1増やしたProjectを返し、原本を直接変更しない。

- [ ] 一時ディレクトリ＋SQLiteのテストで次を先に固定する。

```dart
test('deleting one project keeps a shared original', () async {
  final asset = await assets.importFile(fixtureVideoPath);
  final first = await createProjectWith(asset.id);
  final second = await createProjectWith(asset.id);
  await projects.deleteProject(first.id);
  expect((await projects.load(second.id))!.clipIds, contains(asset.id));
  expect(await File(await assets.resolvePath(asset.id)).exists(), isTrue);
});
```

- [ ] 古いexpectedRevisionで保存したときにRevisionConflictを返すテスト、DB確定前に終了した一時コピーを次回復元時に処理するテストを追加する。
- [ ] コピー→媒体確認→原本ディレクトリへの移動→DB transactionの順に確定。失敗時は未確定ファイルだけを片付ける。
- [ ] プロジェクト参照と素材を別テーブルで管理し、素材削除は参照ゼロをDB内で再確認する。
- [ ] ファイル名をUUIDにし、DBにOS固有の絶対パスを保存しない。解析キャッシュは別ディレクトリ。
- [ ] flutter test test/storageを実行し、再起動後の復元・参照維持を確認してcommitする。

## Task 3: 実録画と既存動画の取り込み

**Files:** lib/media/media_gateway.dart, platform_media_gateway.dart, media_messages.dart; lib/features/capture/capture_controller.dart, capture_state.dart, capture_screen.dart; ios/Runner/Media/CaptureService.swift, AudioSessionCoordinator.swift, MediaPlugin.swift; test/features/capture_controller_test.dart; ios/RunnerTests/CaptureStateTests.swift.

**Interfaces:**

```dart
abstract interface class MediaGateway {
  Stream<MediaEvent> get events;
  Future<CaptureHandle> prepareCapture();
  Future<void> startCapture(String operationId, {required int maxDurationUs});
  Future<CapturedMedia> stopCapture(String operationId);
  Future<AnalyzedClip> analyze(String operationId, String assetId);
  Future<RenderedMedia> render(RenderRequest request);
  Future<void> cancel(String operationId);
  Future<void> disposeCapture();
}
```

全リクエストにoperationId、作品に関係する処理にprojectIdとrevisionを含める。
イベントはoperationId/type/progress/errorCodeを持ち、操作開始時のIDが一致しないイベントを採用しない。
CaptureHandleはプレビュー表示に必要な識別情報だけ。動画/音声bufferをDartへ大量転送しない。

- [ ] FakeMediaGatewayでreadyになる前に録画成功を表示しないテストを書く。

```dart
test('interruption never becomes a successful capture', () async {
  await controller.prepare();
  await controller.record();
  gateway.emitInterrupted(controller.operationId);
  expect(controller.state.phase, CapturePhase.interrupted);
  expect(controller.state.savedAssetId, isNull);
});
```

- [ ] 権限拒否・準備中の連打・部分ファイル・電話割り込みの状態遷移をテストする。
- [ ] iOS媒体境界を実装。AVCaptureSessionは専用キューで扱い、音声Sessionの所有をAudioSessionCoordinatorへ一本化する。
- [ ] 初版の録画は映像と音を同一収録セッションでファイルへ保存し、確定後に解析する。3秒は媒体PTS基準、6秒は明示的に選択した場合だけ。
- [ ] 写真取り込みは選択したURLをアプリ領域へコピーし、音声トラックと長さを検査。0.3秒未満・音声なしは拒否理由を表示。最大6秒の選択区間を保持する。
- [ ] HDR/可変fps/回転付き入力は書き出し時のSDR・30fpsに正規化する契約にし、解析段階では表示向きとPTSを保存する。
- [ ] プレビュー音と触覚は録画中停止。Bluetoothや割り込み後の再開は明示操作を要求する。
- [ ] flutter test test/features/capture_controller_test.dart、iOSの状態テスト、iPhone録画チェックを行い、実機未確認項目は未確認のまま記録する。

## Task 4: 生活音の解析と決定的な15秒の編曲

**Files:** lib/domain/arrangement.dart, arrangement_engine.dart; ios/Runner/Media/AudioAnalyzer.swift; test/domain/arrangement_engine_test.dart; ios/RunnerTests/AudioAnalyzerTests.swift.

**Interfaces:**

```dart
Arrangement arrange({
  required List<AnalyzedClip> clips,
  required ArrangementStyle style,
  required int seed,
});
```

AnalyzedClipはassetId、durationSamples、sampleRate、onsetSamples、peak、rms、suggestedRoleを返す。
ArrangementはsampleRate=48000、totalSamples=720000、templateId/version、analysisVersion、rendererVersion、seed、eventsを持つ。
各SoundEventはassetId/sourceStartSample/destinationStartSample/durationSamples/gain/fadesを持つ。
各映像イベントにはassetId、destinationStartSample、durationSamples、sourceVideoStartTime（分子/分母）、crop、loopMode（loop/hold/once）を記録する。自動解析値、ユーザー調整値、キャッシュは分離する。
時刻は整数で保存。描画側にSwiftのCMTimeを漏らさない。

- [ ] 3素材と6素材、同じ音だけ、無音を含む入力、同じseedの再現性をテストする。

```dart
test('arrangement is deterministic and fits exactly 15 seconds', () {
  final a = arrange(clips: threeFixtures, style: ArrangementStyle.sparse, seed: 42);
  final b = arrange(clips: threeFixtures, style: ArrangementStyle.sparse, seed: 42);
  expect(a.toJson(), b.toJson());
  expect(a.totalSamples, 720000);
  expect(a.events.every((e) =>
    e.destinationStartSample >= 0 &&
    e.destinationStartSample + e.durationSamples <= 720000), isTrue);
  expect(a.events.map((e) => e.assetId).toSet(), threeFixtures.map((e) => e.assetId).toSet());
});
```

- [ ] 解析ではmono/48kHzのPCMを用い、10ms単位のRMS・差分エネルギー・ピークを計算する。候補間に最小間隔を設け、短い打音と持続音を区別する。
- [ ] 役割を意味認識と混同しない。候補が弱い素材は区間選択へ戻せる。
- [ ] 1小節90000samples、1拍22500samples。最初の3小節で主役3素材を紹介し、4〜7小節で混ぜ、8小節で次のループへつなぐ。
- [ ] ぽつぽつ/ゆらゆら/にぎやかのイベント密度・swing・ゲインを明示的なテンプレートで実装する。PRNGは仕様を固定したxorshift32を実装し、状態は各段で0xffffffffにマスクする。seed=0は定義した非ゼロ値0x6d2b79f5へ置換する。SDK既定のRandomの版差に依存しない。
- [ ] 同じseedの金標準fixtureを保存し、flutter test test/domainとSwift解析テストを通してcommitする。

## Task 5: 曲として聴ける音声レンダリング

**Files:** ios/Runner/Media/AudioRenderer.swift; ios/RunnerTests/AudioRendererTests.swift; assets/demo/source; assets/demo/manifest.json; docs/testing/audio-fixtures.md.

**Interfaces:** AudioRenderer.render(arrangement: ArrangementPayload, assets: [String: URL], outputURL: URL, cancellation: CancellationToken) async throws -> AudioRenderReport.
AudioRenderReportはsampleCount、sampleRate、channels、peak、nonFiniteCountを返す。
CancellationTokenはJobRegistry内のoperationIdで管理するキャンセル状態。

- [ ] 合成インパルスと持続音から、指定サンプル位置・総長・非有限値を検査するSwiftテストを先に作る。

```swift
func testRenderLengthAndOnset() async throws {
    let report = try await renderFixture(startSample: 90000)
    XCTAssertEqual(report.sampleCount, 720000)
    XCTAssertEqual(report.nonFiniteCount, 0)
    XCTAssertLessThanOrEqual(report.peak, 1.0)
    XCTAssertLessThanOrEqual(abs(try firstAudibleSample(report.url) - 90000), 240)
}
```

- [ ] 打音前後の余白を含めて切り出す。端には短いフェードを入れ、持続音の繰り返しは端をクロスフェードする。
- [ ] ゲイン補正に上限を設け、小さい雑音を無制限増幅しない。最終ミックスにピーク抑制を適用する。
- [ ] 伴奏はライセンスを記録した自作素材または自作の音色を使う。元音のゲインと伴奏量を分ける。
- [ ] 正確な720000samplesのPCMをまず完成させる。内部PCM長と圧縮音声のpriming/paddingを区別し、MP4はpresentation timeline=15.000秒と450映像フレーム、先頭・末尾の余分音の有無で検査する。復号サンプル数が常に720000になるとは仮定しない。
- [ ] 30組以上の実物素材で音質を確認し、短音3つ/持続音3つ/低音量/クリッピング入力の聴取結果を残す。
- [ ] テストと聴取の合格を分けて記録し、出力fixtureとcommitを作る。

## Task 6: 同じrecipeでプレビューと1080p動画を書き出す

**Files:** lib/domain/video_recipe.dart; lib/features/arrange/render_controller.dart; lib/media/media_messages.dart; ios/Runner/Media/VideoRenderer.swift, MediaValidator.swift, JobRegistry.swift; test/features/render_controller_test.dart; ios/RunnerTests/VideoRendererTests.swift.

**Interfaces:**

```dart
class RenderRequest {
  final String operationId;
  final String projectId;
  final int revision;
  final Arrangement arrangement;
  final VideoRecipe video;
  final RenderQuality quality; // preview or full
}
```

RenderedMediaはoperationId/projectId/revision/path/durationUs/width/heightを返す。
VideoRecipeはlayout/clipCrops/captions/eventsを持つ。効果設定は初版で持たせなくても読み込み時の欠落を「なし」にできるスキーマにする。

- [ ] revision更新後に完了した古いジョブを捨てるテストを書く。

```dart
test('late render cannot replace current revision', () async {
  controller.open(projectAtRevision(1));
  final oldId = await controller.generate();
  controller.open(projectAtRevision(2));
  gateway.emitRendered(oldId, revision: 1);
  expect(controller.state.project.revision, 2);
  expect(controller.state.readyMedia, isNull);
});
```

- [ ] 映像は450フレームの絶対時刻から合成。48kHz sample位置sから最近傍フレームへはfloor((s * 30 + 24000) / 48000)を用い、同点は後のフレームへ寄せる。イベント時刻は映像基準に書き戻さない。媒体の向きとクロップを適用し、3段/順番に大きく/フォトダンプを同じrecipeから生成する。
- [ ] 音源のonsetと映像PTSを結び付ける。高速の打点ごとに映像を点滅させず、映像切替は拍・小節単位に抑える。
- [ ] 4〜6素材は中盤の小節境界で表示対象を切り替え、全素材を見せる。
- [ ] previewは解像度だけを下げ、音イベント・字幕位置の相対値・映像イベントはfullと同一。オフスクリーンのFlutter画面を録画して出力しない。
- [ ] 検証では動画トラック長、音声トラック、フレーム数、復号後音声のonset差を測る。目標差は1フレーム以内。
- [ ] export成功→Photos保存成功→共有シート終了を別状態にする。キャンセル・容量不足は下書きを残して戻す。
- [ ] テスト後、15秒動画をiPhoneの写真アプリで視聴し、出力を確認してcommitする。

## Task 7: 道具モチーフと触って気持ちよい一周を完成させる

**Files:** lib/design/pressable.dart, capture_chrome.dart, clipboard_chrome.dart, playback_chrome.dart; lib/features/onboarding/, create/, capture/, arrange/, export/; test/features/creation_flow_test.dart; integration_test/sample_project_flow_test.dart.

**Interfaces:** 画面はProjectRepositoryとMediaGatewayを依存注入で利用する。UIは媒体セッションを直接所有しない。
PressableはonPressed/enabled/childを取り、押下中の反応と確定操作を分離する。

- [ ] 内蔵サンプルから作成→アレンジ変更→完成までをFakeMediaGatewayで通すWidgetテストを先に書く。
- [ ] 起動時に聴く意思を示す操作があるまで音を鳴らさない。サンプル体験はスキップ可能。
- [ ] つくる画面に素材カード、撮影/取り込み、3種類のアレンジ、元音比較、もうひとつ、調整シートを接続する。
- [ ] 撮影は上に蓋の裏、下に飲み口。左右映像を遮らない。装飾はCustomPainterまたは軽量な透過アセット、ボタンは通常のアクセシブルなWidget。
- [ ] クリップボードの素材移動は指に追随させる。並べ替えメニューも用意する。
- [ ] 完成画面は映像を主役にし、TVモチーフは上下の一部。保存・共有を普通の文字で示す。
- [ ] touch-down反応、キャンセル可能な押下、シートの戻り、アレンジを連続選択したときの最新要求優先を実装する。
- [ ] Reduce Motionでは大きな移動を省く。44pt以上の操作領域、文字拡大、VoiceOver順序をWidgetテストと実機で確認。
- [ ] Simulatorの内蔵サンプル統合テストを通し、通常速度の画面録画で動きの合否を確認してcommitする。

## Task 8: 素材再利用・作品管理・字幕調整・復元

**Files:** lib/features/library/, settings/; lib/features/arrange/adjustments_sheet.dart; test/features/library_test.dart; test/storage/recovery_test.dart.

**Interfaces:** 既存ProjectRepositoryとAssetRepositoryを使用。reducerコマンドはrename、replaceClip、setGain、setCaption、setCrop、reorderClips、selectStyle、duplicateProject。
Undoは編集履歴に基づき、原本の物理削除には流用しない。

- [ ] 再編集時に旧完成版を残す、同じ素材を2作品から利用する、削除して取り消すテストを書く。
- [ ] Libraryは作品/素材の別タブを持ち、空状態から撮影へ戻れる。再生の自動連鎖を避ける。
- [ ] 字幕表示・短い一言・素材名・伴奏量・素材ゲイン・切り出し・クロップを調整シートに配置。初期画面に詳細設定を全部出さない。
- [ ] テキスト長・素材数・ゲイン範囲をDomainで検証し、UIだけの制約にしない。
- [ ] 未完了ExportJobを起動時に調べ、一時出力は完成作品として一覧へ出さない。旧完成版から再書き出しできる。
- [ ] 容量画面は原本/作品/再生成可能キャッシュを分ける。キャッシュ削除で原本を消さない。
- [ ] 共有参照・復元・Undoテストを通し、再起動による下書き回復をiPhoneで確認してcommitする。

## Task 9: 動画共有と安全なリミックスファイル

**Files:** lib/storage/remix_archive.dart; lib/features/export/share_controller.dart, remix_confirmation.dart; ios/Runner platform document configuration; test/storage/remix_archive_test.dart.

**Interfaces:**

```dart
abstract interface class RemixArchive {
  Future<File> exportProject(Project project, Set<String> selectedAssetIds);
  Future<Project> importFile(File archive);
}
```

manifestはschemaVersion/project/arrangement/videoRecipe/assets/hashesを持つ。
音・映像連動エフェクトを追加した将来版はpreset versionも含める。未知の必須機能を黙って落とさない。

- [ ] 悪意あるパスと展開上限をテストする。

```dart
test('archive traversal does not write outside staging', () async {
  final archive = await zipFixture({'../escape.mov': videoBytes});
  await expectLater(remix.importFile(archive), throwsA(isA<InvalidArchive>()));
  expect(await File(outsideStagingPath).exists(), isFalse);
  expect(await projects.list(), isEmpty);
});
```

- [ ] 未知版、ハッシュ不一致、6素材超過、展開後150MB超過、シンボリックリンク、破損動画のfixtureを追加する。
- [ ] 共有前に渡す素材一覧と任意作者名を表示。位置等の不要メタデータを除去した共有用メディアを生成する。
- [ ] 新規staging領域で上限付き展開と媒体確認を行い、すべて成功後に新Projectとして確定する。
- [ ] .otogurashiファイルのiOS関連付け、他アプリからの読み込み、共有シート、Photosへの追加を接続する。
- [ ] シェア中止はエラー扱いせず、送信・投稿完了とは表示しない。
- [ ] 悪性fixtureテストと端末間のファイル往復を確認。2台目未用意なら往復の未確認を明示してcommitする。

## Task 10: TestFlight配布と初版の品質確認

**Files:** .github/workflows/testflight.yml, docs/delivery/testflight.md, docs/testing/iphone-checklist.md, ios/Runner/PrivacyInfo.xcprivacy, iOS signing/export configuration.

**Interfaces:** 既存のRunnerターゲットとreleaseビルド。署名/配布に必要な値はGitHub Environmentから渡す。
Bundle ID/Team ID/配布グループはユーザー既存設定と照合し、勝手にアプリを作成しない。

- [ ] 配布workflowはworkflow_dispatch、対象commitとbuild numberを記録。PRビルドと署名ジョブを分離する。
- [ ] archive/export前にiOS署名設定と証明書の対応を検証し、失敗したままアップロードを走らせない。
- [ ] 一時Keychainに証明書を入れ、job終了時のalways処理で秘密ファイルとKeychainを削除する。ログへ秘密値を出さない。
- [ ] アップロード成功、Apple側処理完了、テスターへの利用可能状態を区別して記録する。
- [ ] プライバシー使用説明、採用プラグインのrequired reason API、内蔵素材の出所を実コードから確認する。
- [ ] CI成果物としてIPA、dSYM、xcresult、使用環境、変更説明を保持。個人の収録素材はCIログ・成果物に含めない。
- [ ] 次の実機シナリオの結果を機種/OS/buildごとに記録する。

```text
初回権限許可と拒否 / 3素材から完成 / 6素材 / 3アレンジ
録音中に電話 / 音声ルート切替 / Bluetooth切断
生成中に別作品へ / 生成中に背景へ / 保存時の容量不足
アプリ終了後に復元 / 写真保存と共有キャンセル
同じ音源の複数作品利用 / リミックス往復
文字拡大 / VoiceOver / Reduce Motion
10作品連続生成 / 音と映像の同期 / 出力動画の共有先再生
```

- [ ] 重大なデータ消失、無音出力、同期ずれ、入力不能を解消してから初版完成とする。
- [ ] コードレビューを許可モデルの範囲で行い、各指摘を修正または根拠付きで解決する。
- [ ] docs: record iOS release evidence and remaining device checksとして結果を保存する。

## 仕様の対応表

| 仕様 | 対応Task |
| --- | --- |
| 初回体験・撮影・取り込み | 1, 3, 7 |
| 音源解析・3アレンジ・元音比較・もうひとつ | 4, 5, 7 |
| 映像3レイアウト・字幕・同期 | 6, 7, 8 |
| 保存・下書き・容量・参照管理 | 2, 8 |
| 共有・リミックス | 9 |
| 蓋/飲み口・クリップボード・テレビ・触り心地 | 7 |
| 権限・割り込み・復旧・アクセシビリティ | 3, 6, 7, 8, 10 |
| 内蔵お題 | 7のつくる画面にローカル定義として配置。ネット接続・通知義務なし |
| 将来Android転用 | Domain/recipeの非依存化、iOS境界。Android実装は今回の対象外 |
| 音映像連動エフェクト | 将来機能。原本保持とrecipe/manifestの版で拡張性を確保 |
| 課金 | 仕様上の候補。初版コア検証で課金を必須にせず、価格や商品登録は別途判断 |

## レビューと実行方法

ユーザーはLuna/maxとSol/mediumの利用を許可している。並列作業は独立した範囲に絞る。
音と映像の共通契約は先に確定し、依存する実装を勝手に別々の型で進めない。
この計画のレビュー後に実装を開始する。将来Androidを見越した過剰な抽象化より、iOSでの正確な媒体処理と使用感を優先する。
