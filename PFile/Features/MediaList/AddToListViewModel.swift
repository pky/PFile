import Foundation

@Observable
@MainActor
final class AddToListViewModel {

    var lists: [MediaList] = []
    var selectedListIds: Set<UUID> = []
    var initialSelectedListIds: Set<UUID> = []
    var isLoading = false
    var listItemCounts: [UUID: Int] = [:]
    var addableItemCounts: [UUID: Int] = [:]
    var newListName = ""
    var errorMessage: String?
    var saveResultMessage: String?

    private let repository: any MediaListRepository
    private var targetItems: [DirectoryItem] = []
    private var resolvedTargetItems: [DirectoryItem] = []
    private var targetScopeID: String?

    var hasChanges: Bool {
        selectedListIds != initialSelectedListIds
    }

    var hasAddableSelections: Bool {
        selectedListIds.contains { (addableItemCounts[$0] ?? 0) > 0 }
    }

    var canSave: Bool {
        hasChanges || hasAddableSelections
    }

    init(repository: any MediaListRepository) {
        self.repository = repository
    }

    func load(
        checkedFor items: [DirectoryItem],
        scopeID: String,
        fileRepository: (any FileRepository)? = nil
    ) async {
        targetItems = items
        targetScopeID = scopeID
        isLoading = true
        defer { isLoading = false }
        do {
            if let fileRepository {
                resolvedTargetItems = try await fileRepository.collectMediaItemsRecursively(from: items)
            } else {
                resolvedTargetItems = items.filter(\.isMedia)
            }
            lists = try await repository.fetchLists(in: scopeID)
            var counts: [UUID: Int] = [:]
            var addableCounts: [UUID: Int] = [:]
            for list in lists {
                counts[list.id] = list.items.count
                addableCounts[list.id] = resolvedTargetItems.filter { item in
                    !contains(item, in: list, sourceID: scopeID)
                }.count
            }
            listItemCounts = counts
            addableItemCounts = addableCounts
            // 対象ファイルが1件でも登録されているリストをチェック済みにする
            var checkedIds = Set<UUID>()
            for list in lists {
                if resolvedTargetItems.contains(where: { contains($0, in: list, sourceID: scopeID) }) {
                    checkedIds.insert(list.id)
                }
            }
            selectedListIds = checkedIds
            initialSelectedListIds = checkedIds
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAndSelect(name: String) async {
        do {
            guard let targetScopeID else {
                errorMessage = "ソースを選択してください"
                return
            }
            let list = try await repository.createList(name: name, scopeID: targetScopeID)
            lists.append(list)
            listItemCounts[list.id] = 0
            addableItemCounts[list.id] = resolvedTargetItems.count
            selectedListIds.insert(list.id)
            newListName = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(
        items: [DirectoryItem],
        sourceID: String,
        connection: RemoteConnection?,
        fileRepository: (any FileRepository)? = nil
    ) async {
        isLoading = true
        defer { isLoading = false }

        do {
            saveResultMessage = nil
            let resolvedItems: [DirectoryItem]
            if !resolvedTargetItems.isEmpty {
                resolvedItems = resolvedTargetItems
            } else if let fileRepository {
                resolvedItems = try await fileRepository.collectMediaItemsRecursively(from: items)
            } else {
                resolvedItems = items.filter(\.isMedia)
            }

            guard !resolvedItems.isEmpty else {
                errorMessage = "追加できる動画または画像がありません"
                return
            }

            let listsToAdd = lists.filter { selectedListIds.contains($0.id) }
            let listsToRemove = lists.filter { initialSelectedListIds.contains($0.id) && !selectedListIds.contains($0.id) }
            var addedCount = 0
            var skippedCount = 0
            var removedCount = 0

            for list in listsToAdd {
                let addableItems = resolvedItems.filter { item in
                    !contains(item, in: list, sourceID: sourceID)
                }
                skippedCount += resolvedItems.count - addableItems.count
                guard !addableItems.isEmpty else { continue }
                addedCount += addableItems.count
                if let connection {
                    try await repository.addItems(addableItems, connection: connection, to: list)
                } else {
                    try await repository.addItems(addableItems, sourceID: sourceID, to: list)
                }
            }

            for list in listsToRemove {
                let removableItems = resolvedItems.filter { contains($0, in: list, sourceID: sourceID) }
                removedCount += removableItems.count
                try await repository.removeItems(resolvedItems, sourceID: sourceID, from: list)
            }

            initialSelectedListIds = selectedListIds
            await load(checkedFor: targetItems, scopeID: sourceID, fileRepository: fileRepository)
            errorMessage = nil
            saveResultMessage = buildSaveResultMessage(
                addedCount: addedCount,
                removedCount: removedCount,
                skippedCount: skippedCount
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func contains(_ item: DirectoryItem, in list: MediaList, sourceID: String) -> Bool {
        list.items.contains { file in
            guard file.sourceID == sourceID else { return false }
            if let itemFileId = item.fileId, itemFileId > 0 {
                return file.fileId == itemFileId
            }
            return file.path == item.path
        }
    }

    private func buildSaveResultMessage(
        addedCount: Int,
        removedCount: Int,
        skippedCount: Int
    ) -> String? {
        var lines: [String] = []

        if addedCount > 0, removedCount > 0 {
            lines.append("\(addedCount)件追加し、\(removedCount)件削除しました")
        } else if addedCount > 0 {
            lines.append("\(addedCount)件追加しました")
        } else if removedCount > 0 {
            lines.append("\(removedCount)件削除しました")
        }

        if skippedCount > 0 {
            lines.append("\(skippedCount)件は既に登録済みでした")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
