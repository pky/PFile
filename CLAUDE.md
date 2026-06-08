# PFile Claude 作業ガイド

## 目的

このファイルは、Claude が PFile を編集するときの事故防止ルールをまとめる。
README の説明を繰り返すのではなく、このリポジトリ固有の前提と禁止事項を優先する。

## 生成物

- `PFile.xcodeproj` と `PFile.xcworkspace` は生成物として扱う
- Xcode プロジェクト設定を変えるときは `project.yml` を編集する
- `project.yml` を変更したら `xcodegen generate` または `make setup` で再生成する
- `PFile/Resources/Info.plist` は生成される前提で、リポジトリには含めない

## 公開リポジトリの安全性

- `GoogleService-Info.plist` をコミットしない
- `PFile/Resources/Info.plist` をコミットしない
- `.env*`、署名素材、provisioning profile、App Store Connect API キーをコミットしない
- `.private/`、`progress.txt`、個人用メモをコミットしない
- docs / README / テストデータに実在の動画名、個人名、メールアドレス、ローカルパスを残さない
- 個人メールアドレス、ローカル絶対パス、実運用の NAS パス、実運用の Firebase / GCP 情報を残さない

## Firebase / AdMob

- Firebase 設定ファイルがなくてもビルドできる状態を壊さない
- Firebase の初期化は `FirebaseSupport.configureIfAvailable()` 経由にする
- Analytics / Crashlytics 送信は `FirebaseSupport` 経由にする
- 外部送信ログに動画名、ファイルパス、接続先ホスト、ユーザー名を含めない
- AdMob の ID を変更するときは、テスト ID と本番 ID の混在に注意する

## SwiftUI / 状態管理

- SwiftUI の不具合は、まず ViewModel と state ownership を確認する
- 子 View で状態を重複管理しない
- `@State`、`@Observable`、`@Environment` の責務を崩さない
- View 階層の大きな書き換えは、原因特定後に必要な場合だけ行う
- async/await の修正では、Task の重複、キャンセル漏れ、MainActor 境界を確認する

## 動画再生 / SMB

- 動画再生まわりは実機依存の挙動が多い
- AMSMB2 は実機専用の前提があるため、Simulator だけで判断しない
- SMB、VLCKit、HTTP range stream の責務を混ぜない
- 再生診断ログを追加するときも、外部送信される値にはファイル名を含めない

## 変更方針

- 変更は最小範囲にする
- 無関係なリファクタリングを混ぜない
- 既存の MVVM + Repository 構成を優先する
- 依存関係を追加しない。必要な場合は理由を明確にする
- 公開向け docs は現在の仕様を書く。変更履歴や内部検討メモを残さない

## 検証

- まず変更箇所に近いテストを実行する
- ビルド確認は必要に応じて `make build` または Xcode の `PFile` scheme を使う
- Firebase 設定なしのビルドが通ることを壊さない
- 公開前の安全確認では、少なくとも次を確認する

```sh
git status --short
git ls-files --others --exclude-standard
git diff --check
```

## コミット

- コミットメッセージは日本語 1 行、50 文字以内にする
- 公開前のコミットでは、秘密情報や個人情報の検出結果を確認してから commit する
