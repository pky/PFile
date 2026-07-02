# SPM 移行計画

## 背景

CocoaPods は 2024-08-13 の公式発表で maintenance mode とされている。
今後の依存管理は Swift Package Manager を基本に寄せ、CocoaPods 依存を段階的に減らす。

現在の CocoaPods 依存は次の 4 件。

- `FirebaseAnalytics`
- `FirebaseCrashlytics`
- `Google-Mobile-Ads-SDK`
- `MobileVLCKit`

## 方針

一括移行は避け、影響範囲が小さい依存から SPM 化する。
動画再生の中核である `MobileVLCKit` は最後に単独検証する。

## 参照する公式情報

- CocoaPods support plans: `https://blog.cocoapods.org/CocoaPods-Support-Plans/`
- CocoaPods trunk read-only plan: `https://blog.cocoapods.org/CocoaPods-Specs-Repo/`
- Firebase Apple SDK: `https://github.com/firebase/firebase-ios-sdk`
- Firebase iOS setup: `https://firebase.google.com/docs/ios/setup`
- Google Mobile Ads SPM: `https://github.com/googleads/swift-package-manager-google-mobile-ads`
- Google Mobile Ads iOS quick start: `https://developers.google.com/admob/ios/quick-start`
- VLCKit: `https://github.com/videolan/vlckit`
- MobileVLCKit Carthage binary manifest: `https://raw.githubusercontent.com/videolan/vlckit/master/Packaging/MobileVLCKit.json`

## フェーズ

### 1. Firebase を SPM 化

対象:

- `FirebaseAnalytics`
- `FirebaseCrashlytics`

作業:

- `project.yml` の `packages` に `firebase-ios-sdk` を追加する。
- `PFile` target の dependencies に `FirebaseAnalytics` と `FirebaseCrashlytics` を追加する。
- `Podfile` から Firebase の 2 pod を削除する。
- Crashlytics dSYM upload script を CocoaPods の `${PODS_ROOT}` 参照から SPM 用に変更する。

確認:

