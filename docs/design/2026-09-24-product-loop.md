# オトグラシ：体験の核と改善ループ

## 核

**友達のリアクションや生活音を撮ると、見慣れた場面が少しずつ重なり、気づけば笑える15秒の曲とMAD的な動画になる驚き。**

最初の成功は「3素材を集める」だけではない。自分の音を聴き比べ、完成動画を端末へ保存するか人に渡せた時点。制作の専門知識より、身近な物をもう一つ撮りたくなる好奇心を優先する。

体験の輪は **撮る → 集める → 変化を聴く → 保存・共有 → また撮る**。画面・文言・装飾・派生機能は、この輪を速く、明快に、楽しくするかで採否を決める。

## 現状の摩擦

- 外側の3タブとライブラリ内の2タブで「作品」「音の引き出し」が重複し、どこにいるか分かりにくい。
- 曲ができても「元の音との差」が主役にならず、変化の驚きが弱い。
- 完成画面の保存・共有が操作できず、価値を持ち帰れない。
- 実物モチーフの枠はあるが、日常動画の軽さや投稿したくなる編集感が不足している。
- 撮影した動画の名前がファイル名になり、集めた音のコレクションとして見えにくい。

## 方向の比較

1. **いまの道具モチーフを磨く**：撮影の蓋、素材のクリップボード、再生のテレビを精緻化。既存設計と整合するが、動画より枠が主役になりがち。
2. **音の採集ノート（採用）**：実物の痕跡を付箋・紙片・手書きの擬音として添える。動画を大きく残し、編集の楽しさを伝える。道具そのものを別の操作体系にはしない。
3. **キャラクター中心**：マスコットが集音を案内。記憶には残るが、まず自分の動画と音が主役になるべき段階では価値が薄い。

## アートディレクション v1

参照画像: [音の採集ノート](sound-diary-direction-v1.png)。ImageGenで生成した検討用画像で、UI仕様そのものではない。プロンプトの要点は「3つの日常音の動画、ビフォー／アフター、完成・共有を3画面に並べ、setlogや短尺動画の手書き編集感、暖色の紙、コーラルと薄紫、実写優先、実装可能なタップ領域。高級感・ガラス表現・全面的な道具の枠・架空機能・重複ナビゲーションを避ける」。

実装で使うのは、太めの日本語見出し、淡い紙色、短い手書き風の線や音のラベル、コーラルの主操作、実写サムネイルが中心のカード。画像の文言やSNS専用ボタンは写さない。スマホの安全領域、実際の素材数、権限状態に合わせる。

第1回の画面確認: [素材を集める](iteration-1-collect.png) / [聴き比べる](iteration-1-arrange.png) / [完成](iteration-1-complete.png)。これらは合成素材で撮ったFlutter画面であり、実機の動画サムネイル、iOSアイコン、写真への保存結果を示すものではない。確認で発見した「主操作が画面外に隠れる」「前画面のスクロール位置が残る」は修正した。

## 最初の改善単位

1. ナビゲーションを「つくる／ライブラリ」に整理し、ライブラリ内だけで「作品／素材」を切り替える。音づくり・完成時は制作へ集中できるよう下部ナビゲーションを隠す。
2. 素材一覧を「3つの音を採集する」画面として整え、実写・素材数・主操作の優先順位を明確にする。サンプル・ファイル名などの開発都合の露出は抑える。
3. プレビューで元の音と完成曲を同格に聴き比べられるようにする。再生成と詳細調整は二次操作に置く。
4. 完成動画の高品質書き出し、写真への保存、iOS共有シートを使えるようにする。書き出しは必要になった時だけ一度行い、成功したものだけ作品へ記録する。
5. 現実の3本を使った実機確認で「最初の完成動画を持ち帰れるか」を評価し、次の修正を選ぶ。

追加エフェクト、マスコット、公開フィード、リミックスの拡張は、この一周の実機評価後に判断する。サウンド／ビデオが同期するエフェクトは既定どおり後続機能。

## 第2回：曲に「なっていく」映像

