import SwiftUI

struct AddToListSheet: View {

    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let items: [DirectoryItem]
    let source: ContentSource
    let connection: RemoteConnection?
    let fileRepository: (any FileRepository)?
    let suppressSuccessAlert: Bool

    @State private var viewModel: AddToListViewModel?
    @State private var newListName = ""
    @State private var showSaveResultAlert = false
    @FocusState private var isNewListFieldFocused: Bool

    init(
        items: [DirectoryItem],
        source: ContentSource,
        connection: RemoteConnection?,
        fileRepository: (any FileRepository)? = nil,
        suppressSuccessAlert: Bool = false
    ) {
        self.items = items
        self.source = source
        self.connection = connection
        self.fileRepository = fileRepository
        self.suppressSuccessAlert = suppressSuccessAlert
    }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("リストを保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let viewModel else { return }
                        Task {
                            await viewModel.save(
                                items: items,
                                sourceID: source.id,
                                connection: connection,
                                fileRepository: fileRepository
                            )
                            if viewModel.errorMessage == nil {
                                if suppressSuccessAlert {
                                    dismiss()
                                } else {
                                    showSaveResultAlert = viewModel.saveResultMessage != nil
                                    if !showSaveResultAlert {
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                    .disabled(!(viewModel?.canSave ?? false))
                }
            }
        }
        .alert("リストを保存", isPresented: $showSaveResultAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text(viewModel?.saveResultMessage ?? "")
        }
        .task {
            let vm = AddToListViewModel(repository: appEnvironment.mediaListRepository)
            viewModel = vm
            await vm.load(
                checkedFor: items,
                scopeID: source.id,
                fileRepository: fileRepository
            )
        }
    }

    @ViewBuilder
    private func content(viewModel: AddToListViewModel) -> some View {
        List {
            if items.contains(where: \.isDirectory) {
                Section {
                    Text("選択したフォルダ配下の動画・画像も追加されます")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    TextField("新しいリスト名", text: $newListName)
                        .focused($isNewListFieldFocused)
                    Button {
                        let name = newListName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        newListName = ""
                        Task { await viewModel.createAndSelect(name: name) }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .disabled(newListName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("リスト") {
                ForEach(viewModel.lists) { list in
                    Button {
                        if viewModel.selectedListIds.contains(list.id) {
                            viewModel.selectedListIds.remove(list.id)
                        } else {
                            viewModel.selectedListIds.insert(list.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: viewModel.selectedListIds.contains(list.id)
                                ? "checkmark.circle.fill"
                                : "circle")
                            .foregroundStyle(viewModel.selectedListIds.contains(list.id)
                                ? Color.accentColor
                                : Color.secondary)
                            Text(list.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(viewModel.listItemCounts[list.id] ?? 0)件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
    }
}
