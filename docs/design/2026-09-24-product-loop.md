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

修正後のiOS CIは54件成功・1件スキップ・失敗0件。実際に書き出した15秒の縦動画から、[1本目の全画面](iteration-2-intro-a.png) → [2本目の全画面](iteration-2-intro-b.png) → [2本の重なり](iteration-2-duo.png) → [3本の重なり](iteration-2-trio.png)を確認した。同じ全画面場面内でも0.5秒と1.5秒のフレームで被写体が移動し、短い音の後に静止画になっていない。これらは構図と再生を検査するための単純な合成素材であり、実写の見栄えや友達と見たときの面白さを示すものではない。次はiPhoneで実写3本を使い、音と映像の一致、保存・共有、HDR素材を確かめる。

## 第3回：音の位置が見える短いアクセント

映像が1本から複数本へ増えるだけでは、どの断片が今の音か瞬時に伝わりにくい。標準の `buildUp` 書き出しに限り、実際の音イベントの開始から0.2秒、該当素材の映像内に小さな3本の線を描く。白い縁で実写上の視認性を保ち、コーラルと薄紫を交互に使う。映像を覆う枠や常時表示の装飾は増やさない。これは編集表現であり、後続のユーザー選択式サウンド／ビデオエフェクトとは別に扱う。

ネイティブCIは54件成功・1件スキップ・失敗0件。[音の入り](iteration-3-rhythm-on.png)と[約0.27秒後](iteration-3-rhythm-off.png)の書き出しフレームを比較し、対応する映像の中で短く点灯して消えることを確認した。合成素材での見え方なので、強さや楽しさの判断は実写と実機で行う。

初回画面も抽象的な丸では撮る対象や完成物が伝わらなかったため、ImageGenで[日常の3場面を切り貼りした画像](../../assets/art/onboarding-moments-v1.webp)を作成し、友達の「わっ！」・タイピング・コップの例を文言にした。[390×844の描画確認](iteration-3-onboarding.png)では画像・説明・主ボタンが一画面に収まる。この画像は体験を示す挿絵で、ユーザー素材や完成動画のサンプルではない。

使用プロンプト（built-in ImageGen、`photorealistic-natural`）:

> Create a single landscape 3:2 image for the first screen of a Japanese iPhone app that turns everyday videos into a 15-second rhythm video. Three candid moments: an adult friend reacting with an open-mouthed delighted laugh, hands typing on a laptop, and a ceramic cup being set on a home table. Make a cohesive collage of three readable uneven film frames; the friend is largest. Warm natural light, believable handheld smartphone footage, lived-in Japanese apartment, cream paper gaps, subtle coral and lavender hand-drawn beat marks. Compose for a rounded 1.55:1 crop. No words, logos, watermarks, UI buttons, phone bezel, gradients, neon, mascot, or cup-shaped border.

## 第4回：拍ごとに増える映像と本物の波形

[増殖と波形の絵コンテ](remix-rhythm-storyboard-v2.png)をImageGenで作成。音の反復に合わせて上段の素材を1枚→2枚→4枚へ分割し、複製の一部を左右反転する。先頭素材の下段ループは維持する。短い波形は合成した音声ファイルから実測した振幅を使い、音の入りから約0.6秒だけ表示する。小さな線だけでは伝わらなかった「何が鳴っているか」「音が重なる楽しさ」を映像の動きとして見せる。

持続音の音程が変わる瞬間は複製の向きも一時的に切り替え、音と映像の変化を同じイベントへ結びつける。音程の範囲、原音との混合、旧レシピ互換は[音声設計メモ](2026-09-24-audio-melody.md)に記録する。これは音声全体をMIDI音源へ変換する機能ではなく、元の場面が分かる範囲の小さな旋律付けである。

iOS CIは55件成功・1件スキップ・失敗0件。[音の入り](iteration-4-one.png) → [次の拍](iteration-4-two.png) → [さらに増えた拍](iteration-4-four.png) → [別素材が重なる場面](iteration-4-mixed.png)を合成素材の書き出しで確認した。波形は音量によって変化し、素材の複製は一つの映像領域の中で進む。合成素材は左右対称に近いため反転の楽しさと音質は評価できない。iPhoneで友達のリアクション・タイピングなどの実写と声を使って確かめる。

