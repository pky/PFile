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
- Firebase Apple SDK: `https://github.com/firebase/firebase-ios-sdk`
- Firebase iOS setup: `https://firebase.google.com/docs/ios/setup`
- Google Mobile Ads SPM: `https://github.com/googleads/swift-package-manager-google-mobile-ads`
- Google Mobile Ads iOS quick start: `https://developers.google.com/admob/ios/quick-start`

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
