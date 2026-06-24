# NAS 動画再生方式調査

> 注記：これは調査段階のメモです。最終的な実装はこのドキュメントの結論と異なります。MP4/MOV系はAVPlayer（SMBResourceLoaderDelegate + AMSMB2によるバイト範囲読み込み）で再生し、VLCKitはMKVなど非対応フォーマットのフォールバックとして使用しています。

## 目的

NAS 上の大きい動画ファイルを iPhone / iPad で安定して再生するため、PFile で採用する再生経路を整理する。

重視する点:

- 通常再生中に停止しにくいこと
- シーク操作が実用的に反応すること
- 日本語ファイル名や認証付き SMB でも扱いやすいこと
- アプリ側の保守範囲が大きくなりすぎないこと

## 結論

PFile の動画再生は MobileVLCKit に `smb://` URL を直接渡す direct SMB 経路を優先する。

```text
VLCMedia(url: smb://<host>/<share>/<path>/video.mp4)
  -> MobileVLCKit / libVLC
    -> SMB 入力
    -> libVLC 側の demux / seek / cache
```

direct SMB 経路を優先する理由:

- VLC / libVLC の想定するネットワーク入力に近い
- アプリ側で自前の `InputStream` を組むより、seek / buffer / demux の境界をプレイヤー側に任せられる
- HTTP Range プロキシより実装範囲が小さい
- シークバー操作中の映像追従を保ちやすい

## キャッシュ方針

`network-caching` を大きくしすぎると通常再生は止まりにくくなる一方、シーク操作の追従が鈍くなる。

PFile では次のように分けて扱う。

- `network-caching`: 中低めに抑える
- `smb-caching`: 厚めにする
- `file-caching`: 厚めにする
- シーク操作: ドラッグ中の seek を短い間隔で間引く

## HTTP Range プロキシの位置付け

HTTP Range プロキシは、iOS 標準プレイヤーや自前 SMB 読み込みをプレイヤーへ渡すための現実的な方法。
ただし PFile が MobileVLCKit を使う前提では、最初の選択肢にはしない。

HTTP Range プロキシが必要になる条件:

- direct SMB が端末や NAS との相性で安定しない
- HTTP request 単位で読み込みを観測・制御したい
- アプリ側で SMB read の retry / timeout / cache を細かく制御したい

## 採用しない方式

`VLCMedia(stream:)` に自作 `InputStream` を渡す方式は本線にしない。

理由:

- VLC 側の seek / read 要求が HTTP Range のように明示されない
- buffer 状態と読み込み状態の境界を観測しづらい
- プレイヤーの想定入力から外れやすい
- 小さな調整で安定化するより、入力経路自体を見直す方が保守しやすい

## 参考リンク

- [VLC for iOS SMB documentation](https://docs.videolan.me/vlc-user/ios/3.X/en/advanced/network_shares/smb.html)
- [VLC Android README / LibVLC network browsing](https://github.com/videolan/vlc-android)
- [Infuse: Streaming From a Mac, PC, or NAS](https://support.firecore.com/hc/en-us/articles/215090977-Streaming-From-a-Mac-PC-or-NAS)
- [Kodi Wiki: Settings/Services/Caching](https://kodi.wiki/view/Settings/Services/Caching)
- [VLCKit Issue: Double percent-encoding required for paths](https://code.videolan.org/videolan/VLCKit/-/issues/45)
- [VLCKit Issue: SMB subtitle with same filename](https://code.videolan.org/videolan/VLCKit/-/issues/208)