- `xcodegen generate`
- `pod install`
- `xcodebuild -workspace PFile.xcworkspace -scheme PFile -destination 'generic/platform=iOS' -configuration Debug CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- `FirebaseSupport.swift` が import / compile できること。

戻し方:

- `project.yml` の Firebase package / dependencies を戻す。
- `Podfile` の Firebase pod を戻す。
- `pod install` を再実行する。

### 2. Google Mobile Ads を SPM 化

対象:

- `Google-Mobile-Ads-SDK`

作業:

- `project.yml` の `packages` に Google Mobile Ads SPM package を追加する。
- `PFile` target の dependencies に `GoogleMobileAds` を追加する。
- `Podfile` から `Google-Mobile-Ads-SDK` を削除する。

確認:

- `AdBannerView.swift` と `PFileApp.swift` が import / compile できること。
- 実機で広告 SDK 初期化とバナー表示に問題がないこと。

戻し方:

- `project.yml` の Google Mobile Ads package / dependency を戻す。
- `Podfile` の `Google-Mobile-Ads-SDK` を戻す。
- `pod install` を再実行する。

### 3. MobileVLCKit を SPM 化できるか検証

対象:

- `MobileVLCKit`

背景:

- CocoaPods trunk は 2026-12-02 に read-only へ移行予定。
- 既存の `MobileVLCKit 3.7.2` は取得できる見込みだが、trunk 経由の新規バージョン追加は止まる。
- VideoLAN の `vlckit` は公式 README で CocoaPods / Carthage を案内している。
- 2026-07-02 時点で、公式ミラーのルートに `Package.swift` は見当たらない。

作業:

- 公式または実運用に耐える SPM 配布があるか確認する。
- SPM 化できる場合、別ブランチ相当の小さい差分で `MobileVLCKit` だけを切り替える。
- SPM 化できない、または実機再生が不安定な場合は `MobileVLCKit` だけ CocoaPods 継続を許容する。

確認:

- NAS 動画再生
- ローカル動画再生
- シーク
- サムネイル生成
- 動画終了時の `vp_memory` ログ
- 実機 Debug build

判断基準:

- 再生互換性が落ちる場合は移行しない。
- App Store 配布に必要な埋め込み、署名、アーキテクチャが不安定な場合は移行しない。
- `MobileVLCKit` だけ CocoaPods に残しても、Firebase / Ads を SPM 化できていれば移行価値はある。

#### MobileVLCKit の選択肢

##### A. CocoaPods 継続

概要:

- 現状維持。
- `MobileVLCKit 3.7.2` を CocoaPods から使い続ける。

利点:

- 最も安全。
- 既存の動画再生、サムネイル生成、署名、埋め込み方式を変えない。
- すでに `BUILD SUCCEEDED` を確認済み。

欠点:

- CocoaPods trunk read-only 後は、新しい `MobileVLCKit` が trunk に追加されなくなる。
- 将来の更新経路が弱い。
- CocoaPods を完全削除できない。

採用条件:

- 2026-12-02 までの暫定対応。
- `MobileVLCKit` の更新頻度が低く、当面 `3.7.2` 固定で問題ない場合。

##### B. Carthage へ移行

概要:

- VideoLAN が提供する `Packaging/MobileVLCKit.json` を使い、Carthage binary として取得する。
- CocoaPods trunk には依存しない。

利点:

- VideoLAN の README に導入手段として記載がある。
- CocoaPods を削除できる可能性がある。
- 公式 SPM がない状況では、上流の案内に近い移行先。

欠点:

- SPM ではない。
- `xcodegen` で framework embed / link / search paths を明示管理する必要がある。
- CI や初回セットアップに `carthage bootstrap` が増える。

検証手順:

1. `Cartfile` に iOS 用 `MobileVLCKit.json` を追加する。
2. `carthage bootstrap --use-xcframeworks --platform iOS` が使えるか確認する。
3. 生成物を `project.yml` の framework dependency として link / embed する。
4. `Podfile` から `MobileVLCKit` を削除する。
5. `xcodegen generate` を実行する。
6. `xcodebuild -project PFile.xcodeproj ... build` を確認する。
7. 実機で NAS / ローカル動画再生、シーク、サムネイル生成を確認する。

採用条件:

- `MobileVLCKit.framework` または `MobileVLCKit.xcframework` が安定して取得できる。
- 実機再生と App Store 向け埋め込みに問題がない。

##### C. 自前 SPM binaryTarget 化

概要:

- VideoLAN の配布バイナリを元に、PFile 用または社内用の Swift package を作る。
- `binaryTarget` として `MobileVLCKit` を取り込む。

利点:

- 最終的に依存管理を SPM に寄せられる。
- CocoaPods と Carthage の両方を削除できる可能性がある。
- `project.yml` の package dependency として管理できる。

欠点:

- 公式 SPM ではない。
- 配布形式が SPM の `binaryTarget` 要件に合わない場合、再パッケージが必要。
- checksum、更新手順、署名、ライセンス表記、配布 URL を自分で管理する必要がある。
- VideoLAN の配布物が tar.xz の場合、SPM 用 zip / xcframework 化の手順が別途必要。

検証手順:

1. `MobileVLCKit 3.7.2` の配布アーカイブを取得する。
2. 中身が `.xcframework` か、通常の `.framework` か確認する。
3. `.framework` のみの場合、iOS device / simulator 対応を確認し、必要なら `.xcframework` 化する。
4. `.xcframework` を zip 化する。
5. `swift package compute-checksum` で checksum を計算する。
6. `Package.swift` に `binaryTarget(name:url:checksum:)` を定義する。
7. `project.yml` にその package を追加する。
8. `Podfile` から `MobileVLCKit` を削除する。
9. `xcodegen generate` を実行する。
10. `xcodebuild -project PFile.xcodeproj ... build` を確認する。
11. 実機で NAS / ローカル動画再生、シーク、サムネイル生成を確認する。
12. ライセンス表示とソース提供導線を確認する。

採用条件:

- SPM の `binaryTarget` としてビルドできる。
- 実機再生が CocoaPods 版と同等。
- 更新手順をドキュメント化できる。

##### D. 手動 vendored framework 管理

概要:

- `Vendor/MobileVLCKit/` のようなディレクトリに framework を置き、`project.yml` で link / embed する。

利点:

- CocoaPods trunk に依存しない。
- SPM binaryTarget が難しい場合でも実装できる可能性が高い。
- 取得元を固定できる。

欠点:

- バイナリをリポジトリに含める場合、リポジトリサイズが大きくなる。
- Git LFS や外部ダウンロード script が必要になる可能性がある。
- 更新作業が手動になりやすい。

検証手順:

1. VideoLAN の配布アーカイブを取得する。
2. `Vendor/MobileVLCKit/` に配置するか、取得 script を用意する。
3. `project.yml` で framework を link / embed する。
4. `Podfile` から `MobileVLCKit` を削除する。
5. `xcodegen generate` を実行する。
6. `xcodebuild -project PFile.xcodeproj ... build` を確認する。
7. 実機で動画再生系を確認する。

採用条件:

- SPM binaryTarget 化が失敗し、Carthage も運用したくない場合。
- バイナリ管理の運用ルールを決められる場合。

##### E. AVPlayer へ寄せて MobileVLCKit を廃止

概要:

- `MobileVLCKit` を削除し、AVFoundation / AVPlayer だけで動画再生する。

利点:

- 外部動画再生 SDK が不要になる。
- CocoaPods を完全削除できる。
- Apple 標準 API のみになる。

欠点:

- MKV / AVI / TS など、AVFoundation が苦手な形式の互換性が落ちる可能性が高い。
- 現在の PFile の用途と衝突する可能性がある。
- `VLCMediaThumbnailer` を使うサムネイル生成も置き換えが必要。

検証手順:

1. 実ユーザーが扱う代表動画形式を一覧化する。
2. AVPlayer で再生できる形式とできない形式を実機で確認する。
3. サムネイル生成を `AVAssetImageGenerator` 等へ置き換えられるか確認する。
4. NAS 経由の再生方式を再評価する。

採用条件:

- 対象動画形式を MP4 / MOV など AVFoundation 対応形式へ限定できる場合。
- 互換性低下を仕様として許容できる場合。

#### 推奨順

1. C: 自前 SPM binaryTarget 化を小さく検証する。
2. B: 失敗したら Carthage へ移行できるか検証する。
3. D: Carthage 運用が重ければ vendored framework を検証する。
4. A: どれも不安定なら CocoaPods 継続を期限付きで採用する。
5. E: 互換性要件を下げられる場合のみ検討する。

#### 完了条件

- `Podfile` と `Podfile.lock` を削除できる。
- `xcodegen generate` 後、`PFile.xcodeproj` 単体でビルドできる。
- 実機で NAS 動画再生、ローカル動画再生、シーク、サムネイル生成が通る。
- `vp_memory` ログで動画終了後に `activePlayers: 0` へ戻る。
- ライセンス表記と VLCKit のソース提供導線を確認済み。

### 4. CocoaPods を完全削除

前提:

- Firebase、Google Mobile Ads、MobileVLCKit の全てが SPM で安定すること。

作業:

- `Podfile`、`Podfile.lock`、`Pods/` を削除する。
- `PFile.xcworkspace` が不要になる場合は削除する。
- `PFile.xcodeproj` 単体でビルドできる状態にする。

確認:

- `xcodegen generate`
- `xcodebuild -project PFile.xcodeproj -scheme PFile -destination 'generic/platform=iOS' -configuration Debug CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- 実機で動画再生、広告表示、Firebase 初期化を確認する。

## 当面のゴール

最初のコミットでは Firebase と Google Mobile Ads を SPM に移行し、`MobileVLCKit` は CocoaPods に残す。
これにより、動画再生の中核を変えずに CocoaPods 依存を 4 件から 1 件へ減らす。

## 進捗

2026-06-29 時点で、Firebase と Google Mobile Ads は SPM へ移行済み。
`MobileVLCKit` のみ CocoaPods に残している。

確認済みの解決バージョン:

- Firebase: `12.15.0`
- Google Mobile Ads: `13.6.0`
- MobileVLCKit: `3.7.2`（CocoaPods）

確認済みコマンド:

- `xcodegen generate`
- `pod install`
- `xcodebuild -workspace PFile.xcworkspace -scheme PFile -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath /tmp/PFileSPMMigrationBuild CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

ビルド結果:

- `BUILD SUCCEEDED`
