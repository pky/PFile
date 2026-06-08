# SMB接続・セキュリティ設計

---

## 使用ライブラリ

AMSMB2（Swift製SMB2/3クライアント）を採用。
Swift Package Manager で導入。

---

## 接続フロー

```
1. ユーザーがホーム画面でNASを選択
2. SMBClientManager が既存セッションキャッシュを確認
3. キャッシュあり・有効 → そのまま使用
4. キャッシュなし・期限切れ → 以下の手順で新規接続
   a. KeychainService からパスワードを取得
   b. AMSMB2 で認証・接続（タイムアウト: 10秒）
   c. 接続成功 → セッションをキャッシュに保存
   d. 接続失敗 → エラー種別を判定してアラート表示
```

---

## SMBClientManager

セッションのライフサイクルを一元管理する。

### セッションキャッシュ

- キャッシュキー: `nasConfigId`
- アイドルタイムアウト: 30秒間操作がなければ自動切断
- アプリがバックグラウンドに移行したタイミングで全セッションを切断

### 同時接続数

- 上限: 3セッション（異なるNASへの同時接続）
- 上限超過時は最も古いセッションを切断して新規接続

### エラー種別と対応

| エラー | 表示メッセージ | 対応 |
|---|---|---|
| タイムアウト | 接続がタイムアウトしました。ホストアドレスを確認してください | アラート表示 |
| 認証失敗 | ユーザー名またはパスワードが正しくありません | アラート表示 |
| ホスト不明 | ホストが見つかりません。ネットワーク接続を確認してください | アラート表示 |
| 接続拒否 | 接続が拒否されました。共有フォルダ名を確認してください | アラート表示 |

---

## Keychainによるパスワード管理

### 保存仕様

| 項目 | 値 |
|---|---|
| Service名 | `com.pfile.nas-credentials` |
| Account（キー） | `nasConfigId`（UUID文字列） |
| アクセス属性 | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| iCloudバックアップ | 含まない（デバイス固有） |

### KeychainService の操作

- `save(password:for nasConfigId:)` - 新規保存
- `load(for nasConfigId:) -> String?` - 取得
- `update(password:for nasConfigId:)` - 更新
- `delete(for nasConfigId:)` - 削除

### NASConfig削除時の処理

NASConfigをSwiftDataから削除する前に、必ずKeychainのエントリを削除する。
削除順序: Keychain削除 → SwiftData削除（逆順にすると孤立エントリが残る）

---

## セキュリティ方針

### プロトコルバージョン

- SMB2以上を使用（SMB1は脆弱性があるため使用禁止）
- AMSMB2の接続設定でSMB1を明示的に無効化

### ネットワーク

- App Transport Security（ATS）の例外はプライベートIPアドレス帯のみ許可
  - 192.168.x.x / 10.x.x.x / 172.16.x.x〜172.31.x.x
- ローカルネットワーク使用の権限（`NSLocalNetworkUsageDescription`）をInfo.plistに設定

### メモリ

- パスワード文字列は使用後すぐに変数のスコープを外してGCに任せる
- ログ・デバッグ出力にパスワードを含めない

---

## ローカルネットワーク権限

iOS 14以降、ローカルネットワークへのアクセスに許可が必要。

Info.plistに追加する項目:
- `NSLocalNetworkUsageDescription`: 「NASに接続するためローカルネットワークへのアクセスが必要です」
- `NSBonjourServices`: SMB検出用（将来のNAS自動検出機能向け）
