import Foundation

@Observable
final class TabOrderViewModel {

    var tabs: [AppTab]

    init() {
        self.tabs = TabOrderService.shared.tabs
    }

    func move(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
        TabOrderService.shared.tabs = tabs
    }
}
