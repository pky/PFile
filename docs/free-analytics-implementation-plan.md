# 無料・広告なし・匿名Analytics方針の実装計画

最終更新: 2026-07-11

## 決定事項

PFile 1.0は次の形で公開する。

- 完全無料
- 広告なし
- アプリ内課金なし
- アカウント登録なし
- Firebase AnalyticsとCrashlyticsは、利用者が同意した場合だけ有効
- 広告連携、広告パーソナライズ、IDFA、クロスアプリ追跡を使用しない
- ファイル名、パス、NAS情報、写真・動画情報を外部送信しない

目的は収益化ではなく、実際の機能利用と安定性を把握して改善することである。

## 基本設計

### 同意方式

初回起動時に、アプリ操作を妨げない説明画面を1回表示する。

選択肢:

- `改善に協力する`
- `送信しない`

選択前はAnalyticsとCrashlyticsを無効にする。選択結果はUserDefaultsへ保存し、設定画面の`匿名の利用状況とクラッシュ情報を送信`からいつでも変更できるようにする。

AppleのATTダイアログは使用しない。IDFA、他社アプリ・Webサイトとのデータ結合、広告測定を行わないためである。

### Firebase初期化

- `FirebaseApp.configure()`自体は設定ファイルがある場合だけ実行する
- Info.plistでAnalyticsとCrashlyticsの自動収集を初期状態で無効にする
- 保存済みの同意が`true`の場合だけ、起動後に両方の収集を有効化する
- Firebase設定ファイルがない開発環境では従来どおり安全にno-opとする
- Analytics依存は`FirebaseAnalytics`から、IDFA収集能力を含まない`FirebaseAnalyticsCore`へ変更する
- Google AnalyticsとGoogle Adsをリンクしない
- 広告パーソナライズ信号を無効にする

## 実装フェーズ

### フェーズ1 広告と課金を完全に削除する

対象:

- `project.yml`
  - Google Mobile Adsパッケージとプロダクト依存を削除
  - `GADApplicationIdentifier`を削除
- `PFile/App/PFileApp.swift`
  - `GoogleMobileAds` importと`MobileAds.shared.start`を削除
- `PFile/Shared/Components/AdBannerView.swift`
  - ファイルを削除
- `PFile/Shared/Constants.swift`
  - `AdMob`と`Purchase`定数を削除
- `PFile/Features/Home/HomeView.swift`
  - 広告表示判定、広告領域、購入サービス初期化を削除
- `PFile/Services/PurchaseService.swift`
  - ファイルを削除
- `PFile/App/AppEnvironment.swift`
  - `purchaseService`の保持と生成を削除
- `PFile/Features/Settings/SettingsView.swift`
  - 購入、復元、広告デバッグUIを削除
- `PFile/Features/Settings/SettingsViewModel.swift`
  - StoreKit状態と購入操作を削除
- 関連モックとテスト
  - 課金テストを削除し、Analytics設定テストへ置き換える
- READMEと設計文書
  - 広告削除課金の記述を削除し、無料・広告なしを明記する

完了条件:

- `rg`で`GoogleMobileAds`、`AdBannerView`、`PurchaseService`、商品IDが本番ソースに残らない
- 依存解決結果からGoogle Mobile AdsとUMPが消える
- Home下部に不要な余白が残らない
- 設定画面に購入関連項目が残らない
- 対象テストとDebugビルドが成功する

### フェーズ2 Analytics同意状態を実装する

新規構成案:

```text
PFile/Services/TelemetryService.swift
PFile/Domain/Models/TelemetryConsent.swift
PFile/Features/Settings/TelemetryConsentView.swift
```

`TelemetryServiceProtocol`を用意し、画面やViewModelがFirebase APIへ直接依存しないようにする。

主な責務:

- 同意状態の保存と取得
- Analytics / Crashlytics収集の有効・無効切り替え
- 許可されたイベントだけの送信
- Crashlyticsへ渡す値の制限
- Firebase未設定時のno-op

同意状態:

```swift
enum TelemetryConsent: String, Codable {
    case undecided
    case enabled
    case disabled
}
```

完了条件:

- 未選択・拒否状態ではイベントとクラッシュ情報を送信しない
- 同意後は再起動しても有効状態を維持する
- 設定画面で無効化した直後から送信を停止する
- ATT権限を要求しない

### フェーズ3 型付きイベントへ置き換える

自由文字列の`FirebaseSupport.logEvent(_:parameters:)`を廃止し、列挙型または専用メソッドだけを公開する。

1.0で収集する最小イベント:

