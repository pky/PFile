import SwiftUI

struct OSSLicensesView: View {

    private let licenses: [License] = [
        License(
            name: "VLCKit",
            spdx: "LGPLv2.1",
            url: "https://code.videolan.org/videolan/VLCKit"
        ),
        License(
            name: "AMSMB2",
            spdx: "MIT",
            url: "https://github.com/amosavian/AMSMB2"
        ),
        License(
            name: "Google Mobile Ads SDK",
            spdx: "独自ライセンス",
            url: "https://developers.google.com/admob/ios/download"
        ),
    ]

    var body: some View {
        List(licenses) { license in
            VStack(alignment: .leading, spacing: 4) {
                Text(license.name)
                    .font(.body)
                Text(license.spdx)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("OSSライセンス")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - License

private struct License: Identifiable {
    let id = UUID()
    let name: String
    let spdx: String
    let url: String
}
