# パフォーマンス目標

| 項目 | 目標値 |
|---|---|
| アプリ起動からホーム表示 | 1秒以内 |
| ディレクトリ一覧の表示 | 2秒以内 |
| サムネイルの初回表示 | 3秒以内（キャッシュ済みは即時） |
| 動画の再生開始 | 2秒以内（先読み済みは即時） |

---

## 計測方針

- 実機（iPad mini）でWi-Fi経由のNAS接続環境で計測する
- Xcodeのインストゥルメンツ（Time Profiler / Network）を使用
- 目標未達の場合はプロファイリングで原因を特定してから最適化する

---

## SMB動画再生の整理

### 現状の再生経路

PFile の SMB 動画再生は、実機では VLC に `smb://` を直接渡している。

```text
VLCMedia(url: smb://...)
  -> MobileVLCKit / libVLC
    -> SMB 入力
```

`SMBStreamingServer` はサムネイル生成などで使うが、動画本再生の本線ではない。

現在の direct SMB 再生では、重い動画でも通常再生中に停止しないことを実機で確認済み。
また、重い動画でもシークバー移動中に少しは映像が追従する。

### 切り分け結果

過去の `SMBRangeInputStream` / ローカル HTTP プロキシ経路では、重い動画で以下の傾向が出ていた。

- `positionSeconds: 950-1006` 付近で通常再生中に `buffering` へ落ちる
- `SMBRangeInputStream seek` が複数回出る
- `read attempt failed` は出ない
- HTTP Range 経路では `requestCount`、`lowOffsetRequests`、`directionChanges` が増えやすい

このため、MobileVLCKit / libVLC の direct SMB 入力を本線にする。
`network-caching` は中低めに抑え、`smb-caching` / `file-caching` を厚めにして通常再生の安定性を支える。

### 最優先で見る実装差

現行実装の重要点:

- `VLCMedia(url:)` に direct `smb://` URL を渡す
- `:network-caching=500`
- `:smb-caching=3000`
- `:file-caching=3000`
- `:input-fast-seek`
- `parseNetwork(timeout: 10000)`
- drawable 準備後に再生開始する
- シークバー操作中の seek は約 0.3 秒単位に間引く
- `:start-time` 起動で timeline が取れない場合だけ、10 秒手前から 1 回だけ再試行する

### 運用方針

重い動画の通常再生停止は解消済みとして扱う。
direct SMB を維持し、再生開始時間とシークバー移動中の追従性を計測対象にする。
