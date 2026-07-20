# App Store 1.0 リリース準備

最終更新: 2026-07-11

## 結論

PFile は主要機能と単体テストの土台はあるが、現時点では App Store へ提出できる状態ではない。

不足の中心は新機能ではなく、次の5領域である。

1. 認証情報を含むバックアップの安全性
2. SMB・動画・サムネイル処理の実機安定性
3. Firebase、匿名Telemetry、プライバシー申告の整合
4. 本番ビルド、アイコン、審査用設定
5. ストア掲載物、審査手順、サポート情報

初回リリースでは機能追加を抑え、P0をすべて完了してからRelease配布確認へ進む。市場検証目的の外部TestFlight募集は必須にしない。P1は原則として審査提出前に完了し、P2は1.0後へ送ってよい。

## 調査時点で確認できたこと

### 実装済み

- iPhone / iPad、iOS 17以上を対象としている
- SMB、ローカルフォルダ、フォトライブラリの閲覧導線がある
- AVPlayer / MobileVLCKit による動画再生、画像、PDF、履歴、リストがある
- StoreKit 2 の非消耗型「広告削除」、購入復元、権利監視の土台がある
- Firebase Analytics / Crashlytics と Google Mobile Ads SDK を組み込んでいる
- Keychain、OSSライセンス画面、バックアップ・復元機能がある
- 単体テストは約400個の検証記述があり、主要ViewModelと再生周辺の一部をカバーしている
- 2026-07-11時点の環境は Xcode 26.6。現在の提出要件である Xcode 26 / iOS 26 SDK 以上を満たせる

### リリース不足として確認できた事実

- `AppDataBackupService` はSMBの共有名、ユーザー名、パスワードを平文JSONへ書き出す。自動バックアップ、外部書き出し、共有の対象にもなる
- Google Mobile AdsはアプリID、バナーIDともGoogle公式テストIDのまま
- UMP同意取得、ATT方針、広告・解析収集のユーザー向け説明が未実装
- アプリ内にプライバシーポリシー、サポート、利用条件へのリンクがない
- アプリ独自の `PrivacyInfo.xcprivacy` がない
- Firebase / Crashlyticsへ送るイベントとログのデータ分類が未整理
- Release設定の `DEVELOPMENT_TEAM` が空で、本番ArchiveとApp Store Connectアップロードが未確認
- App Icon 3種はいずれも1024pxだがアルファチャンネルを持つ
- 日本語UIがハードコードされている一方、`en`を対応言語として宣言している
- StoreKit商品のApp Store Connect登録、Sandbox購入、復元、広告即時非表示が未確認
- 既知の `EXC_BAD_ACCESS` とSMBサムネイル停止について実機の再発なし確認が終わっていない
- ファイル名、パス、接続表示名を含み得る大量の診断ログがReleaseでも有効である
- OSS画面はライセンス名だけで、ライセンス本文、著作権表示、ソース・再リンク要件の確認結果がない
- App Store Connect用の説明文、キーワード、スクリーンショット、サポートURL、審査メモ、年齢区分等が未整理

## 優先順位

### P0: 審査提出前の必須項目

#### P0-1 バックアップから平文認証情報を排除する

状態: 実装・対象テスト完了（2026-07-11）。外部へ過去に共有済みのバックアップはアプリから回収できないため、利用者への注意喚起方針は引き続き必要。

現状はKeychainで保護しているNASパスワードを、バックアップ時に平文JSONへ戻している。さらに自動保存と共有が可能なため、端末外やiCloudバックアップへ意図せず流出する可能性がある。

初回リリースの最小安全策は、バックアップ対象からパスワードを外し、復元後に利用者へ再入力してもらう方式である。認証情報込みバックアップが必須なら、利用者が指定するパスフレーズで暗号化し、平文ファイルを生成しない設計が必要になる。1.0では前者を推奨する。

完了条件:

- 自動・手動・復元前バックアップのすべてにパスワードが入らない
- 既存の平文バックアップが端末内に残る場合の削除または警告方針がある
- 復元後の認証情報再入力フローを実機確認する
- バックアップの回帰テストでパスワード文字列が含まれないことを確認する

実装結果:

- 新規バックアップには共有名だけを残し、ユーザー名・パスワードを含む`credential`を出力しない
- アプリ起動時の自動バックアップ判定前に、端末内の旧バックアップから`credential`を除去する
- 旧バックアップの共有名は非機密フィールドへ移し、接続編集時の再入力を助ける
- 復元後はNASパスワードをKeychainへ復元せず、設定画面で再入力が必要だと表示する
- 新規出力、旧形式移行、復元後の再入力を対象とする3テストを追加した

#### P0-2 既知クラッシュとSMB処理停止を解消する

現在の作業メモには、サムネイル生成中の `EXC_BAD_ACCESS`、libsmb2の競合、完了しない処理が残っている。App Review Guideline 2.1は端末上の安定性と完成状態を要求するため、再現率が低くても未確認のまま提出しない。

