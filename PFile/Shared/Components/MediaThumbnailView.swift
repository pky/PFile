import SwiftUI

struct MediaThumbnailView: View {
    let thumbnail: UIImage?
    var placeholderSystemImage: String = "play.rectangle.fill"
    var placeholderColor: Color = .secondary
    var placeholderFontSize: CGFloat = 24
    var width: CGFloat? = nil
    var height: CGFloat? = nil

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: placeholderSystemImage)
                        .font(.system(size: placeholderFontSize))
                        .foregroundStyle(placeholderColor)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}
