import StoreKit
import Foundation

/// StoreKit2 を使った Pro 購入管理シングルトン。
/// @Observable により購入状態が変化すると自動的に UI が再描画される。
@Observable
final class TaxSuiteStore {
    static let shared = TaxSuiteStore()

    // App Store Connect で設定するプロダクト ID
    static let proProductID = "com.fumiakiMogi777.TaxSuite.pro"

    private(set) var proProduct: Product?
    private(set) var isPurchased = false
    private(set) var isLoading = false
    private(set) var purchaseError: String?

    private var updateListenerTask: Task<Void, Error>?

    private init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await refreshPurchaseStatus()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Public API

    func purchase() async {
        guard let product = proProduct, !isPurchased else { return }
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await refreshPurchaseStatus()
                await transaction.finish()
            case .userCancelled:
                break
            case .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restore() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshPurchaseStatus()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func loadProducts() async {
        do {
            let products = try await Product.products(for: [TaxSuiteStore.proProductID])
            await MainActor.run { proProduct = products.first }
        } catch {
            // Simulator では StoreKit Configuration ファイルがないと失敗するが無視してよい
        }
    }

    func refreshPurchaseStatus() async {
        var purchased = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               tx.productID == TaxSuiteStore.proProductID,
               tx.revocationDate == nil {
                purchased = true
                break
            }
        }
        await MainActor.run {
            isPurchased = purchased
            // 既存の @AppStorage("isTaxSuiteProEnabled") 参照と同期
            UserDefaults.standard.set(purchased, forKey: "isTaxSuiteProEnabled")
        }
    }

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await self.refreshPurchaseStatus()
                    await transaction.finish()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
}
