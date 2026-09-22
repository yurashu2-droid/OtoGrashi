# ビルドと配布の準備

2026-09-22確認。これは実装計画用の構成メモで、ワークフローはまだ未作成。

## 固定する環境

- Flutter stable 3.47.5 / Dart 3.13.4
- Flutter commit: 6a19cca56475dbfba1478ee68d7bd0c2ef891da1
- macOS arm64 SDK archive SHA256: d4dd908b5f8f65515831b6d68ae33307a813f2b68947dded7a1994ee5ea7cead
- GitHub Actions: macos-26を第一候補とする。実装時にrunnerで実在するXcodeパスとarchitectureを再確認して固定。
- Xcode候補: /Applications/Xcode_26.6.app。存在しなければ黙ってdefaultに切り替えず、対応する環境へ明示更新する。
- 依存のlockfile、使用SDK・runnerイメージ・commitを記録する。

公式FlutterリリースJSONから親エージェントも版とハッシュを確認した。
runnerイメージは更新され得るため、文書の候補と実行時の結果を区別する。

## 2種類のワークフロー

1. ios-check: PR/pushの解析・テスト・unsigned Simulatorビルド。署名用Secretsを参照しない。
2. testflight: workflow_dispatchによる署名配布。GitHub Environmentの秘密情報をこのジョブだけで使用する。

Androidビルド・Androidエミュレータ・Playストア配布は今回含めない。

## 接続時に確認する非秘密の値

IOS_BUNDLE_ID / APPLE_TEAM_ID / IOS_SCHEME / TESTFLIGHT_GROUP。
現時点で未提供。署名のない検証はこれらの実運用値がなくても進められる。
既存アプリの情報を確認してから配布に接続する。

## GitHub Secretsの候補名

BUILD_CERTIFICATE_BASE64 / P12_PASSWORD / BUILD_PROVISION_PROFILE_BASE64 /
KEYCHAIN_PASSWORD / ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_BASE64。

既存方式がある場合はその命名と仕組みを維持する。値をチャットやリポジトリへ入れない。
署名証明書は一時Keychainに読み込み、ジョブ終了時に削除する。

## 検証とアップロード

flutter analyze、flutter test、flutter build ios --simulator --debugから始める。
iOS統合テストは、実際に起動したSimulatorのUDIDを指定する。
署名配布はflutter build ipa --release --export-options-plistでarchive/exportし、
既存のアップロード手段があればそれを使う。なければXcode付属のアップロード手段を採用する。
Appleへのアップロード完了と、TestFlightで使える状態は分けて報告する。
実機録画・音質・触覚・発熱はSimulatorで確認済みとしない。

## 参照

- [Flutter SDK archive](https://docs.flutter.dev/install/archive)
- [Flutter macOS releases JSON](https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json)
- [GitHub macOS 26 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)
- [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios)
- [GitHub signing guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Apple upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
