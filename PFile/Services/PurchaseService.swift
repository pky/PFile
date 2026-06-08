import Foundation
import StoreKit

@MainActor
protocol PurchaseServiceProtocol: AnyObject {
    var isAdsRemoved: Bool { get }
    var shouldShowAds: Bool { get }
    var removeAdsDisplayPrice: String? { get }
    var statusMessage: String? { get }
    var isLoading: Bool { get }

#if DEBUG
    var debugShowsAds: Bool { get set }
#endif

    func configure() async
    func purchaseRemoveAds() async
    func restorePurchases() async
}

@Observable
@MainActor
final class PurchaseService: PurchaseServiceProtocol {

    private enum Keys {
        static let adsRemoved = "Purchase.adsRemoved"
#if DEBUG
        static let debugShowsAds = "Purchase.debugShowsAds"
#endif
    }

    private enum PurchaseError: Error {
        case failedVerification
    }

    var isAdsRemoved: Bool = UserDefaults.standard.bool(forKey: Keys.adsRemoved) {
        didSet { UserDefaults.standard.set(isAdsRemoved, forKey: Keys.adsRemoved) }
    }

    var shouldShowAds: Bool {
#if DEBUG
        debugShowsAds && !isAdsRemoved
#else
        !isAdsRemoved
#endif
    }

#if DEBUG
    var debugShowsAds: Bool = UserDefaults.standard.object(forKey: Keys.debugShowsAds) as? Bool ?? true {
        didSet { UserDefaults.standard.set(debugShowsAds, forKey: Keys.debugShowsAds) }
    }
#endif

    var removeAdsDisplayPrice: String?
    var statusMessage: String?
    var isLoading = false

    private var removeAdsProduct: Product?
    nonisolated(unsafe) private var transactionUpdatesTask: Task<Void, Never>?

    init() {
        transactionUpdatesTask = Task { await listenForTransactionUpdates() }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func configure() async {
        await loadProducts()
        await refreshEntitlements()
    }

    func purchaseRemoveAds() async {
        if removeAdsProduct == nil {
            await loadProducts()
        }

        guard let product = removeAdsProduct else {
            statusMessage = "商品情報を取得できませんでした"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verificationResult):
                let transaction = try checkVerified(verificationResult)
                await refreshEntitlements()
                await transaction.finish()
                statusMessage = isAdsRemoved ? "広告削除を有効にしました" : "購入状態を確認できませんでした"
            case .pending:
                statusMessage = "購入は承認待ちです"
            case .userCancelled:
                statusMessage = nil
            @unknown default:
                statusMessage = "購入状態を確認できませんでした"
            }
        } catch PurchaseError.failedVerification {
            statusMessage = "購入の検証に失敗しました"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            statusMessage = isAdsRemoved ? "購入を復元しました" : "復元できる購入がありません"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadProducts() async {
        do {
            let products = try await Product.products(for: [Constants.Purchase.removeAdsProductId])
            removeAdsProduct = products.first { $0.id == Constants.Purchase.removeAdsProductId }
            removeAdsDisplayPrice = removeAdsProduct?.displayPrice
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func refreshEntitlements() async {
        var hasRemoveAds = false

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == Constants.Purchase.removeAdsProductId {
                hasRemoveAds = true
            }
        }

        isAdsRemoved = hasRemoveAds
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == Constants.Purchase.removeAdsProductId {
                await refreshEntitlements()
            }
            await transaction.finish()
        }
    }

    private nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw PurchaseError.failedVerification
        }
    }
}
