# コーデック対応方針

## 採用方針

PFile では、動画再生エンジンとして VLCKit を使用する。

理由:

- NAS 上の動画で使われやすい MKV、AVI、TS などを扱いやすい
- AVFoundation より対応コンテナ・コーデックの範囲が広い
- App Store 配布可能な OSS ライブラリとして利用できる

---

## AVFoundation との違い

AVFoundation は Apple 標準の再生機能で、追加コストなしで利用できる。
一方で、対応形式は Apple プラットフォームで一般的な形式が中心になる。

主な対応形式:
- コンテナ: MP4、MOV、M4V
- 映像コーデック: H.264、H.265/HEVC（iPhone 6s以降）、AV1（ハードウェア対応機種のみ）、MPEG-4
- 音声コーデック: AAC、MP3、ALAC、PCM

扱いにくい形式:
- MKVコンテナ（中身がH.264でもNG）
- AVI、WMV、FLV
- DivX、Xvid
- AC3/DTS音声

NAS に置いた動画は形式が混在しやすいため、PFile では AVFoundation だけに依存しない。

## VLCKit

VLCKit は VideoLAN の iOS 向け再生ライブラリ。

主な特徴:

- MKV、AVI、FLV、DivX、Xvid、OGG、WMV など幅広い形式に対応
- CocoaPods 経由で導入できる
- LGPL ライセンスに基づく OSS ライブラリ

## VLCKitの導入時の注意点

- SPMに対応していないためCocoaPodsまたは手動でバイナリフレームワークを組み込む
- OSSライセンス表示画面を設ける（About画面またはSettings内）
- VLCKitのバージョンと対応iOSバージョンを都度確認する

## 参考リンク

- [Apple AV1 Support - Bitmovin](https://bitmovin.com/blog/apple-av1-support/)
- [VLCKit GitHub](https://github.com/videolan/vlckit)
- [LGPLとApp Storeの互換性](https://jbkempf.com/blog/How-to-properly-relicense-a-large-open-source-project-part-3/)
