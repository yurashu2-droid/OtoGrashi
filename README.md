# オトグラシ / OtoGrashi

友達のリアクションや身近な物音を撮ると、日常の動画が少しずつ重なり、元の場面が分かるまま15秒の曲になる。

## 現在の状態

FlutterとiOSネイティブ処理で実装中です。撮影・取り込み、編曲、聴き比べ、15秒動画の生成、写真への保存、iOS共有シートがあります。標準の動画は素材を1本ずつ紹介した後に重ね、音の反復に合わせて複製・反転し、実際の音量から作る短い波形を表示します。持続音には元の音を残した小さな音程変化を加えます。実写素材での音質、保存・共有、HDR素材はiPhone実機で確認する段階です。
実機確認にはGitHub Actionsの署名なしRelease IPAをダウンロードし、WindowsのiLoaderで署名・インストールします。TestFlight対応は後日です。
Androidへの再利用は考慮しますが、初版のビルド・実機テストはiOSのみです。

- [製品・体験・技術設計](docs/superpowers/specs/2026-09-21-otogurashi-ios-design.md)
- [体験の核と改善ループ](docs/design/2026-09-24-product-loop.md)
- [実装計画](docs/superpowers/plans/2026-09-22-otogurashi-ios-implementation.md)
- [iLoader向けIPAのダウンロード方法](docs/delivery/unsigned-ipa.md)
- [ビルド環境](docs/delivery/build-environment.md)
- [UI方向性の参考画像](docs/design/approved-direction-reference.png)

![UI方向性](docs/design/approved-direction-reference.png)

サウンドと映像がセットで変わるエフェクトは初版後の追加機能です。
サブエージェントはユーザー許可のLuna/maxとSol/mediumに限定します。
