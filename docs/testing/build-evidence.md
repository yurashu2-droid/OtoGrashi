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

## 音声解析・編曲・音声出力 — 2026-09-22

- 対象commit: `3c495649e29ec52ddec1c7353b97e7a2a74a4b40`
- [GitHub Actions実行結果](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/35706593305): success
- Flutterテスト29件、静的解析、unsigned iOS Simulatorビルド、Swiftテスト26件（解析12・出力14）が成功。
- CI成果物の `audio-render-fixture.wav` / `audio-render-report.json` を取得して確認。48kHz・mono、ファイル長と実読込数はいずれも720,000、非有限値0、peak約0.92。途中の短い読み込み後に最後の128サンプルが返るため、一回の読込長をファイル全体長とみなさない。
- 書き込み後の明示的closeと、ファイル長を上限とする分割読込で検査。EOFを越えた読込エラーも修正。
- AACの圧縮パケット境界は固定の正解値にせず、元動画の時刻と既知の音の位置で検証。正確なPTS配置は別の合成PCMテストでも検証。
- 素材は自作の合成テスト動画。実際の生活音30種類の聴き心地、iPhoneの録音・Bluetooth・触覚・映像同期、TestFlight配布は未確認。
- 動画合成と全画面フローは引き続き実装中。この成功はアプリ全体の完成を意味しない。
