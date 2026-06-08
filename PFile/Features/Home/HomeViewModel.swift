import Foundation

@Observable
final class HomeViewModel {

    var connections: [RemoteConnection] = []
    var isLoading = false
    var errorMessage: String?

    private let remoteConnectionRepository: any RemoteConnectionRepository

    init(remoteConnectionRepository: any RemoteConnectionRepository) {
        self.remoteConnectionRepository = remoteConnectionRepository
    }

    func loadConnections() async {
        isLoading = true
        defer { isLoading = false }
        do {
            connections = try await remoteConnectionRepository.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ connection: RemoteConnection) async {
        let previousConnections = connections
        do {
            connections.removeAll { $0.id == connection.id }
            try await remoteConnectionRepository.delete(connection)
            await loadConnections()
        } catch {
            connections = previousConnections
            errorMessage = error.localizedDescription
        }
    }
}
