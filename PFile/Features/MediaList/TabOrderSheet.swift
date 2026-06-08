import SwiftUI

struct TabOrderSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = TabOrderViewModel()

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.tabs, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .onMove { source, dest in
                    viewModel.move(from: source, to: dest)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("タブの順序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
