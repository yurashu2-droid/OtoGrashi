# ビルド環境と実機配布

2026-09-23更新。配布方式は[署名なしRelease IPA → WindowsのiLoader](unsigned-ipa.md)。以前のTestFlight案を置き換える。

- Flutter stable 3.47.5 / Dart 3.13.4。
- GitHub Actions macos-26、Xcode 26.6 (`/Applications/Xcode_26.6.app`)。
- iOS最低バージョン18.0。Androidのビルド・実機テストは今回含まない。
- 仮Bundle ID `dev.yurashu2.otogurashi`、Team IDは空欄。

`ios-check.yml`は静的解析・Flutterテスト・署名なしSimulatorビルド・ネイティブテストを行う。
`unsigned-ipa.yml`は実機向けRelease archiveを `CODE_SIGNING_ALLOWED=NO` で作り、`Payload/Runner.app` をIPAに梱包してArtifactsに置く。

署名に関するApple認証情報や証明書をCIへ渡さない。iPhoneへの署名・インストールはWindowsのiLoader側で行う。
TestFlight対応はApple Developer Program加入後の別作業。

実行ごとの検証範囲と結果は[検証記録](../testing/build-evidence.md)を参照。Simulator成功を実機録音・音質・触覚の確認済みとは扱わない。
