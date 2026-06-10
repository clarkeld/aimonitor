import AIMonitorCore
import Foundation
import SwiftUI

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published var selectedProvider: Provider = .deepseek
    @Published var accounts: [ProviderAccount] = []
    @Published var balances: [Provider: [BalanceSnapshot]] = [:]
    @Published var summaries: [Provider: UsageSummary] = [:]
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var lastImportMessage: String?
    @Published private(set) var apiKeyAvailability: [Provider: Bool] = [:]
    @Published private(set) var deepSeekDashboardTokenAvailable = false
    @Published var refreshIntervalMinutes: Int = 30

    private var store: SQLiteStore?
    private let keychain: SecretStoring
    private let deepSeekClient: DeepSeekClient
    private let deepSeekDashboardClient: DeepSeekDashboardClient
    private let mimoDashboardClient: MiMoDashboardClient
    private var autoRefreshTask: Task<Void, Never>?
    private var apiKeys: [Provider: String] = [:]
    private var deepSeekDashboardToken: String?

    private static let defaultMiMoBalanceURL = "https://platform.xiaomimimo.com/console/balance"
    private static let defaultMiMoUsageURL = "https://platform.xiaomimimo.com/console/usage"
    private static let refreshIntervalUserDefaultsKey = "aiMonitor.refreshIntervalMinutes"

    init(
        keychain: SecretStoring = FileSecretStore(),
        deepSeekClient: DeepSeekClient = DeepSeekClient(),
        deepSeekDashboardClient: DeepSeekDashboardClient = DeepSeekDashboardClient(),
        mimoDashboardClient: MiMoDashboardClient = MiMoDashboardClient()
    ) {
        self.keychain = keychain
        self.deepSeekClient = deepSeekClient
        self.deepSeekDashboardClient = deepSeekDashboardClient
        self.mimoDashboardClient = mimoDashboardClient
    }

    func load() async {
        do {
            if store == nil {
                store = try SQLiteStore(path: SQLiteStore.defaultDatabaseURL())
                try seedAccountsIfNeeded()
                if let store {
                    try store.purgeImportedData()
                }
            }
            let storedInterval = UserDefaults.standard.object(forKey: Self.refreshIntervalUserDefaultsKey) as? Int
            refreshIntervalMinutes = storedInterval ?? 30
            try reloadLocalState()
            refreshAPIKeyAvailability()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startAutoRefresh() async {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let minutes = max(1, self.refreshIntervalMinutes)
                try? await Task.sleep(for: .seconds(Int64(minutes) * 60))
                if Task.isCancelled { return }
                await self.refreshSelectedProvider()
            }
        }
    }

    func restartAutoRefreshIfNeeded(newIntervalMinutes: Int) {
        refreshIntervalMinutes = newIntervalMinutes
        UserDefaults.standard.set(newIntervalMinutes, forKey: Self.refreshIntervalUserDefaultsKey)
        autoRefreshTask?.cancel()
        Task { @MainActor in
            await startAutoRefresh()
        }
    }

    func refreshSelectedProvider() async {
        await refresh(provider: selectedProvider)
    }

    func refresh(provider: Provider) async {
        guard let store else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            switch provider {
            case .deepseek:
                let apiKey = apiKeys[.deepseek]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let dashboardToken = deepSeekDashboardToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard apiKey?.isEmpty == false || dashboardToken?.isEmpty == false else {
                    throw AIMonitorError.missingAPIKey(.deepseek)
                }

                var insertedUsage = 0
                if let dashboardToken, !dashboardToken.isEmpty {
                    let result = try await deepSeekDashboardClient.fetchCurrentMonth(userToken: dashboardToken)
                    try store.deleteUsageRecords(provider: .deepseek)
                    insertedUsage = try store.insertUsageRecords(result.records)
                    try store.upsertBalances(result.balanceSnapshots)
                }

                if let apiKey, !apiKey.isEmpty {
                    let snapshots = try await deepSeekClient.fetchBalances(apiKey: apiKey)
                    try store.upsertBalances(snapshots)
                }

                try touchAccount(provider: .deepseek)
                if dashboardToken?.isEmpty == false {
                    lastImportMessage = "DeepSeek 已刷新，新增 \(insertedUsage) 条用量记录"
                }
            case .mimo:
                let account = account(for: .mimo)
                guard let cookie = apiKeys[.mimo], !cookie.isEmpty else {
                    lastImportMessage = "请在设置里填写 MiMo Dashboard Cookie"
                    break
                }
                let urls = mimoDashboardURLs()
                let configuredURLs = [urls.balanceURL, urls.usageURL].compactMap { value -> URL? in
                    guard let url = URL(string: value), url.scheme?.hasPrefix("http") == true else { return nil }
                    return url
                }
                let fetchURLs = MiMoDashboardClient.dashboardAPIURLs(from: configuredURLs, billingMode: account.billingMode)
                let usesTokenPlanAPI = fetchURLs.contains { $0.path.localizedCaseInsensitiveContains("tokenPlan") }
                guard !fetchURLs.isEmpty else {
                    lastImportMessage = "请在设置里填写 MiMo 余额 URL 或明细 URL"
                    break
                }

                var allRecords: [UsageRecord] = []
                var allSnapshots: [BalanceSnapshot] = []
                var errors: [String] = []
                var ignoredCandidateErrors: [String] = []
                for url in fetchURLs {
                    do {
                        let response = try await mimoDashboardClient.fetchRaw(url: url, cookie: cookie)
                        guard 200..<300 ~= response.statusCode else {
                            let message = "\(url.lastPathComponent): MiMo Dashboard HTTP \(response.statusCode)"
                            if isOptionalMiMoUsageCandidate(url), [400, 404, 405].contains(response.statusCode) {
                                ignoredCandidateErrors.append(message)
                            } else {
                                errors.append(message)
                            }
                            continue
                        }

                        let responseBillingMode: BillingMode = url.path.localizedCaseInsensitiveContains("tokenPlan") ? .tokenPlan : account.billingMode
                        let result = try MiMoDashboardClient.parse(
                            data: response.data,
                            sourceFile: url.host ?? "mimo-dashboard",
                            billingMode: responseBillingMode
                        )
                        allRecords.append(contentsOf: result.records)
                        allSnapshots.append(contentsOf: result.balanceSnapshots)
                    } catch {
                        let message = "\(url.lastPathComponent): \(error.localizedDescription)"
                        if isOptionalMiMoUsageCandidate(url) {
                            ignoredCandidateErrors.append(message)
                        } else {
                            errors.append(message)
                        }
                    }
                }

                if allRecords.isEmpty, allSnapshots.isEmpty, !errors.isEmpty {
                    throw AIMonitorError.importFailed(errors.joined(separator: "；"))
                }
                if allRecords.isEmpty, allSnapshots.isEmpty, errors.isEmpty, !ignoredCandidateErrors.isEmpty {
                    throw AIMonitorError.importFailed(ignoredCandidateErrors.joined(separator: "；"))
                }

                // 先删除所有旧的 MiMo usage records，避免多次刷新导致数值累加翻倍
                try store.deleteUsageRecords(provider: .mimo)
                let inserted = try store.insertUsageRecords(allRecords)
                try store.upsertBalances(allSnapshots)
                if usesTokenPlanAPI {
                    var updatedAccount = account
                    updatedAccount.billingMode = .tokenPlan
                    updatedAccount.lastRefreshAt = Date()
                    try store.saveAccount(updatedAccount)
                } else {
                    try touchAccount(provider: .mimo)
                }
                lastImportMessage = errors.isEmpty ? "MiMo 已刷新，新增 \(inserted) 条用量记录" : "MiMo 部分刷新成功，新增 \(inserted) 条；\(errors.joined(separator: "；"))"
            }
            try reloadLocalState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isOptionalMiMoUsageCandidate(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        guard path.hasPrefix("/api/v1/usage/"), path != "/api/v1/usage/detail" else { return false }
        // /api/v1/usage/detail/list 是消费账单接口（POST），是核心数据源之一，不要被当作 optional
        return !path.hasSuffix("/detail/list")
    }

    @discardableResult
    func saveSettings(
        deepSeekKey: String,
        deepSeekDashboardToken: String,
        mimoCookie: String,
        mimoBalanceURL: String,
        mimoUsageURL: String,
        mimoBillingMode: BillingMode,
        preferredCurrency: String,
        refreshIntervalMinutes: Int
    ) -> Bool {
        guard let store else { return false }
        do {
            errorMessage = nil
            lastImportMessage = nil
            let enteredDeepSeekKey = deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let enteredDashboardToken = deepSeekDashboardToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !enteredDeepSeekKey.isEmpty || !enteredDashboardToken.isEmpty {
                let currentSecrets = deepSeekSecrets()
                let nextSecrets = DeepSeekSecrets(
                    apiKey: enteredDeepSeekKey.isEmpty ? currentSecrets.apiKey : enteredDeepSeekKey,
                    dashboardToken: enteredDashboardToken.isEmpty ? currentSecrets.dashboardToken : enteredDashboardToken
                )
                try keychain.save(encodeDeepSeekSecrets(nextSecrets), provider: .deepseek)
                apiKeys[.deepseek] = nextSecrets.apiKey
                self.deepSeekDashboardToken = nextSecrets.dashboardToken
                apiKeyAvailability[.deepseek] = nextSecrets.apiKey?.isEmpty == false
                deepSeekDashboardTokenAvailable = nextSecrets.dashboardToken?.isEmpty == false
            }
            if !mimoCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let formattedCookie = CookieFormatter.header(from: mimoCookie)
                try keychain.save(formattedCookie, provider: .mimo)
                apiKeys[.mimo] = formattedCookie
                apiKeyAvailability[.mimo] = true
            }
            var dashboardURLs = mimoDashboardURLs()
            let balanceURL = mimoBalanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let usageURL = mimoUsageURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !balanceURL.isEmpty {
                dashboardURLs.balanceURL = balanceURL
            }
            if !usageURL.isEmpty {
                dashboardURLs.usageURL = usageURL
            }
            let normalizedDashboardURLs = normalizeMiMoDashboardURLs(dashboardURLs)
            let effectiveMiMoBillingMode: BillingMode = usesMiMoTokenPlanEndpoint(normalizedDashboardURLs) ? .tokenPlan : mimoBillingMode
            try store.saveAccount(
                ProviderAccount(
                    provider: .mimo,
                    displayName: Provider.mimo.displayName,
                    apiKeyRef: encodeMiMoDashboardURLs(normalizedDashboardURLs),
                    billingMode: effectiveMiMoBillingMode,
                    currency: preferredCurrency
                )
            )
            try store.saveAccount(
                ProviderAccount(
                    provider: .deepseek,
                    displayName: Provider.deepseek.displayName,
                    apiKeyRef: Provider.deepseek.rawValue,
                    billingMode: .payAsYouGo,
                    currency: preferredCurrency
                )
            )
            try reloadLocalState()
            let clamped = max(1, refreshIntervalMinutes)
            UserDefaults.standard.set(clamped, forKey: Self.refreshIntervalUserDefaultsKey)
            self.refreshIntervalMinutes = clamped
            autoRefreshTask?.cancel()
            Task { @MainActor in
                await startAutoRefresh()
            }
            lastImportMessage = "设置已保存"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func apiKeyExists(provider: Provider) -> Bool {
        apiKeyAvailability[provider] ?? false
    }

    func account(for provider: Provider) -> ProviderAccount {
        accounts.first(where: { $0.provider == provider }) ?? ProviderAccount(
            provider: provider,
            displayName: provider.displayName,
            apiKeyRef: provider.rawValue,
            billingMode: provider == .mimo ? .payAsYouGo : .payAsYouGo,
            currency: provider == .mimo ? "CNY" : "CNY"
        )
    }

    func mimoDashboardURLs() -> (balanceURL: String, usageURL: String) {
        decodeMiMoDashboardURLs(account(for: .mimo).apiKeyRef)
    }

    private func seedAccountsIfNeeded() throws {
        guard let store else { return }
        if try store.accounts().isEmpty {
            try store.saveAccount(
                ProviderAccount(
                    provider: .deepseek,
                    displayName: "DeepSeek",
                    apiKeyRef: Provider.deepseek.rawValue,
                    billingMode: .payAsYouGo,
                    currency: "CNY"
                )
            )
            try store.saveAccount(
                ProviderAccount(
                    provider: .mimo,
                    displayName: "MiMo",
                    apiKeyRef: encodeMiMoDashboardURLs(Self.defaultMiMoDashboardURLs),
                    billingMode: .payAsYouGo,
                    currency: "CNY"
                )
            )
        }
    }

    private func touchAccount(provider: Provider) throws {
        guard let store else { return }
        var account = account(for: provider)
        account.lastRefreshAt = Date()
        try store.saveAccount(account)
    }

    private func reloadLocalState() throws {
        guard let store else { return }
        accounts = try store.accounts()
        var nextBalances: [Provider: [BalanceSnapshot]] = [:]
        var nextSummaries: [Provider: UsageSummary] = [:]
        for provider in Provider.allCases {
            nextBalances[provider] = try store.latestBalances(provider: provider)
            nextSummaries[provider] = try store.usageSummary(provider: provider)
        }
        balances = nextBalances
        summaries = nextSummaries
    }

    private func refreshAPIKeyAvailability() {
        let deepSeek = deepSeekSecrets()
        apiKeys[.deepseek] = deepSeek.apiKey
        deepSeekDashboardToken = deepSeek.dashboardToken
        apiKeyAvailability[.deepseek] = deepSeek.apiKey?.isEmpty == false
        deepSeekDashboardTokenAvailable = deepSeek.dashboardToken?.isEmpty == false

        for provider in Provider.allCases where provider != .deepseek {
            if apiKeyAvailability[provider] == true { continue }
            let key = try? keychain.read(provider: provider)
            apiKeys[provider] = key
            apiKeyAvailability[provider] = key?.isEmpty == false
        }
    }

    private func deepSeekSecrets() -> DeepSeekSecrets {
        decodeDeepSeekSecrets((try? keychain.read(provider: .deepseek)) ?? nil)
    }

    private func decodeDeepSeekSecrets(_ value: String?) -> DeepSeekSecrets {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return DeepSeekSecrets()
        }
        if let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(DeepSeekSecrets.self, from: data) {
            return decoded
        }
        return DeepSeekSecrets(apiKey: value, dashboardToken: nil)
    }

    private func encodeDeepSeekSecrets(_ secrets: DeepSeekSecrets) -> String {
        guard let data = try? JSONEncoder().encode(secrets),
              let value = String(data: data, encoding: .utf8) else {
            return secrets.apiKey ?? ""
        }
        return value
    }

    private func decodeMiMoDashboardURLs(_ value: String) -> (balanceURL: String, usageURL: String) {
        guard !value.isEmpty, value != Provider.mimo.rawValue else {
            return Self.defaultMiMoDashboardURLs
        }
        if let data = value.data(using: .utf8),
           let config = try? JSONDecoder().decode(MiMoDashboardURLConfig.self, from: data) {
            return normalizeMiMoDashboardURLs((config.balanceURL, config.usageURL))
        }
        if value.localizedCaseInsensitiveContains("/usage") {
            return normalizeMiMoDashboardURLs(("", value))
        }
        return normalizeMiMoDashboardURLs((value, ""))
    }

    private func encodeMiMoDashboardURLs(_ urls: (balanceURL: String, usageURL: String)) -> String {
        let normalizedURLs = normalizeMiMoDashboardURLs(urls)
        let config = MiMoDashboardURLConfig(balanceURL: normalizedURLs.balanceURL, usageURL: normalizedURLs.usageURL)
        guard let data = try? JSONEncoder().encode(config),
              let value = String(data: data, encoding: .utf8) else {
            return Provider.mimo.rawValue
        }
        return value
    }

    private static var defaultMiMoDashboardURLs: (balanceURL: String, usageURL: String) {
        (defaultMiMoBalanceURL, defaultMiMoUsageURL)
    }

    private func normalizeMiMoDashboardURLs(_ urls: (balanceURL: String, usageURL: String)) -> (balanceURL: String, usageURL: String) {
        let balanceURL = normalizedMiMoBalanceURL(urls.balanceURL)
        let usageURL = urls.usageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            balanceURL.isEmpty ? Self.defaultMiMoBalanceURL : balanceURL,
            usageURL.isEmpty ? Self.defaultMiMoUsageURL : usageURL
        )
    }

    private func normalizedMiMoBalanceURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let url = URL(string: trimmed),
           url.host?.localizedCaseInsensitiveContains("xiaomimimo.com") == true,
           url.path == "/console/balance" {
            return Self.defaultMiMoBalanceURL
        }
        return trimmed
    }

    private func usesMiMoTokenPlanEndpoint(_ urls: (balanceURL: String, usageURL: String)) -> Bool {
        [urls.balanceURL, urls.usageURL].contains { value in
            guard let url = URL(string: value) else { return false }
            return url.host?.localizedCaseInsensitiveContains("xiaomimimo.com") == true &&
                (url.path.localizedCaseInsensitiveContains("tokenPlan") ||
                 url.path.localizedCaseInsensitiveContains("plan-manage"))
        }
    }

}

private struct MiMoDashboardURLConfig: Codable {
    var balanceURL: String
    var usageURL: String
}

private struct DeepSeekSecrets: Codable {
    var apiKey: String?
    var dashboardToken: String?
}