完了条件:

- 画面内に複数のSMB動画がある状態で連続スクロール、戻る、再入場を30分以上実施してクラッシュしない
- 応答しないファイルを混ぜても後続サムネイルとブラウズ操作が止まらない
- MP4 / MOV / M4V、MKV、4K / HEVC、長時間動画で再生・シーク・閉じる・再開が破綻しない
- バックグラウンド往復、ネットワーク切断、NAS停止後に音声残りやハングがない
- Release構成の実機確認で新規クラッシュがなく、同意時はCrashlyticsへ匿名の障害情報が届く

#### P0-3 プライバシーと匿名Telemetryを1つの方針へ揃える

方針更新（2026-07-11）: 1.0は完全無料・広告なし・課金なしとする。Firebase AnalyticsとCrashlyticsだけを明示同意後に使用し、広告連携、IDFA、クロスアプリ追跡は行わない。実装計画は`docs/free-analytics-implementation-plan.md`を参照する。

Google Mobile AdsとStoreKit課金を削除し、Firebase Analytics / Crashlyticsを製品改善目的に限定する。SDKの実際の収集内容を確認し、実装・ポリシー・App Store Connectの回答を一致させる。

完了条件:

- 公開URLを持つプライバシーポリシーを作成し、設定画面から開ける
- ポリシーに解析、クラッシュ、端末内データ、NAS認証情報、写真権限、問い合わせ方法、送信停止方法を書く
- App Store ConnectのApp Privacy回答をSDKを含めて確定する
- アプリ本体と各SDKを含むPrivacy ReportをArchiveから生成・確認する
- 必要な `PrivacyInfo.xcprivacy` とRequired Reason API宣言を追加する
- Firebase / Crashlyticsのログからファイル名、パス、NAS名、URL等を除去または不可逆化する
- Releaseの詳細ログを無効化し、エラー種別と匿名の性能値だけを残す
- Google Mobile Ads、UMP、StoreKit課金コードがアプリと依存関係から消えている
- Analytics / Crashlyticsは利用者の明示同意後だけ有効になる
- IDFA、広告パーソナライズ、ATTを使用しない
- 同意拒否、Firebase未設定、オフラインでも主要機能が動く

#### P0-4 広告・課金機能を削除する

状態: 方針決定、未実装。`docs/free-analytics-implementation-plan.md`のフェーズ1として実施する。

完了条件:

- Google Mobile Ads、UMP、AdMob ID、広告Viewがない
- StoreKit購入サービス、商品ID、購入・復元UIがない
- Homeと設定画面に削除後の余白や不要状態がない
- READMEとストア説明が完全無料・広告なし・課金なしになっている

#### P0-5 配布用Archiveを成立させる

完了条件:

- Apple Developer Program、契約、税務、銀行情報、Bundle ID、App Store Connectアプリレコードを準備する
- `DEVELOPMENT_TEAM`、Release署名、Version / Build番号を確定する
- Xcode 26以上とiOS 26 SDK以上でGeneric iOS Device向けArchiveを作る
- Validate AppとApp Store Connectアップロードを通す
- Ad Hoc / TestFlightでRelease設定の起動を確認する
- App Iconのアルファチャンネルを除去し、Archive検証を通す
- Firebaseの本番plistとCrashlytics dSYMアップロードをRelease Archiveで確認する
- SMB暗号化とFirebaseを踏まえて輸出コンプライアンス質問へ回答し、必要な `ITSAppUsesNonExemptEncryption` の値を確定する

#### P0-6 OSSライセンスと配布条件を満たす

特にバイナリで同梱するMobileVLCKitについて、採用している正確なバージョン、著作権表示、LGPLのライセンス本文、改変有無、ソース入手方法、再リンク可能性など配布条件を確認する。AMSMB2、Firebase、Google Mobile Adsと推移依存もArchive単位で棚卸しする。

完了条件:

- アプリ内または同梱文書からライセンス本文と著作権表示を確認できる
- URL文字列を保持するだけでなく、利用者がソース・ライセンス情報へ到達できる
- MobileVLCKitバイナリの作成元、バージョン、対応ソースを記録する
- App StoreのDRMや配布形態とLGPL条件の両立を確認する。不明点は専門家または権利者へ確認する

#### P0-7 審査担当者が主要機能を再現できるようにする

審査環境から個人宅NASへは接続できない。NAS接続がない状態でもアプリの価値と安定性を確認できる導線が必要である。

完了条件:

- 初回起動時に「NAS」「このiPhone/iPad内」「写真」の使い分けが分かる
- Filesまたは写真だけでブラウズ、再生、履歴、リストを確認できる手順を用意する
- 必要なら個人情報を含まない同梱サンプルまたはデモモードを用意する
- App Review Notesにローカルネットワーク権限、写真権限、匿名Telemetry、確認手順を具体的に書く
- 特殊環境が必要な挙動は審査添付動画で補足する