使用プロンプト（built-in ImageGen、`ui-mockup`）:

> Four successive 9:16 frames of a 15-second vertical video using the same candid footage: a friend's delighted reaction, typing, and a cup tap. Begin with a full-screen friend and a small live waveform; then full-screen typing. Next the friend loops in a bottom bass lane while typing on top splits into two copies on a sound hit, one mirrored. Finally the upper half repeats keyboard moments with cup footage, some mirrored, with a short coral waveform following the sound. Warm real handheld footage and casual setlog/TikTok scrapbook energy; no app chrome, phone bezel, neon, mascot, permanent frame, words or captions.

## 第5回：途中の音に戻る

3つの音を別々の時間に集めても制作が続くよう、起動時に保存済み作品を確認する。未完成の作品があれば更新日時が新しいものを開き、完成作品だけならライブラリを開く。作品がない初回だけ導入画面を出す。撮影を選ぶまではカメラ権限を求めない。実データベースで初回・途中再開・完成後の3経路を確認した。実機では、アプリを閉じて再起動した時の素材の見え方を確かめる。

## 第6回：撮った音を採用する手応え

録画操作とインカメ切替を同じ行に置き、撮影後は再生・撮り直し・採用を画面下に固定した。390×844の描画で両方の操作が見えることを確認した。採用後の動画コピー中も確認画面に留まり、進捗を示して重複操作と途中の戻る操作を防ぐ。作品へ追加できた時だけ一時動画を破棄して短い触覚フィードバックを返す。失敗時は一時動画を残し、同じ動画の再試行・撮り直し・別の動画の選択を可能にする。次の実機確認では、撮影→プレビュー→撮り直し→採用の流れと、追加中の待ち時間を評価する。

## 第7回：音が鳴る映像へ

実写3本による実機評価で、音と映像のずれ、長い無音、見た目だけの反転・複製、撮影画面の狭さが報告された。コード上でも、最初の3小節は1小節1音のみで、音がない時間に動画だけが進んでいた。後半の下段動画は音と無関係に反復し、複製数は過去の音イベント数だけで増えていた。音の開始点が検出できない素材はランダムな位置を使っていた。

今回の修正では、導入を各素材2→3→4拍の反復にし、後半の下段素材も2拍ごとに実際に鳴らす。声など鋭い立ち上がりがない素材には、解析した音量の強い位置を開始候補として渡す。音がある映像イベントの素材時刻を優先し、同時に鳴る声の数だけ映像を複製する。左右反転は対応する逆再生音を実装するまで外す。撮影プレビューは広げ、収録時間は整数秒への切り捨てをやめる。冒頭に1.5秒だけ出る「ひとこと」のボタンは外し、素材名の編集は素材一覧で続ける。

次の音質改善候補は優先順に次の通り。

1. 実写の発声・物音を使い、音声区間の開始と終わりを解析して、取り出した断片を波形で確認・調整できるようにする。現在の音量最大点だけでは語尾や短い反応全体を保証できない。
2. 各テンプレートの拍密度と音量を耳で評価し、音のない間を意図的な休符と区別する。実際に重ねる音と複製映像を同一イベントから生成する。
3. 音程のある素材だけ基音を推定し、選べる旋律と調に合わせる。現状は持続音の相対的な±3半音移動だけで、MIDI的なメロディ制作は未実装。
4. 素材名を動画内でテンプレート別に表示する。名前の編集と再生中の見え方を先に確かめ、文字変更だけで全音声を再解析・再合成しない経路を作る。
5. 長押し録画と発話後の自動停止は、短い声の採集に適するか実機で試す。誤停止を避けるため音量だけで即停止しない。

この修正の合成テスト・CIは音楽的な気持ちよさを証明しない。新しいIPAで実写の音と動画を聞き比べ、無音、同期、ループの気持ちよさを再評価する。

待機中の次の改善では、解析結果に「音が続いている区間」を追加し、最も聞こえやすい区間からイベントを切り出す。区間が短い時はイベントも短くして、無音の語尾を長く並べない。区間情報がない旧解析データは従来の開始候補へ戻す。音づくり画面から素材名を直接変更できるようにし、名前変更では音声の解析・動画の書き出しを始めない。テンプレート別の動画内ラベルは引き続き別の設計課題とする。
