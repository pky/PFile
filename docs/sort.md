# 並び替え設計

---

## 対応する並び替えキー

| キー | 説明 |
|---|---|
| `nameAsc` | 名前昇順（A→Z、あ→ん）※デフォルト |
| `nameDesc` | 名前降順 |
| `dateAddedAsc` | 追加日時（createdAt）昇順 |
| `dateAddedDesc` | 追加日時（createdAt）降順 |
| `dateModifiedAsc` | 更新日時（modifiedAt）昇順 |
| `dateModifiedDesc` | 更新日時（modifiedAt）降順 |
| `sizeAsc` | ファイルサイズ昇順 |
| `sizeDesc` | ファイルサイズ降順 |

---

## 並び替えのルール

### フォルダとファイルのグループ分け

フォルダを常にリストの先頭にまとめ、ファイルを後ろにグループ化する。
各グループの内部で選択された並び替えキーを適用する。

```
例（名前昇順の場合）:
  📁 アクション
  📁 SF
  📁 ドラマ
  🎬 sample_a.mp4
  🎬 sample_b.mkv
  🎬 sample_c.avi
```

### nilの扱い

`createdAt` / `modifiedAt` / `size` が nil のアイテムはグループの末尾に配置する。

### 名前の自然順ソート

名前ソートには自然順（Natural Sort）を適用する。
`"sample_10.mp4"` が `"sample_9.mp4"` より後になるよう `localizedStandardCompare` を使用。

---

## 並び替え設定の永続化

選択した並び替えキーをUserDefaultsに保存し、次回起動時に復元する。

### 保存のスコープ

NASとフォルダの組み合わせごとに個別の並び替え設定を保持する。

保存キー: `sort_\(nasConfigId)_\(SHA256(folderPath))`

同じNASの別フォルダに移動しても、それぞれ独自の並び替えを記憶する。

---

## UIでの操作

ディレクトリブラウザのナビゲーションバー右端に「並び替え」ボタンを配置。
タップすると以下のメニュー（`Menu`）を表示する。

```
並び替え
  ✓ 名前（昇順）     ← 現在選択中にチェックマーク
    名前（降順）
    追加日時（新しい順）
    追加日時（古い順）
    更新日時（新しい順）
    更新日時（古い順）
    サイズ（大きい順）
    サイズ（小さい順）
```

選択と同時にリストをアニメーションなしで即時更新する。

---

## SortServiceの実装方針

`SortService` は `[DirectoryItem]` を受け取り、ソート済みの `[DirectoryItem]` を返す純粋関数として実装する。
状態を持たず、ViewModel側でソートキーを管理する。

```
func sort(_ items: [DirectoryItem], by key: SortKey) -> [DirectoryItem]
```

フォルダ・ファイルのグループ分けとnil処理もこの関数内で行う。
