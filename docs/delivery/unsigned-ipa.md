# WindowsのiLoaderで実機へ入れる

2026-09-23の配布方針。RakugakiMapと同じく、GitHub Actionsでは署名なしの実機向けRelease IPAを作り、WindowsのiLoaderで利用者が署名してインストールする。

## ダウンロード

1. GitHubの **Actions → iPhone unsigned Release IPA** を開く。
2. 対象ブランチの成功した実行を選ぶ。手動起動する場合は **Run workflow** でブランチを選ぶ（workflowがデフォルトブランチに入るまでは対象ブランチへのpushで起動）。
3. 実行ページ末尾の **Artifacts → OtoGrashi-unsigned-ipa** をダウンロードしてZIPを展開する。
4. **OtoGrashi-unsigned.ipa** をWindowsのiLoaderへ渡し、iLoader側で署名してiPhoneにインストールする。

`commit.txt` と `build-info.txt` で対象コードとビルド番号を確認できる。`SHA256SUMS.txt` と `dSYMs.zip` も同梱する。Artifactsの保持期間は14日。

## ビルド内容

- Flutter 3.47.5 / Xcode 26.6 / macos-26。
- `xcodebuild archive`、Release、`generic/platform=iOS`、iPhoneOS arm64。
- `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、空の署名Identity・Team ID。
- 開発用の仮Bundle IDは **dev.yurashu2.otogurashi**。
- archive内の `Runner.app` を `Payload/Runner.app` にコピーしてZIP形式のIPAへ梱包する。`-exportArchive`やAppleへのアップロードは使わない。
- 梱包前に実機向けarm64、Bundle ID、署名・Provisioning Profileの不在を確認する。

Apple ID、証明書、秘密鍵、Provisioning ProfileをリポジトリやGitHub Actionsに登録する手順はない。GitHubの署名用SecretsやApple認証用Environmentも不要。

## 最初の実機確認

アプリ起動 → カメラ・マイク許可 → 3素材を撮影 →「この音でつくる」→ 再生を確認する。
機種、iOS、`build-info.txt`のBuild、失敗した操作を記録する。合成サンプルでの確認と実際の生活音の確認は分ける。

IPA生成成功は実機へのインストールや録音・再生の成功を意味しない。署名とインストールはiLoader側で確認する。

TestFlight用の正式Bundle ID・Team ID・App Store Connect設定はApple Developer Program加入後の別対応とし、今回のworkflowには含めない。
