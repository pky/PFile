# アーキテクチャ設計

## 全体方針

MVVM + Repository パターンを採用する。

```
View
  ↕ @State / @Binding / @Observable
ViewModel
  ↕ Protocol
Repository / Service
  ↕ Protocol
DataSource（SMB / SwiftData / Cache / Keychain）
```

各レイヤーはProtocolで抽象化し、テストやモック差し替えを容易にする。

---

## レイヤー定義

| レイヤー | 責務 | 依存先 |
|---|---|---|
| View | SwiftUIによるUI描画のみ。ロジックを持たない | ViewModel |
| ViewModel | 状態管理・ビジネスロジック・ViewへのデータI/O | Repository / Service |
| Repository | データ取得・保存の抽象化（Protocol定義） | DataSource |
| Service | 横断的な処理（サムネイル生成・先読み・並び替え） | DataSource |
| DataSource | 具体的な実装（SMB・SwiftData・Keychain・キャッシュ） | 外部 |

---

## 状態管理

- `@Observable` マクロをViewModelに適用（iOS 17以上）
- `@State` / `@Binding` でView内ローカル状態を管理
- NAS接続状態など複数Viewで共有する状態は `@Environment` で注入

---

## 非同期処理

- Swift Concurrency（async/await）を基本とする
- Combineは使わない（async/awaitに統一）
- バックグラウンド処理は `Task` + 低優先度（`.background` または `.utility`）で実行

---

## ファイル構成

```
PFile/
├── App/
│   ├── PFileApp.swift              // アプリエントリーポイント
│   └── AppEnvironment.swift        // @Environmentで注入するグローバル状態
│
├── Features/                       // 画面単位のまとまり
│   ├── Home/
│   │   ├── HomeView.swift
│   │   └── HomeViewModel.swift
│   ├── Connection/
│   │   ├── ConnectionAddView.swift
│   │   └── ConnectionAddViewModel.swift
│   ├── FileBrowser/
│   │   ├── FileBrowserView.swift
│   │   ├── FileBrowserViewModel.swift
│   │   └── BreadcrumbView.swift
│   ├── VideoPlayer/
│   │   ├── VideoPlayerView.swift
│   │   ├── VideoPlayerViewModel.swift
│   │   └── PlayerControlsView.swift
│   ├── MediaList/
│   │   ├── MediaListsView.swift
│   │   ├── MediaListDetailView.swift
│   │   └── AddToListSheet.swift
│   ├── PhotoLibrary/
│   │   └── PhotoLibraryBrowserView.swift
│   └── WatchHistory/
│       ├── WatchHistoryListView.swift
│       └── WatchHistoryListViewModel.swift
│
├── Domain/
│   ├── Models/                     // データ構造の定義
│   │   ├── RemoteConnection.swift
│   │   ├── MediaList.swift
│   │   ├── MediaFile.swift
│   │   ├── WatchHistory.swift
│   │   └── DirectoryItem.swift
│   └── Repositories/              // Protocolのみ（実装はInfrastructureに）
│       ├── MediaListRepository.swift
│       ├── WatchHistoryRepository.swift
│       └── FileRepository.swift
│
├── Infrastructure/                 // 具体的な実装
│   ├── SMB/
│   │   ├── SMBClientManager.swift
│   │   └── SMBFileRepository.swift
│   ├── SwiftData/
│   │   ├── MediaListRepositoryImpl.swift
│   │   └── WatchHistoryRepositoryImpl.swift
│   └── Keychain/
│       └── KeychainService.swift
│
├── Services/
│   ├── ThumbnailService.swift
│   ├── PrefetchManager.swift
│   └── SortService.swift
│
└── Shared/
    ├── Extensions/
    ├── Components/                 // 再利用可能なSwiftUIコンポーネント
    │   ├── AdBannerView.swift
    │   └── BreadcrumbView.swift
    └── Constants.swift
```

---

## 依存関係の注入

ViewModelの初期化時にRepositoryをイニシャライザで注入する。
DIコンテナは使わず、`AppEnvironment` からシングルトンとして提供する。

```
AppEnvironment
  ├── mediaListRepository: MediaListRepository
  ├── watchHistoryRepository: WatchHistoryRepository
  ├── smbClientManager: SMBClientManager
  ├── thumbnailService: ThumbnailService
  └── prefetchManager: PrefetchManager
```

---

## 最小対応OS

iOS 17以上（SwiftData・@Observable・NavigationSplitView対応）
