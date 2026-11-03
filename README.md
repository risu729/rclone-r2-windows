# R2Drive

Cloudflare R2を、ファイル内容・名前を暗号化したWindowsドライブとして使うためのPowerShellスクリプトです。**実行するファイルは `R2Drive.ps1` 1本**です。

初回設定、設定途中からの再開、通常の接続を同じスクリプトで行います。暗号化には標準の[rclone crypt](https://rclone.org/crypt/)、ドライブ表示には[WinFsp](https://winfsp.dev/)を使います。

## 必要なもの

- Windows 11 x64、Windows PowerShell 5.1
- `winget`（App Installerに付属）
- rcloneとWinFsp。未インストールの場合は初回実行時にインストールするか確認します。
- R2を有効化したCloudflareアカウント、既存の**非公開・Standard**のR2バケット
- そのバケットだけを対象にした **Object Read & Write** のS3認証情報
- パスワードマネージャーなどに保管した、24文字以上の強い暗号化パスフレーズ

Cloudflare側の準備は[公式のS3接続手順](https://developers.cloudflare.com/r2/get-started/s3/)を参照してください。このスクリプトはCloudflareのアカウント・バケット・トークンを作成しません。

通常のR2エンドポイント `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` を使います。EUなどのjurisdiction専用エンドポイントには対応していません。

## 初回の使い方

1. このリポジトリをcloneするか、`R2Drive.ps1` をダウンロードします。
2. 内容を確認してから、保存したフォルダで次を実行します。

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -STA -File .\R2Drive.ps1
   ```

   インターネットから取得したファイルがWindowsの実行ポリシーで拒否された場合は、内容を確認した後、そのファイルだけを解除します。組織のポリシーで禁止されている環境では管理者の指示に従ってください。

   ```powershell
   Unblock-File -LiteralPath .\R2Drive.ps1
   ```

   `-ExecutionPolicy RemoteSigned` は起動するPowerShellプロセスにだけ適用し、PC全体の設定は変更しません。管理ポリシーが優先される場合は変更できません。スタートメニュー・自動起動にも同じ指定を使います。

3. 必要なソフトのインストール確認が出た場合、内容を確認します。WinFspのインストールには管理者の確認が必要な場合があります。スクリプトはWindowsの確認画面を自動操作しません。
4. 設定画面に次を入力します。

   | 項目 | 入力内容 |
   |---|---|
   | CloudflareアカウントID | 32桁のアカウントID |
   | R2バケット名 | 用意した非公開バケットの名前 |
   | ドライブ文字 | 未使用のD〜Z。初期値はR |
   | S3 Access Key ID | トークン作成結果のS3クライアント用Access Key ID |
   | S3 Secret Access Key | 同じ画面のSecret Access Key |
   | 暗号化パスフレーズ | 新しく決めた24文字以上のパスフレーズ。確認欄にも同じものを入力 |

   **API token valueやCloudflareログイン用パスワードは入力しません。** 暗号化パスフレーズはキーやログイン用パスワードと別にしてください。

5. パスフレーズを保管したことを確認して「確認して接続」を押します。接続が完了するとドライブが開きます。
6. 初期状態では復旧用設定の保存先を選ぶ画面が出ます。`r2drive-recovery.conf` を、パスフレーズとともに安全に保管してください。設定ファイル自体も暗号化されています。

依存ソフトを先に導入する場合は、次のコマンドも使えます。

```powershell
winget install --exact --id Rclone.Rclone --source winget --scope user
winget install --exact --id WinFsp.WinFsp --source winget
```

## 2回目以降

同じコマンドを実行するか、スタートメニューの **R2Drive** を開きます。

- 接続済みなら、そのドライブを開きます。
- 接続していなければ、保存済み設定のパスフレーズを入力します。初回のS3キーを再入力する必要はありません。
- 設定作成後に接続が失敗しても、次回は保存済みの暗号化設定を再利用します。パスフレーズやsaltを勝手に作り直しません。
- 別のドライブが指定文字を使っている場合は、接続を中止します。既存ドライブは変更しません。

自動接続や復旧用設定の出力を変更する場合は、次を実行します。接続中に自動接続を無効にしても、その時点のドライブ接続は終了しません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -STA -File .\R2Drive.ps1 -Mode Configure
```

既存の接続先・暗号化パスフレーズを変更する機能はありません。`Configure` は保存済み設定を開く画面です。

## 自動接続とロック

**自動接続は初期状態では無効です。** 有効にする場合は、画面で「Windowsログイン時に自動接続する」を選びます。

- 有効時はパスフレーズをWindowsの[DPAPI / CurrentUser](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.dataprotectionscope)で保護して保存し、サインイン時にドライブとエクスプローラーを開きます。
- 同じWindowsユーザーとして動くプログラムは、この保存鍵を復号できる可能性があります。復号のたびに本人確認をする仕組みではありません。
- **画面ロック・スリープ・一定時間の放置による自動切断はありません。** ドライブが接続している間はアプリからファイルを読めます。
- サインアウトやシャットダウンで接続は終了します。自動接続が有効なら、次のサインインで再接続します。
- 自動接続を無効にして設定を完了すると、このスクリプトのスタートアップ項目とDPAPI保存鍵を取り除きます。暗号化済み設定とR2上のデータは保持します。

明示的なロック／安全な取り外しボタンは実装していません。停止・サインアウトの前に、ファイルを閉じてアップロードが完了していることを確認してください。サインアウト後もPC内のキャッシュが確実に消去されるわけではありません。

## 保存・キャッシュの動作

- ドライブへの保存は、PC内のキャッシュを経由してアップロードされます。ファイルを閉じ、最後のアクセスから5秒経過するとアップロード対象になります。転送完了までには回線やファイル容量に応じた時間がかかります。
- 書き込み用キャッシュは目安2GB、最終アクセスから1時間で整理する設定です。開いているファイルや未アップロードのデータがある場合、容量・時間の目安を超えることがあります。
- キャッシュや他アプリの一時ファイルは、PC内に**読める状態**で残る場合があります。これはR2上の暗号化とは別です。
- R2上のファイル内容・名前は暗号化しますが、ファイルサイズ・更新日時・フォルダ構造などは隠しません。
- ネットワーク切断時やPC終了直後のファイル到着は保証しません。重要なファイルはR2から読み戻して確認してください。

詳細は[rclone mountのキャッシュ仕様](https://rclone.org/commands/rclone_mount/#vfs-file-caching)を参照してください。

## 作成するファイル

現在のWindowsユーザーの `%LOCALAPPDATA%\R2Drive` に保管します。既存の標準rclone設定は変更しません。

| ファイル | 内容 |
|---|---|
| `R2Drive.ps1` | 継続利用・スタートアップ用の同じスクリプトのコピー |
| `settings.json` | アカウントID・バケット名・ドライブ文字・自動接続の指定 |
| `rclone.conf` | 暗号化されたS3認証情報・crypt設定・ランダムな追加salt |
| `unlock.dpapi` | 自動接続を有効にした場合のみ作成するWindowsユーザー専用の保存鍵 |
| `mount.pid` | このスクリプトが起動したドライブのプロセス番号 |
| `cache/` | 書き込み用キャッシュ |
| `mount.log` | ドライブ接続時のエラーログ |
| `pending-*.conf` | 初回設定が途中で止まった場合に残ることがある、暗号化済みの設定候補 |

`settings.json` も接続先情報を含み、ログにはファイル名が含まれる場合があります。実際の設定・鍵・キャッシュ・ログをリポジトリへ追加しないでください。

## 他の端末・クライアントへの移行

標準のrclone cryptを使うため、同じ設定を対応クライアントに引き継げばR2内のファイルを再アップロードせず使えます。復旧用の暗号化設定には追加saltも含まれます。パスフレーズだけでなく、設定も保管してください。

Androidでは[RSAF](https://github.com/chenxiaolong/RSAF)などが候補です。Androidでの実機動作はこのリポジトリの検証範囲に含みません。`unlock.dpapi` は別端末への移行用ファイルではありません。

復旧用設定だけでは、アカウントID・バケット名・ドライブ文字などを含むこのスクリプトの `settings.json` は復元されません。別のPCでこのスクリプトを継続する場合は、スクリプトと `settings.json` も保管してください。

## 動作確認

R2へのアクセスやドライブ接続をせず、ローカルの一時フォルダで自己診断できます。rcloneが導入済みである必要があります。

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File .\R2Drive.ps1 -Mode SelfTest
```

設定ファイルの暗号化、標準cryptのファイル名・内容の暗号化と読み戻し、Windows DPAPIでの保管・取り出し、誤った設定パスワードの拒否を確認します。一時フォルダは終了時に片付けます。

WinFspも含めて確認する場合は `-MountTest` を追加します。空いているV〜Zのいずれかに一時ドライブを作り、書き込みが暗号化バックエンドへ到着したことを確認して接続を終了します。実際のR2や既存のR:にはアクセスしません。

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File .\R2Drive.ps1 -Mode SelfTest -MountTest
```

元の個人用構成では、Windowsドライブへの保存→R2からの直接読み戻し、暗号化オブジェクトの確認を実施しています。この公開版はそれを1本に統合・汎用化したもので、任意の環境や再起動後の動作まで保証するものではありません。

## 料金・ライセンス

このスクリプトはMITライセンスです。rcloneとWinFspは別途それぞれのライセンスに従います。

R2の利用料金は別途発生する場合があります。Workers Paidとは別計算で、無料枠は同じCloudflareアカウント内で共有します。[R2公式料金](https://developers.cloudflare.com/r2/pricing/)を確認してください。

このリポジトリはコードと使い方の公開用です。Issues、Pull requests、Discussions、Projects、Wiki、Actionsは無効化します。
