# 共有フォルダ API の公開

Cloudflare の管理 API トークンを GitHub の Repository secret に登録し、手動 workflow を実行すると、非公開 R2 バケットの準備と Worker / Durable Objects の公開をまとめて行います。

## 初回の設定

1. Cloudflare の対象アカウントで R2 を有効化してください。R2 の利用開始・支払い方法登録はダッシュボードで行います。このスクリプトは課金の有効化を行いません。Workers のアカウント用 `workers.dev` サブドメインも設定しておいてください。
2. 対象アカウントだけに範囲を絞った **API Token** を作ります。権限は Account → **Account Settings: Read**、**Workers Scripts: Edit**、**Workers R2 Storage: Edit**。Account Settings Read はアカウントの検出・確認に使用します。ゾーン権限は現在の `workers.dev` 公開では不要です。
3. GitHub リポジトリの Settings → Secrets and variables → Actions に `CLOUDFLARE_API_TOKEN` を Repository secret として登録します。R2 の S3 access key / secret や Global API Key とは別の資格情報です。アプリやソースコードには保存しません。
4. トークンから見えるアカウントが 1 つなら自動選択します。複数ある場合は同じ画面の Repository variable（または secret）`CLOUDFLARE_ACCOUNT_ID` に対象アカウントの 32 桁 ID を設定してください。複数候補から勝手に選択しません。
5. Actions → **Deploy shared folders** → **Run workflow** を開き、**source_ref** に公開するコードのブランチまたはコミットを指定します。現在の開発ブランチは `claude/video-styles` です。実行入口の workflow はデフォルトブランチの `main` にも置き、バックエンドのコードは source_ref から取得します。push / pull request からは公開されません。Summary に実際に取得したコミットが残ります。

成功すると Actions の Summary と `shared-folders-deployment-info` artifact 内の `deployment-info.json` に HTTPS URL が出ます。アプリの「みんなの音」から、この URL をサービスのアドレスに設定してください。ビルド時に固定する場合の変数名は `OTO_SHARED_API_URL` です。artifact にトークンは含まれません。

パスキーはこの HTTPS ドメインに紐づきます。友だちに公開した後は、Worker 名やドメインを気軽に変更しないでください。ドメインの変更だけでは既存のパスキーは移りません。Cloudflare の API トークンをアプリへ渡す必要はありません。

## 処理内容

`backend/shared-folders/wrangler.jsonc` の現在の設定を読み、バインディング・Durable Object マイグレーションをそのまま公開します。設定された R2 バケットがなければ作成し、あれば再利用します。公開 `r2.dev` が有効、またはカスタムドメインが 1 つでも付いているバケットは拒否します。非公開状態を API で確認できない場合も停止します。既存バケットやデータの削除、公開設定の変更は行いません。

生成設定と公開情報は gitignore 対象の `backend/shared-folders/.wrangler/` に保存します。追跡される設定ファイルは変更しません。Wrangler は `package-lock.json` で固定されたローカル依存を使います。失敗時は資格情報保護のため API の応答本文や Wrangler の出力を表示せず、HTTP ステータスまたは終了コードを報告します。アカウント・権限・R2 有効化を確認して再実行してください。途中で作成された非公開バケットは残り、次回再利用できます。

## ローカル実行

`backend/shared-folders` で `npm ci` の後、環境変数 `CLOUDFLARE_API_TOKEN`（必要なら `CLOUDFLARE_ACCOUNT_ID`）をセッションに設定して `npm run deploy` を実行します。トークンを引数や履歴に直接貼り付けず、ローカルの秘密管理から環境変数へ渡してください。

資格情報なしの確認は `node scripts/deploy.mjs --dry-run`。Cloudflare API へ接続せず、R2 を作成せず、Wrangler の dry-run だけを実行します。シェルに設定済みの Cloudflare 資格情報も子プロセスへ渡しません。

参考: [Cloudflare GitHub Actions](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/)、[R2 バケット API](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/)、[r2.dev 設定 API](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/subresources/domains/subresources/managed/methods/list/)、[カスタムドメイン一覧 API](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/subresources/domains/subresources/custom/methods/list/)。
