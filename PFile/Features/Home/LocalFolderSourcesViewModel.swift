import Foundation

@Observable
final class LocalFolderSourcesViewModel {

    var sources: [LocalFolderSource] = []
    var isLoading = false
    var errorMessage: String?

    private let repository: any LocalFolderSourceRepository

    init(repository: any LocalFolderSourceRepository) {
        self.repository = repository
    }

    func loadSources() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sources = try await repository.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addFolder(from url: URL) async -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmarkData = try LocalFolderBookmarkService.makeBookmark(for: url)
            let source = LocalFolderSource(
                displayName: url.lastPathComponent,
                bookmarkData: bookmarkData
            )
            try await repository.save(source)
            errorMessage = nil
            await loadSources()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ source: LocalFolderSource) async {
        do {
            try await repository.delete(source)
            await loadSources()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
