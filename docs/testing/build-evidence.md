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

## iLoader向け署名なしRelease IPA — 2026-09-23

- 対象commit: `c03e1eeba2274fe68d5540522acc6f13c977e1fa`。
- [IPA生成ジョブ](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/35805467269): success。
- [Artifacts: OtoGrashi-unsigned-ipa](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/35805467269/artifacts/10727307429)（約47.4MB、保持期限2026-10-07 UTC）。
- `xcodebuild archive` / Release / generic iOS device / arm64 が成功。`CODE_SIGNING_ALLOWED=NO`、空のTeam ID・署名Identityで実行。
- 仮Bundle ID `dev.yurashu2.otogurashi`、iPhoneOS、arm64、アプリ本体の `_CodeSignature` と `embedded.mobileprovision` の不在をスクリプトで確認。
- `Payload/Runner.app` を `OtoGrashi-unsigned.ipa` に梱包し、`unzip -tq`成功。IPAのSHA256、commit、build情報、dSYMをArtifactsに同梱。
- Apple ID・証明書・秘密鍵・Provisioning Profile・App Store Connect認証情報を登録・使用していない。TestFlightへのアップロードは行わない。
- Flutter側は今回の機能変更時点で静的解析成功、75テスト成功（任意の画像取得テスト1件skip）。Swift修正後はCIでReleaseコンパイルを確認。
- 初回は比較再生のSwift引数ラベル、次回は梱包前のlipo引数順で停止。上記成功commitで両方を解消。
- これは途中版の実機テスト用IPA。iLoader署名・インストール、iPhone録音・音質・触覚は未確認。共有・リミックスは未完成。HDR合成fixtureのSimulator読み込み失敗は別の未解決項目として残る。
- 同一アプリコードのSimulator検証は[別ジョブ](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/35805210387)で実行中。IPA生成成功を全ネイティブテストの成功とは扱わない。
