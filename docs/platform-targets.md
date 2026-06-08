# プラットフォーム・デバイス方針

## 対象デバイス

| 優先度 | デバイス | 用途 |
|---|---|---|
| メイン | iPad mini（8.3インチ） | 主要な使用環境 |
| サブ | iPhone | 補助的な利用 |
| 対象外 | Mac / PC | 対象外 |

## 技術スタック方針

iOS / iPadOS 向けに SwiftUI + SwiftData で実装する。

フレームワーク: SwiftUI（iOS/iPadOSネイティブ）
最小iOS: iOS 17以上（SwiftData、@Observable対応）

---

## iPad mini 向けUI設計方針

### 基本方針

縦持ち（Portrait）を主軸に設計する。横持ち（Landscape）は補助的に対応。

### 縦持ち（メイン）

- サイドバーなし。シングルカラムのフルスクリーンレイアウト
- ナビゲーションは `NavigationStack` による push 遷移（スタック型）
- タブバーをボトムに配置（ブラウザ / リスト / 履歴）
- ディレクトリ移動はタブバーの上に breadcrumb または NavigationStack のタイトルで現在地を表示

### 横持ち（補助）

- `NavigationSplitView` に切り替え、左サイドバーでディレクトリツリーを表示
- `horizontalSizeClass` が `.regular` かつ横向きの場合にサイドバーを表示
- サイドバーは折りたたみ可能にし、動画視聴中はサイドバーを非表示にする

向きの検出は `@Environment(\.verticalSizeClass)` と `@Environment(\.horizontalSizeClass)` の組み合わせで判定する。

### サムネイルグリッドの列数

| 環境 | 列数 |
|---|---|
| iPad 縦（メイン） | 3列 |
| iPad 横 | 5列 |
| iPhone 縦 | 2列 |
| iPhone 横 | 3列 |

`LazyVGrid` + `GridItem(.adaptive(minimum: 160))` で自動調整する。

### 動画プレイヤー

- 縦持ちでも横持ちでもフルスクリーン表示（`fullScreenCover`）
- シーク操作ボタン（+10s / +60s / -10s / -60s）は最小44pt、推奨60pt以上のタップ領域

### iPhone サブ対応

- 縦持ちiPhoneは iPad mini 縦持ちと同じシングルカラム設計がそのまま適用できる
- 列数のみグリッドの `adaptive` 指定で自動調整される
- 追加の分岐コードは最小限に抑える

---