#### P0-8 App Store Connectの提出必須項目を完成させる

完了条件:

- アプリ名、サブタイトル、説明、キーワード、カテゴリ、著作権、サポートURL、プライバシーポリシーURLを設定する
- iPhone / iPadの必要サイズのスクリーンショットを用意する
- 年齢区分の最新質問、コンテンツ権利、広告の有無へ回答する
- 対応国、価格、リリース方式、問い合わせ先を決める
- Review連絡先、審査メモ、IAP審査画像を設定する
- リンク切れ、仮文言、テスト広告、デバッグ画面がないことを最終確認する

### P1: 1.0品質として審査前に完了したい項目

#### P1-1 対応言語の宣言を実装に合わせる

現在は英語対応を宣言しているが、UI文字列はほぼ日本語にハードコードされている。1.0の最小差分は日本語のみとして `en` 宣言を外すこと。英語圏へ配信するなら、`Localizable.xcstrings`等へ移行して英語UI、権限文言、ストア説明、スクリーンショットまで揃える。

#### P1-2 権限拒否と初回体験を整える

- ローカルネットワーク拒否時に設定アプリへの案内を出す
- 写真拒否・限定アクセス時に状態と再設定方法を説明する
- NAS未登録、履歴なし、リストなし、オフラインの空状態から次の操作が分かるようにする
- 認証失敗、共有名誤り、タイムアウトを利用者向け文言へ統一する

#### P1-3 アクセシビリティと端末差を確認する

- VoiceOverでアイコンボタン、サムネイル、シーク操作、同意画面、モーダルを操作できる
- Dynamic Type最大付近で購入、接続入力、設定、エラー表示が欠けない
- 44pt以上の操作領域、十分なコントラスト、Reduce Motionを確認する
- iPhone小画面、iPhone大画面、iPad mini、iPad大画面で縦横・Split Viewを確認する

#### P1-4 リリース候補の試験表を固定する

- Debug単体テストだけでなく、Release構成の実機スモークテストを作る
- 権限、Telemetry同意、バックアップ、SMB方言、動画形式、低速回線、容量不足、メモリ警告を表で管理する
- Release構成を内部TestFlightまたは同等の実機配布で確認する
- 「重大クラッシュ0、データ消失0、購入不能0」を提出判定基準にする

#### P1-5 サポートと運用を準備する

- サポートページに連絡先、FAQ、対応NAS/形式、既知制約を書く
- Crashlyticsアラート、問い合わせ対応、緊急時の公開停止判断を決める
- 段階的リリースを使い、公開後24時間・72時間・7日でクラッシュとレビューを確認する
- 1.0.1をすぐ出せるVersion / Build運用を決める

### P2: 1.0後へ送ってよい項目

- 英語を含む本格的な多言語対応
- 高度な検索、zip、EPUB、クラウドサービス直結
- Chromecast、強力なアプリロック、ファイル暗号化
- 動画スクラブやサムネイル品質の追加最適化
- 大規模なUIリファクタリング

P2を理由にP0/P1の完了を遅らせない。

## 推奨する実施順序

1. P0-1 平文認証情報バックアップを修正する
2. P0-2 現在のSMBサムネイルクラッシュを実機で収束させる
3. P0-3 プライバシー・匿名Telemetry・ログ方針を確定して実装する
4. P0-4 広告・課金コードとSDKを削除する
5. P0-5 / P0-6 Release Archiveとライセンスを検証する
6. P0-7 審査再現手順、P0-8 ストア情報を作る
7. P1の権限、アクセシビリティ、端末マトリクスを確認する
8. Release構成の実機確認を完了し、重大問題が0のビルドだけを提出する

## Go / No-Go 判定

次をすべて満たした場合だけ審査へ提出する。

- P0が全項目完了している
- Release ArchiveのValidateとアップロードが成功している
- 平文パスワードを含む新規バックアップが生成されない
- プライバシーポリシー、実装、Privacy Manifest、App Privacy回答が一致している
- 広告・課金がなく、同意式の匿名Analytics / Crashlyticsだけが動く
- 主要実機シナリオでクラッシュ、ハング、データ消失がない
- 審査担当者がNASなしでも主要導線を確認できる
- ストア画像、説明、URL、審査情報に仮データがない

## Apple公式資料

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App Reviewでよくある問題](https://developer.apple.com/app-store/review/)
- [App Privacyの管理](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [Privacy Manifestの追加](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [App Store Connectの必須項目](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)
- [初回In-App Purchaseの提出](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase)
- [輸出コンプライアンス概要](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [今後・現在の提出要件](https://developer.apple.com/news/upcoming-requirements/)

## 注意

本書は技術・審査準備の観点による整理であり、法的助言ではない。プライバシーポリシー、Analytics同意、輸出規制、LGPLの最終判断は、配信地域と実際のSDK設定を確定した後に必要に応じて専門家へ確認する。
