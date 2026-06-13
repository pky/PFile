# SMB 動画再生実験計画

## 目的

SMB 上の動画で、通常再生の安定性とシークバー操作中の映像追従を両立できる再生方式を比較する。

現状の direct SMB は通常再生の安定性が高い一方、キャッシュを厚くするとシーク追従が悪化する。
今後はキャッシュ値の微調整だけで判断せず、再生経路ごとに同じ指標で比較する。

## 既知の結果

- `VLCMedia(url: smb://...)` の direct SMB は通常再生が最も安定している。
- `network-caching` / `smb-caching` / `file-caching` を厚くすると停止しにくいが、シーク追従が鈍くなる。
- `VLCMedia(stream:)` と自作 `InputStream` は、VLC 側の seek / read 要求が見えにくく、本線から外した。
- 旧 HTTP Range proxy は重い動画で通常再生中に `buffering` 停止が出た。
- 旧 HTTP Range proxy は、古い Range 読み込みをキャンセルして最新 seek を優先する設計ではなかった。
- `AVPlayer + ResourceLoader + AMSMB2` は設計案があるが、現行の動画本再生経路では未採用。

## 評価指標

同じ実機、同じ NAS、同じ動画、同じ Wi-Fi で比較する。

| 指標 | 目標 |
|---|---|
| 通常再生 | 20 分以上停止しない |
| seek 初回反応 | seek 要求から 1 秒以内に映像位置が変わる |
| seek 確定 | 指を離してから 2 秒以内に最終要求位置へ近づく |
| 連続 seek | 10 秒以上ドラッグしても `error` / `stopped` に落ちない |
| 復旧性 | `buffering` に落ちても 5 秒以内に復帰する |

## 共通ログ

再生方式ごとに次のログを比較する。

- `SeekDiag begin`
- `SeekDiag firstResponse`
- `SeekDiag summary`
- `VideoPlayer playback interruption`
- `VideoPlayer State changed`
- `StartupDiag media_attached`

`SeekDiag summary` では次を見る。

- `seekRequests`
- `firstResponseMs`
- `avgLatencyMs`
- `maxLatencyMs`
- `bufferingDuringSeek`
- `finalDeltaSeconds`

## 実験順

### 1. direct SMB 計測強化

現行経路を基準値にする。

確認すること:

- キャッシュ値ごとの通常再生安定性
- キャッシュ値ごとの seek 初回反応
- seek 中に `buffering` へ落ちる頻度

現在の試行:

- 実機ログで、drag 中 100ms 間隔の preview seek は逆効果と判定した
- direct SMB では drag 中の preview seek を止め、指を離した最終位置だけ seek する
- 0.25 秒未満の移動は重複 seek として捨てる

観測ログ:

- `seekRequests: 11` / `dragMs: 1718` で `bufferingDuringSeek: true`
- `firstResponseMs: 7` のため、アプリから VLC への seek 設定自体は遅くない
- 問題は direct SMB + VLCKit が連続 seek 後のデータ取得で `buffering` に落ちること

### 2. HTTP Range proxy v2

`SMBStreamingServer` を動画本再生向けに分離し、最新 seek を優先する。

現在の試行:

- 実機の動画本再生を `http_proxy_v2` 優先に切り替える
- proxy 準備失敗時だけ direct SMB に fallback する
- 新しい Range GET が来たら古い GET task / connection をキャンセルする
- Range 先頭は 256KB、その後の小さい Range は 512KB、通常読み込みは最大 2MB chunk にする
- `SMBStreamingServer` の Range / cancel / active request ログで挙動を確認する

合格条件:

- direct SMB より seek 初回反応が良い
- 通常再生で旧 proxy のような長時間 `buffering` 停止が出ない

### 3. AVPlayer + ResourceLoader + AMSMB2

MP4 / MOV 系の比較候補として試す。

確認すること:

- seek 反応が VLC direct SMB より良いか
- 再生可能形式の範囲
- MKV / AVI / TS などを VLC fallback にできるか

### 4. direct SMB のモード切り替え

通常再生は安定寄り、seek 中だけ軽量設定で再アタッチできるかを試す。

懸念:

- media 再アタッチ自体が重い場合、追従改善にならない
- seek 中の再生状態管理が複雑になる

### 5. シーク中プレビュー

本再生は direct SMB のまま維持し、drag 中だけ別経路でフレームプレビューを出す。

位置付け:

- 再生経路の根本改善ではない
- 体感改善としては有効な可能性がある

## 判定方針

通常再生の安定性を最優先にする。
ただし、安定性のために seek 追従が完全に失われる方式は本線にしない。

最終的には次のどちらかを採用する。

- 単一経路で安定性と seek 追従を両立できる方式
- direct SMB を安定再生用に残し、seek / preview だけ別経路に逃がす方式
