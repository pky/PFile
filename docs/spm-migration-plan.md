# SPM 移行結果

## 現状

PFile は CocoaPods を使わない。
依存関係は SPM と直接参照する XCFramework で管理する。

SPM 管理の依存:

- `FirebaseAnalytics`
- `FirebaseCrashlytics`
- `GoogleMobileAds`
- `AMSMB2`

直接参照するバイナリ:

- `MobileVLCKit 3.7.2`

## MobileVLCKit

`MobileVLCKit` は公式 SPM package がないため、SPM `binaryTarget` 化を検証した。
ローカル Swift package と XcodeGen の組み合わせでは、Xcode GUI で `Missing package product 'MobileVLCKit'` になった。

そのため、現在は `scripts/prepare-mobilevlckit-binary.sh` で `Packages/MobileVLCKitBinary/Artifacts/MobileVLCKit.xcframework` を取得し、`project.yml` から直接 link / embed する。

この方式では `PFile.xcodeproj` 単体でビルドする。
workspace は使わない。

## 更新手順

`MobileVLCKit` を更新するときは、`scripts/prepare-mobilevlckit-binary.sh` の次の値を更新する。

- `VERSION`
- `ARCHIVE_NAME`
- `ARCHIVE_SHA256`

更新後、既存の `Packages/MobileVLCKitBinary/Artifacts/` を消してから `make setup` を実行する。

確認項目:

- `xcodegen generate`
- `xcodebuild -project PFile.xcodeproj -scheme PFile -destination 'generic/platform=iOS' -configuration Debug CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- 実機で NAS 動画再生
- 実機でローカル動画再生
- シーク
- サムネイル生成

## ライセンス

`MobileVLCKit` は LGPL v2.1 のため、ライセンス表示とソース提供導線を維持する。
