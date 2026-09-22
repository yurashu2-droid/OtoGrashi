# オトグラシ / OtoGrashi

いつもの物を3つ撮ると、その音でできた、自分の15秒が生まれる。

## 現在の状態

設計・実装計画のレビュー段階です。まだアプリコード、CIワークフロー、TestFlightビルドはありません。
Flutterで画面と主要ロジックを作り、iOSで録音・動画処理を検証する方針です。
Androidへの再利用は考慮しますが、初版のビルド・実機テストはiOSのみです。

- [製品・体験・技術設計](docs/superpowers/specs/2026-09-21-otogurashi-ios-design.md)
- [実装計画](docs/superpowers/plans/2026-09-22-otogurashi-ios-implementation.md)
- [ビルド・TestFlight構成メモ](docs/delivery/build-environment.md)
- [UI方向性の参考画像](docs/design/approved-direction-reference.png)

![UI方向性](docs/design/approved-direction-reference.png)

サウンドと映像がセットで変わるエフェクトは初版後の追加機能です。
サブエージェントはユーザー許可のLuna/maxとSol/mediumに限定します。
