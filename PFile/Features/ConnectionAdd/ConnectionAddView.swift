import SwiftUI

struct ConnectionAddView: View {

    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ConnectionAddViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    form(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("接続先を追加")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            viewModel = ConnectionAddViewModel(
                remoteConnectionRepository: appEnvironment.remoteConnectionRepository
            )
        }
    }

    @ViewBuilder
    private func form(viewModel: ConnectionAddViewModel) -> some View {
        @Bindable var vm = viewModel
        Form {
            Section("基本情報") {
                TextField("表示名（例: サンプルNAS）", text: $vm.displayName)
                    .autocorrectionDisabled()
            }

            Section("SMB接続") {
                TextField("ホスト / IPアドレス", text: $vm.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("ポート（省略時: 445）", text: $vm.port)
                    .keyboardType(.numberPad)

                HStack {
                    if viewModel.availableShares.isEmpty {
                        TextField("共有フォルダ（例: videos/movies）", text: $vm.shareName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Picker("共有フォルダ", selection: $vm.shareName) {
                            Text("/ （ルート）").tag("/")
                            ForEach(viewModel.availableShares, id: \.self) { share in
                                Text(share).tag(share)
                            }
                        }
                    }

                    Button {
                        Task { await viewModel.fetchShares() }
                    } label: {
                        if viewModel.isFetchingShares {
                            ProgressView().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.tint)
                        }
                    }
                    .disabled(viewModel.host.isEmpty || viewModel.isFetchingShares)
                }

            }

            Section("認証") {
                TextField("ユーザー名", text: $vm.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("パスワード", text: $vm.password)
                    .textContentType(.password)
            }

            Section {
                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    HStack {
                        if viewModel.isTesting {
                            ProgressView().frame(width: 20, height: 20)
                            Text("接続テスト中...")
                        } else if viewModel.connectionTested {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("接続成功")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "network")
                            Text("接続テスト")
                        }
                        Spacer()
                    }
                }
                .disabled(viewModel.host.isEmpty || viewModel.isTesting || viewModel.isLoading)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        do {
                            try await viewModel.save()
                            dismiss()
                        } catch {
                            // errorMessage は save() 内でセット済み
                        }
                    }
                } label: {
                    if viewModel.isLoading {
                        ProgressView().frame(width: 20, height: 20)
                    } else {
                        Text("保存")
                    }
                }
                .disabled(!viewModel.canSave || viewModel.isLoading)
            }
        }
    }
}
