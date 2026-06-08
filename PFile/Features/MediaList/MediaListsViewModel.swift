import Foundation

extension Notification.Name {
    static let mediaListsDidChange = Notification.Name("mediaListsDidChange")
}

@Observable
@MainActor
final class MediaListsViewModel {

    var lists: [MediaList] = []
    var isLoading = false
    var errorMessage: String?

    private let repository: any MediaListRepository
    private var scopeID: String?
    private let showsAllWhenScopeMissing: Bool

    init(
        repository: any MediaListRepository,
        scopeID: String? = nil,
        showsAllWhenScopeMissing: Bool = true
    ) {
        self.repository = repository
        self.scopeID = scopeID
        self.showsAllWhenScopeMissing = showsAllWhenScopeMissing
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            lists = try await fetchListsForCurrentScope()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateScope(_ scopeID: String?) async {
        self.scopeID = scopeID
        await load()
    }

    func createList(name: String) async {
        do {
            guard let scopeID else {
                errorMessage = "ソースを選択してください"
                return
            }
            let list = try await repository.createList(name: name, scopeID: scopeID)
            lists.append(list)
            errorMessage = nil
            NotificationCenter.default.post(name: .mediaListsDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteList(_ list: MediaList) async {
        do {
            try await repository.deleteList(list)
            lists.removeAll { $0.id == list.id }
            errorMessage = nil
            NotificationCenter.default.post(name: .mediaListsDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameList(_ list: MediaList, to name: String) async {
        do {
            try await repository.renameList(list, to: name)
            errorMessage = nil
            NotificationCenter.default.post(name: .mediaListsDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveLists(from source: IndexSet, to destination: Int) async {
        lists.move(fromOffsets: source, toOffset: destination)
        for (index, list) in lists.enumerated() {
            list.sortOrder = index
        }
        do {
            for list in lists {
                try await repository.renameList(list, to: list.name)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchListsForCurrentScope() async throws -> [MediaList] {
        if let scopeID {
            return try await repository.fetchLists(in: scopeID)
        }
        if showsAllWhenScopeMissing {
            return try await repository.fetchAllLists()
        }
        return []
    }
}
