# 検証記録

## 初期iOSビルド — 2026-09-22

- 対象commit: `edc69e93534f78a3e63b3ad3d7c0b35e7f0b620f`
- [GitHub Actions実行結果](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/35692465338): success
- macos-26 / Xcode 26.6 (17F113) / Flutter 3.47.5 / Dart 3.13.4
- 成功した範囲: 依存解決、静的解析、日本語初期画面のWidgetテスト1件、unsigned iOS Simulator debug build。
- これは初期画面のみの検証。録音、編曲、動画出力、端末の音質・同期・触覚、TestFlight配布の合格を意味しない。
- Bundle ID / Apple Team IDはユーザー回答で未決定。`com.example.otogurashi`はSimulator検証用。

以降の変更については、対象commitとチェック範囲を分けて追記する。

## 保存基盤のiOSビルド — 2026-09-22

- 対象commit: `26bd9e27966ef8767e39cd58126d8df5d0469bc7`
- [GitHub Actions実行結果](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/35693845585): success
- SQLite依存を含む静的解析、Flutterテスト11件、unsigned iOS Simulatorビルドが成功。
- レビューで空タイトルと素材メタデータ読み出しAPIの修正を要求。ビルド成功はレビュー指摘解消の代わりにはしない。
