import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepseek
    case mimo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .mimo: "MiMo"
        }
    }
}

public enum BillingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case payAsYouGo
    case tokenPlan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .payAsYouGo: "按量付费"
        case .tokenPlan: "Token Plan"
        }
    }
}

public enum DataSource: String, Codable, Sendable {
    case api
}

public struct UsageFetchResult: Sendable {
    public var records: [UsageRecord]
    public var balanceSnapshots: [BalanceSnapshot]

    public init(records: [UsageRecord], balanceSnapshots: [BalanceSnapshot] = []) {
        self.records = records
        self.balanceSnapshots = balanceSnapshots
    }
}

public struct ProviderAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: Provider { provider }
    public var provider: Provider
    public var displayName: String
    public var apiKeyRef: String
    public var billingMode: BillingMode
    public var currency: String
    public var lastRefreshAt: Date?

    public init(
        provider: Provider,
        displayName: String,
        apiKeyRef: String,
        billingMode: BillingMode,
        currency: String,
        lastRefreshAt: Date? = nil
    ) {
        self.provider = provider
        self.displayName = displayName
        self.apiKeyRef = apiKeyRef
        self.billingMode = billingMode
        self.currency = currency
        self.lastRefreshAt = lastRefreshAt
    }
}

public struct BalanceSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: Provider
    public var currency: String
    public var totalBalance: Double?
    public var grantedBalance: Double?
    public var toppedUpBalance: Double?
    public var creditTotal: Double?
    public var creditUsed: Double?
    public var creditRemaining: Double?
    public var monthlyCost: Double?
    public var isAvailable: Bool
    public var source: DataSource
    public var capturedAt: Date

    public init(
        id: String = UUID().uuidString,
        provider: Provider,
        currency: String,
        totalBalance: Double? = nil,
        grantedBalance: Double? = nil,
        toppedUpBalance: Double? = nil,
        creditTotal: Double? = nil,
        creditUsed: Double? = nil,
        creditRemaining: Double? = nil,
        monthlyCost: Double? = nil,
        isAvailable: Bool = true,
        source: DataSource,
        capturedAt: Date = Date()
    ) {
        // 用 provider+currency 作为唯一 id，确保 INSERT OR REPLACE 能正确替换同货币的余额，
        // 避免 dashboard 和 api 两个来源的余额并存导致显示错误
        self.id = "\(provider.rawValue)-\(currency.uppercased())"
        self.provider = provider
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.creditTotal = creditTotal
        self.creditUsed = creditUsed
        self.creditRemaining = creditRemaining
        self.monthlyCost = monthlyCost
        self.isAvailable = isAvailable
        self.source = source
        self.capturedAt = capturedAt
    }
}

public struct UsageRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: Provider
    public var model: String
    public var date: Date
    public var promptTokens: Int64
    public var completionTokens: Int64
    public var cacheHitTokens: Int64
    public var totalTokens: Int64
    public var cost: Double
    public var currency: String
    public var sourceFile: String
    public var rowHash: String

    public init(
        id: String = UUID().uuidString,
        provider: Provider,
        model: String,
        date: Date,
        promptTokens: Int64,
        completionTokens: Int64,
        cacheHitTokens: Int64 = 0,
        totalTokens: Int64,
        cost: Double,
        currency: String,
        sourceFile: String,
        rowHash: String
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.date = date
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cacheHitTokens = cacheHitTokens
        self.totalTokens = totalTokens
        self.cost = cost
        self.currency = currency
        self.sourceFile = sourceFile
        self.rowHash = rowHash
    }
}

public struct ModelUsage: Identifiable, Equatable, Sendable {
    public var id: String { model }
    public var model: String
    public var totalTokens: Int64
    public var cost: Double
    public var currency: String
}

public struct DailyUsage: Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var totalTokens: Int64
    public var cost: Double
}

public struct UsageSummary: Equatable, Sendable {
    public var todayCost: Double
    public var monthCost: Double
    public var todayTokens: Int64
    public var monthTokens: Int64
    public var currency: String
    public var modelUsages: [ModelUsage]
    public var dailyUsages: [DailyUsage]
    public var totalTokens: Int64

    public static let empty = UsageSummary(
        todayCost: 0,
        monthCost: 0,
        todayTokens: 0,
        monthTokens: 0,
        currency: "CNY",
        modelUsages: [],
        dailyUsages: [],
        totalTokens: 0
    )
}

public enum AIMonitorError: LocalizedError, Equatable {
    case missingAPIKey(Provider)
    case invalidResponse
    case importFailed(String)
    case keychainFailed(OSStatus)
    case databaseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider.displayName) API Key 尚未设置"
        case .invalidResponse:
            "服务返回的数据无法识别"
        case .importFailed(let message):
            message
        case .keychainFailed(let status):
            "Keychain 操作失败：\(status)"
        case .databaseFailed(let message):
            "数据库操作失败：\(message)"
        }
    }
}

public enum NumberFormatting {
    public static func money(_ value: Double?, currency: String) -> String {
        guard let value else { return "--" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: value as NSNumber) ?? "\(currency) \(String(format: "%.2f", value))"
    }

    public static func tokens(_ value: Int64) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 {
            return String(format: "%.1fB", number / 1_000_000_000)
        }
        if number >= 1_000_000 {
            return String(format: "%.1fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
    }
}
