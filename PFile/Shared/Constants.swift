import SwiftUI

enum Constants {

    enum Theme {
        static let panelBackground = Color("PanelBackground")
        static let tabCyan = Color(red: 101/255, green: 147/255, blue: 218/255)
        static let folderBlue = tabCyan
    }
    enum App {
        static let bundleId = "jp.pky.pfile"
        static let displayName = "PFile"
    }

    enum SMB {
        static let defaultPort = 445
        static let timeout: TimeInterval = 30
    }

    enum Thumbnail {
        static let size = CGSize(width: 200, height: 200)
    }

    enum Layout {
        // BreadcrumbView の高さ（caption テキスト + vertical padding 8pt×2 ≈ 28pt）
        // ブラウズタブ以外のコンテンツ上端をブラウズタブと揃えるために使用
        static let breadcrumbBarHeight: CGFloat = 28
        // HomeView のメインタブバー高さ。配下階層でも同じヘッダー位置を維持するために使用
        static let mainTabBarHeight: CGFloat = 88
    }

    enum Grid {
        // gridTitled: caption 2行分の固定高さ（~17pt/行）
        static let cellTitleHeight: CGFloat = 36
        // gridDetail: caption 2行 + caption2 最大2行分の固定高さ
        static let cellDetailInfoHeight: CGFloat = 64
    }

    enum AdMob {
        // Google公式のバナー広告テストID
        static let bannerAdUnitId = "ca-app-pub-3940256099942544/2934735716"
    }

    enum Purchase {
        static let removeAdsProductId = "jp.pky.pfile.remove_ads.lifetime"
    }
}
