import CryptoKit
import Foundation

public struct DeepSeekDashboardResponse: Sendable {
    public var url: URL
    public var statusCode: Int
    public var contentType: String?
    public var data: Data
}

public struct DeepSeekDashboardClient: Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(
        baseURL: URL = URL(string: "https://platform.deepseek.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fetchCurrentMonth(userToken: String, date: Date = Date(), calendar: Calendar = .current) async throws -> UsageFetchResult {
        let token = try Self.normalizedUserToken(userToken)
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? calendar.component(.year, from: date)
        let month = parts.month ?? calendar.component(.month, from: date)

        async let summaryResponse = fetchRaw(path: "/api/v0/users/get_user_summary", queryItems: [], userToken: token)
        async let amountResponse = fetchRaw(
            path: "/api/v0/usage/amount",
            queryItems: [
                URLQueryItem(name: "year", value: "\(year)"),
                URLQueryItem(name: "month", value: "\(month)")
            ],
            userToken: token
        )
        async let costResponse = fetchRaw(
            path: "/api/v0/usage/cost",
            queryItems: [
                URLQueryItem(name: "year", value: "\(year)"),
                URLQueryItem(name: "month", value: "\(month)")
            ],
            userToken: token
        )

        let responses = try await (summaryResponse, amountResponse, costResponse)
        return try Self.parse(
            summaryData: responses.0.data,
            amountData: responses.1.data,
            costData: responses.2.data,
            sourceFile: "deepseek-dashboard-\(year)-\(month)",
            calendar: calendar
        )
    }

    public func fetchRaw(path: String, queryItems: [URLQueryItem], userToken: String) async throws -> DeepSeekDashboardResponse {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AIMonitorError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw AIMonitorError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(try Self.normalizedUserToken(userToken))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.deepseek.com/usage", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIMonitorError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw AIMonitorError.importFailed("DeepSeek Dashboard HTTP \(httpResponse.statusCode)")
        }
        return DeepSeekDashboardResponse(
            url: url,
            statusCode: httpResponse.statusCode,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            data: data
        )
    }

    public static func normalizedUserToken(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIMonitorError.importFailed("DeepSeek Dashboard Token 为空")
        }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = object["value"] as? String,
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    public static func parse(
        summaryData: Data,
        amountData: Data,
        costData: Data,
        sourceFile: String = "deepseek-dashboard",
        calendar: Calendar = .current,
        capturedAt: Date = Date()
    ) throws -> UsageFetchResult {
        let summaryObject = try JSONSerialization.jsonObject(with: summaryData)
        let amountObject = try JSONSerialization.jsonObject(with: amountData)
        let costObject = try JSONSerialization.jsonObject(with: costData)
        let currency = summaryCurrency(from: summaryObject) ?? "CNY"
        let snapshots = balanceSnapshots(from: summaryObject, currency: currency, capturedAt: capturedAt)
        let costIndex = usageEntries(from: costObject, valueKind: .cost, calendar: calendar)
        let amountEntries = usageEntries(from: amountObject, valueKind: .tokens, calendar: calendar)

        let records = amountEntries.map { entry -> UsageRecord in
            let cost = costIndex.first { candidate in
                candidate.date == entry.date && candidate.model == entry.model
            }?.cost ?? 0
            let total = entry.totalTokens > 0 ? entry.totalTokens : entry.promptTokens + entry.cacheHitTokens + entry.completionTokens
            let canonical = [
                "deepseek",
                entry.model,
                ISO8601DateFormatter().string(from: entry.date),
                "\(entry.promptTokens)",
                "\(entry.completionTokens)",
                "\(entry.cacheHitTokens)",
                "\(total)",
                "\(cost)",
                currency
            ].joined(separator: "|")
            return UsageRecord(
                provider: .deepseek,
                model: entry.model,
                date: entry.date,
                promptTokens: entry.promptTokens,
                completionTokens: entry.completionTokens,
                cacheHitTokens: entry.cacheHitTokens,
                totalTokens: total,
                cost: cost,
                currency: currency,
                sourceFile: sourceFile,
                rowHash: stableHash(canonical)
            )
        }

        guard !snapshots.isEmpty || !records.isEmpty else {
            throw AIMonitorError.importFailed("没有在 DeepSeek Dashboard 响应中识别到余额或 token 用量字段")
        }
        return UsageFetchResult(records: records, balanceSnapshots: snapshots)
    }

    private enum UsageValueKind {
        case tokens
        case cost
    }

    private struct UsageEntry: Equatable {
        var model: String
        var date: Date
        var promptTokens: Int64 = 0
        var completionTokens: Int64 = 0
        var cacheHitTokens: Int64 = 0
        var totalTokens: Int64 = 0
        var cost: Double = 0
    }

    private static func balanceSnapshots(from object: Any, currency fallbackCurrency: String, capturedAt: Date) -> [BalanceSnapshot] {
        guard let summary = findDictionary(containingAny: ["normal_wallets", "bonus_wallets", "monthly_costs"], in: object) else {
            return []
        }

        let normalWallets = summary["normal_wallets"] as? [[String: Any]] ?? []
        let bonusWallets = summary["bonus_wallets"] as? [[String: Any]] ?? []
        let currencies = Set((normalWallets + bonusWallets).compactMap { stringValue($0, keys: ["currency"])?.uppercased() })
        let effectiveCurrencies = currencies.isEmpty ? [fallbackCurrency] : Array(currencies).sorted()

        // 从 summary 的 monthly_costs 汇总中提取权威的月度消耗值
        var monthlyCostByCurrency: [String: Double] = [:]
        if let monthlyCosts = summary["monthly_costs"] as? [[String: Any]] {
            for costDict in monthlyCosts {
                if let currency = stringValue(costDict, keys: ["currency"])?.uppercased(),
                   let amount = doubleValue(costDict, keys: ["total_cost", "totalAmount", "total", "amount"]) {
                    monthlyCostByCurrency[currency] = round(amount * 1_000_000) / 1_000_000
                }
            }
        }
        // 如果 summary 没有 monthly_costs 但有 total_cost 字段，直接使用
        if let summaryCurrency = stringValue(summary, keys: ["currency"])?.uppercased(),
           let totalAmount = doubleValue(summary, keys: ["total_cost", "totalCost", "monthly_total", "monthlyCost"]) {
            if monthlyCostByCurrency[summaryCurrency] == nil {
                monthlyCostByCurrency[summaryCurrency] = round(totalAmount * 1_000_000) / 1_000_000
            }
        }

        return effectiveCurrencies.compactMap { currency in
            let toppedUp = normalWallets
                .filter { stringValue($0, keys: ["currency"])?.caseInsensitiveCompare(currency) == .orderedSame }
                .compactMap { doubleValue($0, keys: ["balance"]) }
                .reduce(0, +)
            let granted = bonusWallets
                .filter { stringValue($0, keys: ["currency"])?.caseInsensitiveCompare(currency) == .orderedSame }
                .compactMap { doubleValue($0, keys: ["balance"]) }
                .reduce(0, +)
            // 金额四舍五入到 6 位小数，避免 Double 浮点累加误差（如 0.1 + 0.2 = 0.30000000000000004）
            // 同时保留 DeepSeek token 计费的高精度（token 计费可精确到小数点后 6 位）
            let total = round((toppedUp + granted) * 1_000_000) / 1_000_000
            let authoritativeMonthlyCost = monthlyCostByCurrency[currency]
            guard total > 0 || !normalWallets.isEmpty || !bonusWallets.isEmpty || authoritativeMonthlyCost != nil else { return nil }
            return BalanceSnapshot(
                provider: .deepseek,
                currency: currency,
                totalBalance: total,
                grantedBalance: round(granted * 1_000_000) / 1_000_000,
                toppedUpBalance: round(toppedUp * 1_000_000) / 1_000_000,
                creditTotal: intOrDoubleValue(summary, keys: ["current_token"]),
                creditUsed: intOrDoubleValue(summary, keys: ["monthly_token_usage", "monthly_usage"]),
                creditRemaining: intOrDoubleValue(summary, keys: ["total_available_token_estimation"]),
                monthlyCost: authoritativeMonthlyCost,
                source: .api,
                capturedAt: capturedAt
            )
        }
    }

    private static func summaryCurrency(from object: Any) -> String? {
        guard let summary = findDictionary(containingAny: ["monthly_costs", "normal_wallets", "bonus_wallets"], in: object) else {
            return nil
        }
        if let costs = summary["monthly_costs"] as? [[String: Any]],
           let currency = costs.compactMap({ stringValue($0, keys: ["currency"]) }).first {
            return currency.uppercased()
        }
        if let wallets = summary["normal_wallets"] as? [[String: Any]],
           let currency = wallets.compactMap({ stringValue($0, keys: ["currency"]) }).first {
            return currency.uppercased()
        }
        return nil
    }

    private static func usageEntries(from object: Any, valueKind: UsageValueKind, calendar: Calendar) -> [UsageEntry] {
        let payload = unwrapBizData(object)
        var entries: [UsageEntry] = []

        if let dictionary = payload as? [String: Any],
           let days = dictionary["days"] as? [Any] {
            for dayObject in days {
                entries.append(contentsOf: dayEntries(from: dayObject, valueKind: valueKind, calendar: calendar))
            }
        } else if let array = payload as? [Any] {
            for item in array {
                if let dictionary = item as? [String: Any],
                   let days = dictionary["days"] as? [Any] {
                    for dayObject in days {
                        entries.append(contentsOf: dayEntries(from: dayObject, valueKind: valueKind, calendar: calendar))
                    }
                }
            }
        }

        return entries
    }

    private static func dayEntries(from object: Any, valueKind: UsageValueKind, calendar: Calendar) -> [UsageEntry] {
        guard let dictionary = object as? [String: Any],
              let date = dateValue(dictionary, keys: ["date", "day", "time"], calendar: calendar) else {
            return []
        }

        let modelContainers = [
            dictionary["data"],
            dictionary["total"],
            dictionary["models"],
            dictionary["model_usages"],
            dictionary["modelUsage"],
            dictionary["usage"],
            dictionary["amount"]
        ].compactMap(\.self)

        if let directModel = stringValue(dictionary, keys: ["model", "model_name", "modelName"]) {
            return [entry(model: directModel, values: dictionary, date: date, valueKind: valueKind)]
        }

        for container in modelContainers {
            let entries = modelEntries(from: container, date: date, valueKind: valueKind)
            if !entries.isEmpty { return entries }
        }

        let ignoredKeys: Set<String> = ["date", "day", "time", "total"]
        let nestedModels = dictionary.compactMap { key, value -> UsageEntry? in
            guard !ignoredKeys.contains(key), let values = value as? [String: Any], isUsageDictionary(values) else { return nil }
            return entry(model: key, values: values, date: date, valueKind: valueKind)
        }
        return nestedModels
    }

    private static func modelEntries(from object: Any, date: Date, valueKind: UsageValueKind) -> [UsageEntry] {
        if let dictionary = object as? [String: Any] {
            return dictionary.compactMap { model, value in
                guard let values = value as? [String: Any], isUsageDictionary(values) else { return nil }
                return entry(model: model, values: values, date: date, valueKind: valueKind)
            }
        }
        if let array = object as? [Any] {
            return array.compactMap { item in
                guard let dictionary = item as? [String: Any],
                      let model = stringValue(dictionary, keys: ["model", "model_name", "modelName", "name"]) else {
                    return nil
                }
                return entry(model: model, values: normalizedUsageDictionary(dictionary), date: date, valueKind: valueKind)
            }
        }
        return []
    }

    private static func normalizedUsageDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        guard let usage = dictionary["usage"] as? [[String: Any]] else {
            return dictionary
        }
        var normalized = dictionary
        for item in usage {
            guard let type = stringValue(item, keys: ["type", "usage_type", "usageType"]),
                  let amount = item["amount"] ?? item["value"] else {
                continue
            }
            normalized[type] = amount
        }
        return normalized
    }

    private static func entry(model: String, values: [String: Any], date: Date, valueKind: UsageValueKind) -> UsageEntry {
        switch valueKind {
        case .tokens:
            let cacheHit = int64Value(values, keys: ["PROMPT_CACHE_HIT_TOKEN", "prompt_cache_hit_token", "cache_hit_tokens", "cacheHitTokens"]) ?? 0
            let promptMiss = int64Value(values, keys: ["PROMPT_CACHE_MISS_TOKEN", "prompt_cache_miss_token", "cache_miss_tokens", "cacheMissTokens"])
            let promptTotal = int64Value(values, keys: ["PROMPT_TOKEN", "prompt_token", "prompt_tokens", "promptTokens"])
            let prompt = promptMiss ?? max((promptTotal ?? 0) - cacheHit, 0)
            let completion = int64Value(values, keys: ["RESPONSE_TOKEN", "response_token", "completion_tokens", "completionTokens", "output_tokens"]) ?? 0
            let total = int64Value(values, keys: ["TOTAL_TOKEN", "total_token", "total_tokens", "totalTokens"]) ?? prompt + cacheHit + completion
            return UsageEntry(
                model: model,
                date: date,
                promptTokens: prompt,
                completionTokens: completion,
                cacheHitTokens: cacheHit,
                totalTokens: total
            )
        case .cost:
            let cost = doubleValue(values, keys: [
                "TOTAL",
                "total",
                "amount",
                "cost"
            ]) ?? sumUsageCosts(values)
            // cost 四舍五入到 6 位小数，避免 IEEE 754 浮点误差，同时保留 DeepSeek token 计费精度
            return UsageEntry(model: model, date: date, cost: round(cost * 1_000_000) / 1_000_000)
        }
    }

    private static func sumUsageCosts(_ values: [String: Any]) -> Double {
        values.reduce(0) { partial, pair in
            guard pair.key != "REQUEST" else { return partial }
            return partial + (doubleFromAny(pair.value) ?? 0)
        }
    }

    private static func isUsageDictionary(_ values: [String: Any]) -> Bool {
        values.keys.contains { key in
            [
                "PROMPT_TOKEN",
                "PROMPT_CACHE_HIT_TOKEN",
                "PROMPT_CACHE_MISS_TOKEN",
                "RESPONSE_TOKEN",
                "TOTAL_TOKEN",
                "total_tokens",
                "amount",
                "cost"
            ].contains(key)
        }
    }

    private static func unwrapBizData(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            if let data = dictionary["data"] {
                return unwrapBizData(data)
            }
            if let bizData = dictionary["biz_data"] {
                return bizData
            }
        }
        return object
    }

    private static func findDictionary(containingAny keys: [String], in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if keys.contains(where: { dictionary[$0] != nil }) {
                return dictionary
            }
            for value in dictionary.values {
                if let found = findDictionary(containingAny: keys, in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findDictionary(containingAny: keys, in: value) {
                    return found
                }
            }
        }
        return nil
    }

    private static func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
            if let value = dictionary[key] {
                return "\(value)"
            }
        }
        return nil
    }

    private static func doubleValue(_ dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = doubleFromAny(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private static func int64Value(_ dictionary: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let value = value as? Int64 { return value }
            if let value = value as? Int { return Int64(value) }
            if let value = value as? Double { return Int64(value) }
            if let value = value as? String, let parsed = Int64(value.replacingOccurrences(of: ",", with: "")) { return parsed }
        }
        return nil
    }

    private static func intOrDoubleValue(_ dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = doubleFromAny(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private static func doubleFromAny(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? String {
            return Double(value.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }

    private static func dateValue(_ dictionary: [String: Any], keys: [String], calendar: Calendar) -> Date? {
        guard let value = stringValue(dictionary, keys: keys) else { return nil }
        if let seconds = TimeInterval(value), seconds > 1_000_000_000 {
            return calendar.startOfDay(for: Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds))
        }
        if let date = ISO8601DateFormatter().date(from: value) {
            return calendar.startOfDay(for: date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }

    private static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
