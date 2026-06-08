# データモデル設計

---

## 永続化モデル（SwiftData）

### RemoteConnection

ネットワーク接続情報を保存するモデル。
現在の主要な接続先は SMB / NAS。

```
RemoteConnection
  ├── id: UUID                      // 主キー
  ├── displayName: String           // 表示名（例: サンプルNAS）
  ├── serviceType: ServiceType      // 接続サービス種別
  ├── host: String?                 // ホスト名またはIPアドレス
  ├── port: Int?                    // ポート番号（サービスごとにデフォルト値あり）
  ├── username: String?             // ユーザー名（OAuthサービスは不要）
  ├── keychainIdentifier: String    // Keychainで認証情報をひくキーID
  ├── startPath: String             // 接続時のトップフォルダパス（デフォルト: "/"）
  ├── createdAt: Date
  └── lastConnectedAt: Date?
```

- パスワード・トークン等の認証情報はKeychainに保存し、このモデルには持たない
- `keychainIdentifier` でKeychain参照。削除時は必ず対応するKeychainエントリも削除する
- `startPath` が `"/"` の場合はサービスのルートをトップとして表示する
- `startPath` を指定した場合、パンくずリストはその階層からスタートする（ルートへは遡れない）
- アプリ内で利用可能な接続種別は `ServiceType.isAvailable` で制御する

---

### MediaList

```
MediaList
  ├── id: UUID
  ├── name: String
  ├── scopeID: String               // ソース識別子
  ├── sortOrder: Int
  ├── createdAt: Date
  └── items: [MediaFile]
```

- ソースごとにリストを分ける
- 1つのファイルを複数のリストに登録できる

### MediaFile

```
MediaFile
  ├── id: UUID
  ├── connectionId: UUID
  ├── sourceID: String              // ソース識別子
  ├── path: String
  ├── name: String
  ├── itemTypeRaw: String
  ├── addedAt: Date
  ├── fileSize: Int64?
  ├── fileId: UInt64?
  └── lists: [MediaList]
```

- `sourceID` と `path` でファイルを識別する
- 利用できる場合は `fileId` も使い、移動やリネーム後の再解決に利用する

---

### WatchHistory

動画の視聴履歴。同一ファイルは1レコードとしてupsertする。

```
WatchHistory
  ├── id: UUID
  ├── sourceID: String
  ├── filePath: String
  ├── fileName: String
  ├── lastPositionSeconds: Double  // 最終視聴位置（秒）
  ├── durationSeconds: Double?     // 動画の総時間（取得できた場合のみ）
  ├── fileId: UInt64?
  ├── watchedAt: Date              // 最終視聴日時
  └── thumbnailData: Data?
```

- upsertのキー: ソースとファイル識別情報の組み合わせ
- 同一ファイルを再視聴した場合は `lastPositionSeconds` と `watchedAt` を更新
- 一覧は `watchedAt` 降順で表示

---

## メモリ上のモデル（永続化しない）

### DirectoryItem

各ソースから取得したファイル・フォルダ情報。画面表示用。

```
DirectoryItem
  ├── name: String                 // ファイル名またはフォルダ名
  ├── path: String                 // サービス上のフルパス
  ├── type: ItemType               // .directory / .video / .image / .other
  ├── size: Int64?                 // ファイルサイズ（バイト）
  ├── modifiedAt: Date?            // 更新日時
  └── createdAt: Date?             // 作成日時（追加日時として使用）
```

#### ItemType

```
enum ItemType {
  case directory
  case video
  case image
  case other
}
```

#### 動画ファイルの判定対象拡張子

mp4, mov, m4v, avi, mkv, wmv, flv, webm, ts, m2ts, mpg, mpeg, rmvb, 3gp

#### 画像ファイルの判定対象拡張子

jpg, jpeg, png, gif, heic, heif, webp, bmp, tiff, tif

---

## モデル間の関係

```
RemoteConnection ──< WatchHistory    （1つの接続先に複数の視聴履歴）
MediaList       >──< MediaFile        （リストとファイルの多対多）
RemoteConnection ──> DirectoryItem   （接続して取得、永続化しない）
```

---

## SwiftDataのコンテキスト管理

- `ModelContainer` をアプリ起動時に1つだけ生成し、`AppEnvironment` から提供
- UIスレッド用のメインコンテキストと、バックグラウンド保存用のコンテキストを分離
- バックグラウンドでの履歴自動保存はバックグラウンドコンテキストを使用
