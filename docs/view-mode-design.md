# ファイルブラウザ 表示形式の選択 設計

---

## 概要

FileBrowserView で4種類の表示形式を切り替えられるようにする。
グリッド系はサムネイルを表示するため、ThumbnailService で動画サムネイルを生成・キャッシュする。

---

## 表示形式

### リスト (List)
- 現行の実装。1カラムの垂直リスト
- アイコン・ファイル名・サイズを表示

### コラム (Column)
- 2カラム（縦持ち）/ 3カラム（横持ち）のリスト形式
- 各セルに小さいサムネイル（60×34pt）+ ファイル名・サイズを横並び表示
- LazyVGrid + GridItem(.flexible) × 2

### グリッド (Grid)
- 3カラム（縦持ち）/ 5カラム（横持ち）のグリッド
- サムネイル（16:9 アスペクト比）+ ファイル名ラベル（2行まで）を縦積み
- LazyVGrid + GridItem(.flexible) × 3

### グリッド（タイトルなし）(Grid No Title)
- 4カラム（縦持ち）/ 6カラム（横持ち）のグリッド
- サムネイルのみ（ファイル名なし）
- LazyVGrid + GridItem(.flexible) × 4

---

## 状態管理

### 永続化
- `UserDefaults` に `FileBrowser.viewMode` キーで保存
- 全接続共通

### ViewMode enum

```
enum ViewMode: String, CaseIterable {
    case list
    case column
    case grid
    case gridNoTitle
}
```

---

## サムネイル生成

### 動画
- VLCMediaThumbnailer を使用（SMBファイルのダウンロード不要）
- snapshotPosition: 0.1（再生時間の10%地点）
- サムネイルサイズ: 320×180pt（@2x相当）
- 取得失敗時は SF Symbol `film` をプレースホルダーとして表示
- 生成完了後はフェードイン（0.2秒）で切り替え

### 画像
- 取得できない場合はプレースホルダー（SF Symbol: `photo`）を表示

### フォルダ
- SF Symbol `folder.fill`（サムネイル非対応）

---

## キャッシュ設計

### メモリキャッシュ（NSCache）
- キー: `"\(connection.id)/\(item.path)"`
- 最大エントリ数: 500件
- 最大メモリ使用量: 50MB
- メモリ警告で全クリア

### ディスクキャッシュ
- 保存先: `Library/Caches/thumbnails/`
- ファイル名: `SHA256(key).jpg`（固定長で衝突回避）
- 有効期限: OS が Caches を自動管理

---

## 重複リクエストの排除

同一ファイルへの複数セルからの並行リクエストは、
FileBrowserViewModel の `thumbnails: [String: UIImage]` ディクショナリへの書き込みで冪等に処理する。
（すでにキャッシュにある場合は生成をスキップ）

---

## サムネイルロード戦略

### Lazy Loading
セルが画面に表示されたときに `.task(id: item.path)` でサムネイルロードを開始する。
スクロール高速化のために一度キャッシュされた画像は再取得しない。

### FileBrowserViewModel との連携
```
FileBrowserViewModel
  ├── var viewMode: ViewMode          // 表示形式（UserDefaults 永続化）
  ├── var thumbnails: [String: UIImage] // 取得済みサムネイル（@Observable で View 更新）
  ├── func thumbnail(for item:) -> UIImage?
  └── func loadThumbnail(for item:) async
```

ThumbnailService と SMBClientManager は ViewModel の依存として注入する。
テスト時は nil を渡してサムネイル生成をスキップする。

---

## ツールバー

ソートボタンの隣に表示形式ボタンを追加する。

```
ナビゲーションバー右端:
  [表示形式ボタン]  [ソートボタン]

表示形式ボタンタップ → Picker メニュー表示:
  ✓ リスト
    コラム
    グリッド
    グリッド（タイトルなし）
```

---

## 関連ファイル

| ファイル | 内容 |
|---|---|
| `Features/FileBrowser/ViewMode.swift` | ViewMode enum |
| `Services/ThumbnailService.swift` | サムネイル生成・ディスクキャッシュ |
| `Features/FileBrowser/FileBrowserViewModel.swift` | viewMode・thumbnails 管理 |
| `Features/FileBrowser/FileBrowserView.swift` | 表示形式ごとのレイアウト・ツールバーボタン |
