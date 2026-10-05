# Trim video preview Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the range editor feature; the parent prepares Cloudflare deployment independently.

**Goal:** 音の範囲を映像と一緒に選び、共有サーバーの初回公開を準備する。

**Architecture:** 共通のトリムシートで既存 NativeMovieView と MediaPlaybackController を使う。連続 seek は画面内でまとめ、確定まで保存しない。Cloudflare の手動 workflow は source_ref を取得し、既存の公開スクリプトへ認証を渡す。

**Tech Stack:** Flutter, iOS AVPlayer, GitHub Actions, Cloudflare Workers/R2.

**Spec:** `docs/superpowers/specs/2026-10-05-trim-video-preview-design.md`

## Constraints and review focus

- Windows の flutter_tester は WDAC で実行不可。ローカルは型・静的解析、実行テストは必要な範囲を macOS CI でまとめる。
- 連続ドラッグ時の古い seek、素材切り替え時の音漏れ、シートを閉じた後の非同期処理、小さいiPhoneの表示、保存失敗時の復帰を確認する。
- Cloudflare トークンはログ・アプリ・ソースへ含めない。認証登録待ちでも UI 作業は進める。

## Task 1: Video-backed range editor

- [x] `lib/features/create/clip_card.dart` と呼び出し元へ presentation を渡し、元動画の同時プレビュー・境界 seek・範囲試聴・時刻表示を実装する。
- [x] `lib/features/arrange/adjustments_sheet.dart` の範囲選択も共通の動画付きシートへ接続する。
- [x] 連続 seek と再生停止の重要な状態管理だけを対象に既存テストの活用／必要な関連テスト追加を行う。
- [x] 差分と静的解析を確認し、関連変更をまとめてCI・実機向けIPAを実行する。初回に発見した初期位置と進捗の読み上げエラーを修正して再ビルド。後続のテスト環境・CI条件だけの修正ではIPAを作り直していない。

## Task 2: Discoverable Cloudflare deployment

- [x] `.github/workflows/shared-folders-deploy.yml` に source_ref と未登録資格情報の明確な検出を加える。
- [x] 同じ実行入口だけを main へ登録し、バックエンドは開発ブランチから取得する。main の登録コミットは `6eb859b086c7ba0beabaf6cf1f8ae20cf3090692`、GitHub 上のファイル内容と Actions 登録を確認済み。
- [x] `docs/shared-folders-deploy.md` を更新する。
- [ ] 非公開R2・Workerの実公開と接続確認は API トークンの登録待ち。PC の Wrangler は未ログイン、GitHub の `CLOUDFLARE_API_TOKEN` は未登録。ユーザーへ R2 の利用開始、対象アカウントに絞った管理トークンの3権限、GitHub Secret の登録先を案内済み。資格情報なしで公開は実行していない。

## Verification / limits

- 全体の `flutter analyze --fatal-infos` は問題なし。
- 手動 deploy workflow は YAML パーサーで入力・checkout・資格情報ガード・manual-only を確認済み。
- 選択範囲の終了停止は既存の100ms再生状態ポーリングで行うため、停止は厳密なサンプル単位ではなく、約1ポーリング間隔とブリッジの遅延があり得る。実際に使う範囲の保存値は変更しない。
- iPhone の実表示と手触りは IPA の実機確認が必要。

## Completed evidence

- アプリコード `a004820ca3f22bafcd41185bad13b6d00180e119` の [署名なし Release IPA](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/37316336816) は成功。後続変更はテスト・CIのみでアプリコードは同じ。
- Downloads の `OtoGrashi-trim-video-a004820.ipa` は 9,671,251 bytes。生成元コミット、artifact の SHA256 と一致し、`Payload/Runner.app`、開発用 Bundle ID `dev.yurashu2.otogurashi`、build 95 を確認した。
- SHA256: `61b09bc5bec4010640a0840210bd6b8a4386c8557cc8188a5db5fcbf3756dd49`。
- [最終CI](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/37317500101) は全体の静的解析・範囲再生に関する3件の回帰チェックとも成功。先行する関連画面・保存・既存再生の47件は成功し、無関係なネイティブ描画テストを増やしていない。
- test-only の実行でもネイティブ描画ファイルを要求していた既存の CI 条件を修正した。
