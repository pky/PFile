# グリッドセルサイズ変更 設計

---

## 概要

グリッド表示（column / gridTitled / gridNoTitle）でセルサイズをスライダーで変更できる機能。
スライダーを右に動かすと大きなセル（少ない列数）、左で小さなセル（多い列数）になる。
UserDefaults に保存して次回起動時も維持する。

---

## UI 設計

### スライダーの配置

ナビゲーションバー右端に「グリッドサイズ変更」ボタンを追加する。
グリッド系 ViewMode（column / gridTitled / gridNoTitle）のときのみ表示する。

```
ナビゲーションバー右端:
  [セルサイズボタン]  [表示形式ボタン]  [ソートボタン]
```

ボタンタップで **ポップオーバー** を表示する（iPad 最適化、iPhone ではシートになる）。

### ポップオーバー内容

```
┌─────────────────────────────┐
│  グリッドサイズ              │
│                              │
│  小 ●━━━━━━━━━━━━━━━━━━● 大  │
│                              │
│  3 列                        │
└─────────────────────────────┘
```

- タイトル「グリッドサイズ」
- Slider（最小値〜最大値）
- 現在の列数（参考値として表示）

---

## アーキテクチャ設計

### セルサイズ管理方式

`gridCellWidth: CGFloat` を FileBrowserViewModel に持たせる。
`LazyVGrid` の GridItem を `.flexible()` × 固定列数から `.adaptive(minimum: gridCellWidth)` に変更する。
`.adaptive` により、画面幅に応じて列数が自動計算される。

縦持ち（320pt）で cellWidth=150 → 2列
横持ち（600pt）で cellWidth=150 → 4列
スライダー変更 → cellWidth が変化 → 列数が自動更新

### 設定値

| 項目 | 値 |
|---|---|
| 最小セル幅 | 80pt |
| 最大セル幅 | 280pt |
| デフォルト | 150pt |
| UserDefaults キー | `FileBrowser.gridCellWidth` |

gridColumnCount の参考計算式（表示用）:
`floor(containerWidth / gridCellWidth)`

### ViewModel への追加

```swift
var gridCellWidth: CGFloat = 150 {
    didSet {
        let clamped = gridCellWidth.clamped(to: 80...280)
        UserDefaults.standard.set(clamped, forKey: Self.gridCellWidthKey)
    }
}
```

初期化時に UserDefaults から復元する。

---

## View 構成

### gridContent()

GridItem は `.adaptive(minimum: gridCellWidth)` を使う。
ViewMode（column / gridTitled / gridNoTitle）の区別は列数ではなくセルの外観（レイアウト）で維持する。

```swift
let gridItems = [GridItem(.adaptive(minimum: viewModel.gridCellWidth), spacing: 8)]
```

### toolbarItems()

グリッド系 ViewMode のときのみ「セルサイズ」ボタンを表示する。

```swift
if viewModel.viewMode != .list {
    ToolbarItem(placement: .navigationBarTrailing) {
        Button { showGridSizePopover = true } label: {
            Image(systemName: "square.resize")
        }
        .popover(isPresented: $showGridSizePopover) {
            GridSizePopoverView(cellWidth: $viewModel.gridCellWidth)
        }
    }
}
```

### GridSizePopoverView（新規コンポーネント）

FileBrowserView 内のプライベート struct として実装する。

```
struct GridSizePopoverView: View {
    @Binding var cellWidth: CGFloat
    // Slider + 列数ラベル
}
```

---

## 関連ファイル

| ファイル | 内容 |
|---|---|
| `Features/FileBrowser/FileBrowserViewModel.swift` | gridCellWidth 管理・UserDefaults 永続化 |
| `Features/FileBrowser/FileBrowserView.swift` | adaptive grid・ツールバーボタン・GridSizePopoverView |

表示形式ごとのセル外観は `ViewMode` で管理し、列数は `gridCellWidth` と画面幅から決まる。

---

## テスト対象

| テストケース | 内容 |
|---|---|
| gridCellWidth デフォルト値が 150 | 初期化時の確認 |
| gridCellWidth 変更が UserDefaults に保存される | 永続化の確認 |
| UserDefaults の値が復元される | 初期化時の復元確認 |
| 範囲外の値がクランプされる | 80未満は80、280超は280に補正 |