ユーザーが重視するのは日常風景を常時3段で並べた動画ではなく、友達の反応、タイピング、コップなどの断片が音とともに展開する意外性。目標を「制作できる」から「一緒に見て笑え、SNSへ渡したくなる」に具体化する。

参照画像: [映像のビルドアップ](remix-build-up-storyboard-v1.png)。ImageGenの `ui-mockup` で作成した4コマの方向確認。プロンプトは、同じ3本の実写素材をフル画面の単独映像から2本、3本の画面へ増やし、手書きの擬音と淡いコーラル／紫を拍のアクセントとして添える、setlog／短尺MAD風の縦動画。これはタイミングと構図の参照であり、生成画像を動画素材として埋め込むものではない。

使用プロンプト（built-in ImageGen）:

> ui-mockup. Create one horizontal design-reference image showing FOUR successive frames of a 15-second vertical social video inside four separate true 9:16 smartphone-screen rectangles, laid out left to right as a storyboard. This is for a Japanese casual music-making app called オトグラシ. Candid real-life source footage: a friend’s spontaneous surprised 'わぁ!' reaction, hands typing on a laptop, and a ceramic cup set on a table. Beat 1: friend reaction fills the entire vertical video. Beat 2: typing fills the video. Beat 3: two videos appear at once, with the friend in the larger upper lane and the cup as a repeating rhythm strip below. Beat 4: three videos form a lively but readable composition, friend reaction and typing in top half side by side, cup as bass loop across bottom half. Brief doodled handwritten Japanese onomatopoeia and tiny coral/lavender rhythmic accent marks, scrapbook/setlog/TikTok edit energy, warm real footage, clearly still practical in-app vertical video frames. Keep the video itself the hero. NO actual app chrome, buttons, status bars, phone bezel, permanent decorative cup frame, slick futuristic neon, generic gradient, stock-photo polish, or mascot. Each frame should feel like the same 3 videos re-edited as the music builds. High-resolution concept storyboard, legible visual structure; text accuracy not essential.

標準の動画レイアウトを `buildUp` にする。最初の3小節で各素材を全画面で見せ、4〜5小節で2本、6小節目以降で3本を同時に見せる。先頭素材を下段の大きめの帯で短くループさせ、別の素材が上に増える。既存の「3段」「順番に大きく」「フォトダンプ」は選択肢として維持する。作品一覧から完成動画を再生・保存・再共有できるようにし、素材には名前を付けられるようにする。

次に検証する仮説は、拍に合わせた一部映像の複製・反転、声や短い音のピッチを安全な範囲で変えること、MIDI的な旋律テンプレートに音を当てること。音の元が認識できる楽しさや書き出しの安定性を実機で確かめてから、どれが本当に共有したくなる変化を作るか選ぶ。ピッチ／MIDIを必須要件とはしない。

生成レシピを見直すと、後半の2〜3本表示は固定順で、実際に鳴っている素材と合わない小節があった。後半はその小節の音イベントを優先して映像素材を選び、未紹介の素材も順に登場させる。先頭素材の短い映像ループは画面の軸として維持する。

音が検出できずアレンジから除かれた素材は、最初の全画面紹介にも使わない。4〜6本を集めた時に無音素材が先頭にあっても、曲に採用された3本から映像を始める。

短い音イベントをそのまま動画の長さにすると、全画面の導入が数フレームで停止してしまう。導入3場面では元動画を各小節の間再生し、後半は音に合わせた短い映像反復へ移る。CIのプレビュー書き出しを標準の `buildUp` レイアウトと異なる3素材に変え、冒頭・中盤・終盤のフレームを検査する。

iOS CIの診断では、54件中52件が通過した。長尺元動画の短い選択範囲テストは、AVAssetReaderが45秒開始指定より前のデコード用フレームまで返し、タイムスタンプ一覧へ混入したことが原因。読取範囲で結果を絞る。もう1件はiPhoneシミュレーターがHEVC Main 10のHDRテスト素材をAVAssetImageGeneratorでデコードできないエラー `-11821`。回転VFR素材は正常にSDR/30fpsへ書き出せた。HDRについてはシミュレーターでのみ能力不足としてスキップし、実機のHDR素材で書き出しを確認する。
