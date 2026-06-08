import SwiftUI

struct BreadcrumbView: View {

    let connectionName: String
    let currentIndex: Int
    let segments: [String]
    /// nil の場合はタップ不可（表示のみ）
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    rootLabel

                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))

                        if let onTap {
                            Button {
                                onTap(index)
                            } label: {
                                Text(segment)
                                    .font(index == currentIndex ? .caption.weight(.semibold) : .caption)
                                    .foregroundStyle(segmentColor(for: index))
                            }
                            .id(index)
                        } else {
                            Text(segment)
                                .font(index == currentIndex ? .caption.weight(.semibold) : .caption)
                                .foregroundStyle(segmentColor(for: index))
                                .id(index)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Constants.Theme.tabCyan)
            .onChange(of: segments) { _, _ in
                if let last = segments.indices.last {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rootLabel: some View {
        if let onTap {
            Button {
                onTap(-1)
            } label: {
                Text(connectionName)
                    .font(currentIndex < 0 ? .caption.weight(.semibold) : .caption)
                    .foregroundStyle(currentIndex < 0 ? .white : .white.opacity(0.75))
            }
        } else {
            Text(connectionName)
                .font(currentIndex < 0 ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(currentIndex < 0 ? .white : .white.opacity(0.75))
        }
    }

    private func segmentColor(for index: Int) -> Color {
        if index == currentIndex {
            return .white
        }
        if index > currentIndex {
            return .white.opacity(0.6)
        }
        return .white.opacity(0.75)
    }
}
