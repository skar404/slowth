import StoreKit

// Pure "tip the developer" donations — consumable, no effect on app functionality.
// Product IDs must match products created in App Store Connect (one app record
// covers both platforms, see CLAUDE.md's note on shared bundle IDs) and the
// Configs/Slowth.storekit file used for local Simulator/dev testing.
@MainActor
final class TipStore: ObservableObject {
    enum TipProductID: String, CaseIterable {
        case coffee = "tip.coffee"
        case beans = "tip.beans"
        case climbingPass = "tip.climbingpass"
    }

    enum StoreError: Error {
        case failedVerification
    }

    struct TipHistoryEntry: Identifiable, Equatable {
        let id: UInt64
        let productID: String
        let date: Date
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var purchasingProductID: String?
    @Published var lastPurchasedProductID: String?
    @Published var lastError: String?
    @Published private(set) var history: [TipHistoryEntry] = []
    @Published private(set) var isLoadingHistory = false

    private var updatesTask: Task<Void, Never>?

    init() {
        ensureTransactionListener()
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        guard FeatureFlags.tipsEnabled else { return }
        ensureTransactionListener()
        guard products.isEmpty else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(for: TipProductID.allCases.map(\.rawValue))
            products = TipProductID.allCases.compactMap { id in fetched.first { $0.id == id.rawValue } }
        } catch {
            lastError = "Could not load support options. Check your connection and try again."
        }
    }

    func purchase(_ product: Product) async {
        guard FeatureFlags.tipsEnabled else { return }
        ensureTransactionListener()
        guard purchasingProductID == nil else { return }
        purchasingProductID = product.id
        defer { purchasingProductID = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                lastPurchasedProductID = product.id
                await loadHistory()
            case .userCancelled:
                break
            case .pending:
                lastError = "Purchase is pending approval (e.g. Ask to Buy)."
            @unknown default:
                break
            }
        } catch {
            lastError = "Purchase failed. Please try again."
        }
    }

    func loadHistory() async {
        guard FeatureFlags.tipsEnabled else { return }
        ensureTransactionListener()
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let ourProductIDs = Set(TipProductID.allCases.map(\.rawValue))
        var entries: [TipHistoryEntry] = []
        for await result in Transaction.all {
            guard let transaction = try? checkVerified(result) else { continue }
            guard ourProductIDs.contains(transaction.productID) else { continue }
            guard transaction.revocationDate == nil else { continue }
            entries.append(TipHistoryEntry(id: transaction.id, productID: transaction.productID, date: transaction.purchaseDate))
        }
        history = entries.sorted { $0.date > $1.date }
    }

    func displayName(for productID: String) -> String {
        products.first { $0.id == productID }?.displayName ?? productID
    }

    private func ensureTransactionListener() {
        guard FeatureFlags.tipsEnabled, updatesTask == nil else { return }
        updatesTask = listenForTransactionUpdates()
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self, let transaction = try? await self.checkVerified(update) else { continue }
                await transaction.finish()
                await self.loadHistory()
                await MainActor.run { self.lastPurchasedProductID = transaction.productID }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified: throw StoreError.failedVerification
        case .verified(let safe): return safe
        }
    }
}
