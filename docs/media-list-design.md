# メディアリスト設計

## 概要

メディアリストは、動画や画像を任意のリストにまとめておくための機能。
NAS、ローカルフォルダ、フォトライブラリなどのソースから、あとで見返したいファイルをリストに登録できる。

主な用途:

- 見たい動画や画像をリスト単位で整理する
- 同じファイルを複数のリストに登録する
- リスト内のファイルをリスト表示またはグリッド表示で探す
- リスト未登録のファイルだけをブラウザ側で絞り込む

## 画面構成

### リスト一覧

リスト一覧では、現在のソースに紐づくメディアリストを表示する。

- リストの作成
- リスト名の変更
- リストの削除
- リストの並び替え
- タブ順序設定の表示

### リスト詳細

リスト詳細では、選択したリストに登録されているファイルを表示する。

- 動画の再生
- 画像の表示
- リストからの削除
- 表示形式の切り替え
- グリッドサイズの変更
- 並び替え
- 複数選択

### リストへ追加

ファイルブラウザやフォトライブラリから選択したファイルを、既存または新規のリストに追加する。

- 追加先リストの選択
- 新しいリストの作成
- 登録済みリストのチェック表示
- 複数ファイルの一括追加

## データモデル

### MediaList

```swift
@Model
final class MediaList {
    @Attribute(.unique) var id: UUID
    var name: String
    var scopeID: String
    var sortOrder: Int
    var createdAt: Date
    @Relationship(deleteRule: .nullify, inverse: \MediaFile.lists)
    var items: [MediaFile]
}
```

`scopeID` は、リストが属するソースを識別するための値。
ソースごとにリストを分けることで、NAS、ローカルフォルダ、フォトライブラリの内容が混ざらないようにする。

### MediaFile

```swift
@Model
final class MediaFile {
    @Attribute(.unique) var id: UUID
    var connectionId: UUID
    var sourceID: String
    var path: String
    var name: String
    var itemTypeRaw: String
    var addedAt: Date
    var fileSize: Int64?
    var fileId: UInt64?
    @Relationship(deleteRule: .nullify)
    var lists: [MediaList]
}
```

`sourceID` と `path` を使って、各ソース内のファイルを識別する。
フォトライブラリなどパスだけでは安定しないソースでは、必要に応じて `fileId` も利用する。
`connectionId` はリモート接続由来のファイルとの互換に使う。

## 関係

- 1つのファイルを複数のリストに登録できる
- リストを削除しても、登録されていたファイル参照は他のリストで使える
- ファイルをリストから外しても、元のファイル自体は削除しない
- リストは `scopeID` ごとに管理する

## Repository

`MediaListRepository` がリスト操作、ファイル登録、登録済み判定を担当する。

主な責務:

- リスト一覧の取得
- ソース単位のリスト取得
- リストの作成、名称変更、削除
- ファイルの追加、削除
- リスト内ファイルの取得
- ブラウザ側で使う登録済みファイル判定

## ブラウザとの連携

ファイルブラウザは `MediaListRepository` を参照し、現在表示しているソース内でリスト登録済みのファイルを判定する。

ブラウザ側の主な機能:

- 複数選択
- 選択したファイルのリスト追加
- リスト未登録のみ表示するフィルター
- 登録状態に応じた表示更新

## タブ順序

タブの並び順は `TabOrderService` で UserDefaults に保存する。

- 初期順序はブラウザ、履歴
- リストは作成済みのリストに応じて表示する
- 保存済みのタブ構成に存在しない項目は読み込み時に補完する

タブ順序の変更は設定シートから行い、変更後すぐに保存する。
