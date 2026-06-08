import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    @State private var viewModel: SettingsViewModel?

    @State private var showClearCacheAlert = false
    @State private var showDeleteHistoryAlert = false
    @State private var showRestoreLatestBackupAlert = false
    @State private var showRestoreBackupFileImporter = false
    @State private var showBackupFileExporter = false
    @State private var pendingRestoreBackupURL: URL?
    @State private var pendingExportBackupDocument: BackupJSONDocument?
    @State private var pendingExportBackupFilename = "PFileBackup.json"

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    settingsList(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            let vm = SettingsViewModel(
                watchHistoryRepository: appEnvironment.watchHistoryRepository,
                thumbnailService: appEnvironment.thumbnailService,
                backupService: appEnvironment.appDataBackupService,
                purchaseService: appEnvironment.purchaseService
            )
            viewModel = vm
            await vm.refreshPurchaseState()
        }
    }

    // MARK: - Settings List

    @ViewBuilder
    private func settingsList(viewModel: SettingsViewModel) -> some View {
        List {
            purchaseSection(viewModel: viewModel)
            cacheSection(viewModel: viewModel)
            playbackSection(viewModel: viewModel)
            dataSection(viewModel: viewModel)
            backupSection(viewModel: viewModel)
#if DEBUG
            debugSection(viewModel: viewModel)
#endif
            infoSection(viewModel: viewModel)
        }
        .alert("サムネイルキャッシュを削除", isPresented: $showClearCacheAlert) {
            Button("クリア", role: .destructive) {
                Task { await viewModel.clearThumbnailCache() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("サムネイルキャッシュをすべて削除しますか？次回表示時に再生成されます。")
        }
        .alert("視聴履歴を削除", isPresented: $showDeleteHistoryAlert) {
            Button("すべて削除", role: .destructive) {
                Task { await viewModel.deleteAllWatchHistory() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("すべての視聴履歴を削除しますか？この操作は取り消せません。")
        }
        .alert("接続情報・リスト・履歴を復元", isPresented: $showRestoreLatestBackupAlert) {
            Button("復元", role: .destructive) {
                Task { await viewModel.restoreLatestBackup() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("現在の接続情報、リスト、視聴履歴は復元前データとして退避したうえで、Documents/Backups の最新バックアップから復元します。")
        }
        .alert(
            "接続情報・リスト・履歴を復元",
            isPresented: Binding(
                get: { pendingRestoreBackupURL != nil },
                set: { if !$0 { pendingRestoreBackupURL = nil } }
            )
        ) {
            Button("復元", role: .destructive) {
                guard let pendingRestoreBackupURL else { return }
                Task { await viewModel.restoreBackup(from: pendingRestoreBackupURL) }
                self.pendingRestoreBackupURL = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingRestoreBackupURL = nil
            }
        } message: {
            Text("現在の接続情報、リスト、視聴履歴は復元前データとして退避したうえで、選択したバックアップファイルから復元します。")
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .fileImporter(
            isPresented: $showRestoreBackupFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                pendingRestoreBackupURL = urls.first
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showBackupFileExporter,
            document: pendingExportBackupDocument,
            contentType: .json,
            defaultFilename: pendingExportBackupFilename
        ) { result in
            switch result {
            case .success(let url):
                    viewModel.backupStatusMessage = "接続情報・リスト・履歴を外部へ保存しました: \(url.lastPathComponent)"
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
            pendingExportBackupDocument = nil
        }
    }

    // MARK: - 購入セクション

    @ViewBuilder
    private func purchaseSection(viewModel: SettingsViewModel) -> some View {
        Section("購入") {
            if viewModel.isAdsRemoved {
                Label("広告削除済み", systemImage: "checkmark.seal")
            } else {
                Button {
                    Task { await viewModel.purchaseRemoveAds() }
                } label: {
                    HStack {
                        Label("広告を削除", systemImage: "cart")
                        Spacer()
                        if let price = viewModel.removeAdsDisplayPrice {
                            Text(price)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(viewModel.isPurchasing)
            }

            Button {
                Task { await viewModel.restorePurchases() }
            } label: {
                Label("購入を復元", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isPurchasing)

            if viewModel.isPurchasing {
                ProgressView()
            }

            if let message = viewModel.purchaseStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

#if DEBUG
    // MARK: - デバッグセクション

    @ViewBuilder
    private func debugSection(viewModel: SettingsViewModel) -> some View {
        Section("デバッグ") {
            Toggle("広告を表示", isOn: Binding(
                get: { viewModel.debugShowsAds },
                set: { viewModel.debugShowsAds = $0 }
            ))
        }
    }
#endif

    // MARK: - サムネイルキャッシュセクション

    @ViewBuilder
    private func cacheSection(viewModel: SettingsViewModel) -> some View {
        Section("サムネイルキャッシュ") {
            Picker("容量上限", selection: Binding(
                get: { viewModel.thumbnailCacheLimitMB },
                set: { viewModel.thumbnailCacheLimitMB = $0 }
            )) {
                ForEach(SettingsViewModel.thumbnailCacheLimitOptions, id: \.self) { mb in
                    Text(cacheLimitLabel(mb: mb)).tag(mb)
                }
            }

            Button(role: .destructive) {
                showClearCacheAlert = true
            } label: {
                Label("サムネイルキャッシュを削除", systemImage: "trash")
            }
            .disabled(viewModel.isClearing)
        }
    }

    // MARK: - 再生セクション

    @ViewBuilder
    private func playbackSection(viewModel: SettingsViewModel) -> some View {
        Section("再生") {
            Toggle("再生位置を記憶して再開する", isOn: Binding(
                get: { viewModel.resumePlayback },
                set: { viewModel.resumePlayback = $0 }
            ))

            Toggle("動画プレイヤーのホームボタンを常に表示", isOn: Binding(
                get: { viewModel.showVideoHomeButtonAlways },
                set: { viewModel.showVideoHomeButtonAlways = $0 }
            ))

            Toggle("動画プレイヤーの共有ボタンを表示", isOn: Binding(
                get: { viewModel.showVideoShareButton },
                set: { viewModel.showVideoShareButton = $0 }
            ))

            Toggle("動画プレイヤーの AirPlay ボタンを表示", isOn: Binding(
                get: { viewModel.showVideoAirPlayButton },
                set: { viewModel.showVideoAirPlayButton = $0 }
            ))

            Toggle("動画プレイヤーに現在時刻を表示", isOn: Binding(
                get: { viewModel.showVideoClock },
                set: { viewModel.showVideoClock = $0 }
            ))

            Picker("画面の向き", selection: Binding(
                get: { viewModel.orientationMode },
                set: { viewModel.orientationMode = $0 }
            )) {
                ForEach(OrientationMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }

    // MARK: - データセクション

    @ViewBuilder
    private func dataSection(viewModel: SettingsViewModel) -> some View {
        Section("データ") {
            Picker("視聴履歴の上限件数", selection: Binding(
                get: { viewModel.watchHistoryLimit },
                set: { viewModel.watchHistoryLimit = $0 }
            )) {
                ForEach(SettingsViewModel.watchHistoryLimitOptions, id: \.self) { count in
                    Text("\(count)件").tag(count)
                }
            }

            Button(role: .destructive) {
                showDeleteHistoryAlert = true
            } label: {
                Label("視聴履歴をすべて削除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func backupSection(viewModel: SettingsViewModel) -> some View {
        Section("接続情報・リスト・履歴") {
            if !viewModel.backupDirectoryPath.isEmpty {
                LabeledContent("保存先") {
                    Text(viewModel.backupDirectoryPath)
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastAutoBackupDescription = viewModel.lastAutoBackupDescription {
                LabeledContent("自動保存") {
                    Text(lastAutoBackupDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("対象")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("接続情報、認証情報、ローカルフォルダ、リスト、リスト内ファイル、視聴履歴")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await viewModel.exportBackup() }
            } label: {
                Label("接続情報・リスト・履歴を書き出す", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.isExportingBackup || viewModel.isRestoringBackup)

            Button {
                Task { await exportBackupToExternalLocation(viewModel: viewModel) }
            } label: {
                Label("保存先を選んで書き出す", systemImage: "externaldrive.badge.plus")
            }
            .disabled(viewModel.isExportingBackup || viewModel.isRestoringBackup)

            Button(role: .destructive) {
                showRestoreLatestBackupAlert = true
            } label: {
                Label("最新バックアップから復元", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isExportingBackup || viewModel.isRestoringBackup)

            Button {
                showRestoreBackupFileImporter = true
            } label: {
                Label("書き出しファイルを選んで復元", systemImage: "doc.badge.arrow.up")
            }
            .disabled(viewModel.isExportingBackup || viewModel.isRestoringBackup)

            if let backupStatusMessage = viewModel.backupStatusMessage {
                Text(backupStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastExportURL = viewModel.lastExportURL {
                ShareLink(item: lastExportURL) {
                    Label("直近の書き出しファイルを共有", systemImage: "square.and.arrow.up.on.square")
                }
            }

            if let lastRestoreSnapshotURL = viewModel.lastRestoreSnapshotURL {
                ShareLink(item: lastRestoreSnapshotURL) {
                    Label("復元前データを共有", systemImage: "archivebox")
                }
            }
        }
    }

    // MARK: - 情報セクション

    @ViewBuilder
    private func infoSection(viewModel: SettingsViewModel) -> some View {
        Section("情報") {
            HStack {
                Text("バージョン")
                Spacer()
                Text(viewModel.appVersion)
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                OSSLicensesView()
            } label: {
                Text("OSSライセンス")
            }
        }
    }

    // MARK: - Helpers

    private func cacheLimitLabel(mb: Int) -> String {
        mb >= 1024 ? "\(mb / 1024)GB" : "\(mb)MB"
    }

    @MainActor
    private func exportBackupToExternalLocation(viewModel: SettingsViewModel) async {
        await viewModel.exportBackup()

        guard let exportURL = viewModel.lastExportURL else { return }

        do {
            let data = try Data(contentsOf: exportURL)
            pendingExportBackupDocument = BackupJSONDocument(data: data)
            pendingExportBackupFilename = exportURL.lastPathComponent
            showBackupFileExporter = true
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private struct BackupJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
