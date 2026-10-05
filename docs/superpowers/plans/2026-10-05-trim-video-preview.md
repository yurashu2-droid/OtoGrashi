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
- [ ] 差分と静的解析を確認し、関連変更をまとめてCI・実機向けIPAを一度実行する。

## Task 2: Discoverable Cloudflare deployment

- [x] `.github/workflows/shared-folders-deploy.yml` に source_ref と未登録資格情報の明確な検出を加える。
- [x] 同じ実行入口だけを main へ登録し、バックエンドは開発ブランチから取得する。main の登録コミットは `6eb859b086c7ba0beabaf6cf1f8ae20cf3090692`、GitHub 上のファイル内容と Actions 登録を確認済み。
- [x] `docs/shared-folders-deploy.md` を更新する。
- [ ] トークンが登録された場合は非公開R2・Workerを公開し、実際のURLで接続を確認する。未登録の場合は必要な初回設定を明示する。

## Verification / limits

- 全体の `flutter analyze --fatal-infos` は問題なし。
- 手動 deploy workflow は YAML パーサーで入力・checkout・資格情報ガード・manual-only を確認済み。
- 選択範囲の終了停止は既存の100ms再生状態ポーリングで行うため、停止は厳密なサンプル単位ではなく、約1ポーリング間隔とブリッジの遅延があり得る。実際に使う範囲の保存値は変更しない。
- iPhone の実表示と手触りは IPA の実機確認が必要。
