import SwiftUI

// MARK: - NewConnectionType

enum NewConnectionType {
    case localFolder
    case remote(ServiceType)
}

// MARK: - ConnectionTypePickerSheet

struct ConnectionTypePickerSheet: View {

    let onSelect: (NewConnectionType) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    typeCell(
                        title: "ローカルフォルダ",
                        systemImage: "folder",
                        color: .yellow,
                        available: true
                    ) {
                        onSelect(.localFolder)
                        dismiss()
                    }

                    ForEach(ServiceType.allCases, id: \.self) { type in
                        let available = type.isAvailable
                        typeCell(
                            title: type.displayName,
                            systemImage: type.iconName,
                            color: type.iconColor,
                            available: available
                        ) {
                            onSelect(.remote(type))
                            dismiss()
                        }
                        .disabled(!available)
                    }
                }
                .padding()
            }
            .navigationTitle("何に接続しますか？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func typeCell(
        title: String,
        systemImage: String,
        color: Color,
        available: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(available ? color : .secondary)
                    .frame(width: 60, height: 60)

                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(available ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ServiceType extensions

private extension ServiceType {
    var iconName: String {
        switch self {
        case .smb:         return "externaldrive.connected.to.line.below"
        case .ftp, .ftps:  return "server.rack"
        case .sftp:        return "lock.shield"
        case .webdav:      return "globe"
        case .dropbox:     return "arrow.down.circle"
        case .googleDrive: return "cloud"
        case .oneDrive:    return "cloud"
        }
    }

    var iconColor: Color {
        switch self {
        case .smb:         return .blue
        case .ftp, .ftps:  return .orange
        case .sftp:        return .green
        case .webdav:      return .purple
        case .dropbox:     return .blue
        case .googleDrive: return .red
        case .oneDrive:    return .blue
        }
    }
}