| イベント | 目的 | 許可パラメータ |
|---|---|---|
| `source_opened` | 使われるソースを知る | `source_type`: smb/local/photo |
| `playback_started` | 再生経路を知る | `source_type`, `engine`, `format_category` |
| `playback_failed` | 失敗傾向を知る | `source_type`, `engine`, `error_category` |
| `resume_playback_used` | 履歴再開の価値を測る | `source_type` |
| `media_added_to_list` | リスト機能の利用を測る | `source_type`, `selection_count_bucket` |
| `history_opened` | 履歴導線の利用を測る | なし |
| `thumbnail_failed` | サムネイル品質を測る | `source_type`, `format_category`, `error_category` |

収集しないイベント:

- 画面上の全タップ
- フォルダ移動ごとの詳細ログ
- 正確な再生位置、動画時間、ファイルサイズ
- ユーザー単位の詳細な行動列
- 利用目的が説明できないイベント

値が必要な場合は範囲へ丸める。

```text
selection_count_bucket: one / two_to_five / over_five
duration_bucket: under_10m / 10m_to_60m / over_60m
latency_bucket: under_1s / 1s_to_3s / over_3s
```

### フェーズ4 Crashlyticsログを匿名化する

現状の動画・SMB診断には、ファイル名、パス、URL、接続表示名が入る可能性がある。ReleaseでCrashlyticsへ送る値を次へ限定する。

許可:

- 内部で生成した一時的なplayer ID
- 再生エンジン種別
- 状態名と匿名エラー分類
- 同時処理数
- 丸めた時間、メモリ、レイテンシ
- アプリバージョン、OS、端末種別（SDK標準情報）

禁止:

- ファイル名、パス、URL
- NASホスト、IP、共有名、表示名
- ユーザー名、認証情報
- 写真アセットID
- `localizedDescription`全文
- 任意の自由記述

`record(error:)`へ外部SDKエラーをそのまま渡す場合は、説明文にパスやURLが入らないことを確認し、安全な独自エラーへ変換する。

### フェーズ5 プライバシーUIと申告を完成させる

- 設定画面へAnalytics切り替えを追加
- 設定画面へプライバシーポリシーリンクを追加
- ポリシーに収集項目、目的、Googleへの送信、無効化方法、保存期間を書く
- Firebase Consoleのデータ保持を必要最小限に設定する
- App Store Connectで`Product Interaction`、`Crash Data`等を実構成に合わせて申告する
- ArchiveからPrivacy Reportを生成し、Privacy Manifestと申告を照合する
- `FirebaseAnalyticsCore`、Crashlyticsと推移依存のPrivacy Manifestを確認する

## テスト計画

### 単体テスト

- 未選択ではイベントを送らない
- 拒否ではイベントを送らない
- 同意時だけイベントを送る
- 設定変更が永続化される
- 許可外パラメータを送信できない
- ファイル名、パス、URLをAPIへ渡す型が存在しない
- バケット境界が正しい
- Firebase設定ファイルなしでもクラッシュしない

### 結合確認

- DebugViewで許可イベントだけが届く
- 同意前に`first_open`等が送信されない
- 無効化後に新しいイベントが届かない
- Crashlyticsテストクラッシュが同意時だけ届く
- Crashlyticsにファイル名、パス、NAS情報がない
- Archiveのリンク済みFrameworkにGoogle Mobile Adsがない
- ATTダイアログが表示されない

## 実施順序

1. フェーズ1で広告・課金を削除する
2. XcodeGen生成、対象テスト、Debugビルドを通す
3. フェーズ2で同意状態と設定UIを実装する
4. フェーズ3で型付きイベントを導入する
5. フェーズ4で既存のCrashlyticsログを匿名化する
6. フェーズ5でポリシー、Privacy Report、App Privacyを揃える
7. Release構成を内部TestFlightまたはApp Store配布相当で確認する

各フェーズを独立したレビュー可能な差分にし、広告削除とTelemetry再設計を同じ巨大差分にしない。

## 完了条件

- 広告・課金コードとSDKが完全にない
- Analytics / Crashlyticsは明示同意後だけ動く
- ATTとIDFAを使用しない
- 許可イベント以外を送れない
- ファイル名、パス、NAS情報、認証情報を送らない
- プライバシーポリシー、Privacy Manifest、App Privacy回答が実装と一致する
- 対象テスト、Debugビルド、Release Archive検証が成功する

## 公式資料

- [Firebase Analyticsの収集制御](https://firebase.google.com/docs/analytics/ios/configure-data-collection)
- [FirebaseのApp Storeデータ申告資料](https://firebase.google.com/docs/ios/app-store-data-collection)
- [Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Apple App Tracking Transparency](https://developer.apple.com/documentation/apptrackingtransparency)
