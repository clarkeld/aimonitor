import Foundation
import CryptoKit

public struct MiMoDashboardResponse: Sendable {
    public var url: URL
    public var statusCode: Int
    public var contentType: String?
    public var data: Data
}

public struct MiMoDashboardClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(url: URL, cookie: String, billingMode: BillingMode) async throws -> UsageFetchResult {
        let response = try await fetchRaw(url: url, cookie: cookie)
        guard 200..<300 ~= response.statusCode else {
            throw AIMonitorError.importFailed("MiMo Dashboard HTTP \(response.statusCode)")
        }

        return try Self.parse(data: response.data, sourceFile: url.host ?? "mimo-dashboard", billingMode: billingMode)
    }

    public func fetchRaw(url: URL, cookie: String) async throws -> MiMoDashboardResponse {
        var requestURL = url
        // 所有 MiMo API 都需要在 URL 上附加 api-platform_ph 和 api-platform_slh 参数进行认证
        // 保留原有的查询参数（如 year/month），只追加认证参数
        if url.host?.localizedCaseInsensitiveContains("xiaomimimo.com") == true {
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let allowedChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
                var encodedItems: [URLQueryItem] = components.percentEncodedQueryItems ?? []
                
                // 先清除已有的认证参数，避免重复
                encodedItems.removeAll { $0.name == "api-platform_ph" || $0.name == "api-platform_slh" }
                
                if let phValue = CookieFormatter.extractValue(for: "api-platform_ph", from: cookie) {
                    let encoded = phValue.addingPercentEncoding(withAllowedCharacters: allowedChars) ?? phValue
                    encodedItems.append(URLQueryItem(name: "api-platform_ph", value: encoded))
                }
                
                if let slhValue = CookieFormatter.extractValue(for: "api-platform_slh", from: cookie) {
                    let encoded = slhValue.addingPercentEncoding(withAllowedCharacters: allowedChars) ?? slhValue
                    encodedItems.append(URLQueryItem(name: "api-platform_slh", value: encoded))
                }
                
                components.percentEncodedQueryItems = encodedItems
                if let newURL = components.url {
                    requestURL = newURL
                }
            }
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = Self.httpMethod(for: url)
        request.setValue(CookieFormatter.header(from: cookie), forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        let refererPath = url.path.localizedCaseInsensitiveContains("usage") || url.path.localizedCaseInsensitiveContains("bill")
            ? "/console/usage"
            : "/console/plan-manage"
        request.setValue("https://platform.xiaomimimo.com\(refererPath)", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        if let body = Self.requestBody(for: url) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIMonitorError.invalidResponse
        }

        return MiMoDashboardResponse(
            url: requestURL,
            statusCode: httpResponse.statusCode,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            data: data
        )
    }

    private static func httpMethod(for url: URL) -> String {
        // MiMo 消费账单明细接口需要 POST 才会返回金额数据
        url.path.localizedCaseInsensitiveContains("/usage/detail/list") ? "POST" : "GET"
    }

    private static func requestBody(for url: URL) -> Data? {
        guard url.path.localizedCaseInsensitiveContains("/usage/detail/list") else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month], from: Date())
        let payload: [String: Any] = [
            "year": parts.year ?? 0,
            "month": parts.month ?? 0
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    public static func dashboardAPIURLs(
        from configuredURLs: [URL],
        billingMode: BillingMode,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> [URL] {
        let apiURLs = configuredURLs.flatMap { configuredURL -> [URL] in
            if configuredURL.path.hasPrefix("/api/") {
                return [configuredURL]
            }

            guard configuredURL.host?.localizedCaseInsensitiveContains("xiaomimimo.com") == true,
                  var components = URLComponents(url: configuredURL, resolvingAgainstBaseURL: false) else {
                return [configuredURL]
            }

            components.scheme = "https"
            components.host = "platform.xiaomimimo.com"
            components.query = nil

            if configuredURL.path.localizedCaseInsensitiveContains("usage") {
                if billingMode == .tokenPlan {
                    components.path = "/api/v1/tokenPlan/usage"
                } else {
                    let parts = calendar.dateComponents([.year, .month], from: date)
                    let queryItems = [
                        URLQueryItem(name: "year", value: "\(parts.year ?? 0)"),
                        URLQueryItem(name: "month", value: "\(parts.month ?? 0)")
                    ]
                    let usagePaths = [
                        "/api/v1/usage/detail/list"
                    ]
                    return usagePaths.compactMap { path in
                        var candidate = components
                        candidate.path = path
                        candidate.queryItems = queryItems
                        return candidate.url
                    }
                }
                return components.url.map { [$0] } ?? []
            }

            if configuredURL.path.localizedCaseInsensitiveContains("balance") ||
                configuredURL.path.localizedCaseInsensitiveContains("plan-manage") {
                if billingMode == .tokenPlan {
                    let detail = components
                    var usage = components
                    var detailComponents = detail
                    detailComponents.path = "/api/v1/tokenPlan/detail"
                    usage.path = "/api/v1/tokenPlan/usage"
                    return [detailComponents.url, usage.url].compactMap(\.self)
                } else {
                    components.path = "/api/v1/balance"
                    return components.url.map { [$0] } ?? []
                }
            }

            return [configuredURL]
        }

        return deduplicated(apiURLs)
    }

    public static func parse(data: Data, sourceFile: String = "mimo-dashboard", billingMode: BillingMode = .tokenPlan) throws -> UsageFetchResult {
        let object: Any
        if let parsed = try? JSONSerialization.jsonObject(with: data) {
            object = parsed
        } else {
            throw AIMonitorError.invalidResponse
        }
        var dictionaries: [[String: Any]] = []
        collectDictionaries(from: object, into: &dictionaries)

        var records: [UsageRecord] = []
        var snapshots: [BalanceSnapshot] = []

        for dictionary in dictionaries {
            if let snapshot = balanceSnapshot(from: dictionary, billingMode: billingMode) {
                snapshots.append(snapshot)
            }
            if let record = usageRecord(from: dictionary, sourceFile: sourceFile) {
                records.append(record)
            }
        }
        records.append(contentsOf: payAsYouGoUsageRecords(from: object, sourceFile: sourceFile))

        let supplementalCostRecords = dailyCostRecords(from: object, sourceFile: sourceFile)
        if records.allSatisfy({ $0.cost == 0 }) {
            records.append(contentsOf: supplementalCostRecords)
        } else {
            let calendar = Calendar.current
            let daysWithCost = Set(records.filter { $0.cost > 0 }.map { calendar.startOfDay(for: $0.date) })
            records.append(contentsOf: supplementalCostRecords.filter { !daysWithCost.contains(calendar.startOfDay(for: $0.date)) })
        }

        records = mergeRecordsByDateAndModel(records, sourceFile: sourceFile)

        if records.isEmpty, snapshots.isEmpty {
            throw AIMonitorError.importFailed("没有在 MiMo 响应中识别到余额或 token 用量字段")
        }

        return UsageFetchResult(records: records, balanceSnapshots: snapshots)
    }

    private static func collectDictionaries(from object: Any, into dictionaries: inout [[String: Any]]) {
        if let dictionary = object as? [String: Any] {
            dictionaries.append(dictionary)
            for value in dictionary.values {
                collectDictionaries(from: value, into: &dictionaries)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectDictionaries(from: value, into: &dictionaries)
            }
        }
    }

    private static func balanceSnapshot(from dictionary: [String: Any], billingMode: BillingMode) -> BalanceSnapshot? {
        let currency = stringValue(dictionary, keys: ["currency", "currency_code", "unit"])?.uppercased() ?? "USD"
        let totalBalance = doubleValue(dictionary, keys: ["balance", "total_balance", "totalBalance", "amount", "remaining_balance", "remainingBalance", "availableBalance"])
        let creditTotal = doubleValue(dictionary, keys: ["credit_total", "creditTotal", "credits_total", "creditsTotal", "total_credits", "totalCredits", "quota", "quota_total", "quotaTotal", "total_quota", "totalQuota", "token_plan_total", "tokenPlanTotal", "limit", "total"])
        let creditUsed = doubleValue(dictionary, keys: ["credit_used", "creditUsed", "credits_used", "creditsUsed", "used_credits", "usedCredits", "quota_used", "quotaUsed", "used_quota", "usedQuota", "token_plan_used", "tokenPlanUsed", "usage", "used"])
        let creditRemaining = doubleValue(dictionary, keys: ["credit_remaining", "creditRemaining", "credits_remaining", "creditsRemaining", "remaining_credits", "remainingCredits", "credit_left", "creditLeft", "credits_left", "creditsLeft", "quota_remaining", "quotaRemaining", "remaining_quota", "remainingQuota", "token_plan_remaining", "tokenPlanRemaining", "remain", "remaining"])

        guard totalBalance != nil || creditTotal != nil || creditUsed != nil || creditRemaining != nil else {
            return nil
        }

        let roundedBalance = totalBalance != nil ? round(totalBalance! * 100) / 100 : nil
        return BalanceSnapshot(
            provider: .mimo,
            currency: currency,
            totalBalance: roundedBalance,
            creditTotal: billingMode == .tokenPlan ? creditTotal : nil,
            creditUsed: billingMode == .tokenPlan ? creditUsed : nil,
            creditRemaining: billingMode == .tokenPlan ? creditRemaining : nil,
            source: .api
        )
    }

    private static func usageRecord(from dictionary: [String: Any], sourceFile: String) -> UsageRecord? {
        guard let model = stringValue(dictionary, keys: ["model", "model_name", "modelName", "name"]) else {
            return nil
        }

        let promptTokens = intValue(dictionary, keys: [
            "prompt_tokens",
            "input_tokens",
            "inputTokens",
            "promptTokens",
            "inputMissToken",
            "input_miss_token",
            "input_miss_tokens",
            "inputMissTokens"
        ])
        let completionTokens = intValue(dictionary, keys: [
            "completion_tokens",
            "output_tokens",
            "outputTokens",
            "completionTokens",
            "outputToken"
        ])
        let totalTokens = intValue(dictionary, keys: [
            "total_tokens",
            "totalTokens",
            "tokens",
            "used_tokens",
            "usedTokens",
            "token_usage",
            "tokenUsage",
            "totalToken",
            "total_token"
        ])
        let cacheHitTokens = intValue(dictionary, keys: [
            "cache_hit_tokens",
            "cached_tokens",
            "cacheTokens",
            "inputHitToken",
            "input_hit_token",
            "input_hit_tokens",
            "inputHitTokens"
        ]) ?? 0

        guard promptTokens != nil || completionTokens != nil || totalTokens != nil else {
            return nil
        }

        // 严格要求有明确的 date 字段，拒绝无 date 的汇总/统计对象
        guard let date = dateValue(dictionary, keys: ["date", "day", "created_at", "createdAt", "time", "timestamp"]) else {
            return nil
        }
        let currency = stringValue(dictionary, keys: ["currency", "currency_code"])?.uppercased() ?? "USD"
        let cost = usageCost(from: dictionary)
        let prompt = Int64(promptTokens ?? 0)
        let completion = Int64(completionTokens ?? 0)
        let total = Int64(totalTokens ?? (promptTokens ?? 0) + (completionTokens ?? 0))
        let canonical = [
            "mimo",
            model,
            ISO8601DateFormatter().string(from: date),
            "\(prompt)",
            "\(completion)",
            "\(cacheHitTokens)",
            "\(total)",
            "\(cost)",
            currency
        ].joined(separator: "|")

        return UsageRecord(
            provider: .mimo,
            model: model,
            date: date,
            promptTokens: prompt,
            completionTokens: completion,
            cacheHitTokens: Int64(cacheHitTokens),
            totalTokens: total,
            cost: cost,
            currency: currency,
            sourceFile: sourceFile,
            rowHash: stableHash(canonical)
        )
    }

    private static func payAsYouGoUsageRecords(from object: Any, sourceFile: String) -> [UsageRecord] {
        var dictionaries: [[String: Any]] = []
        collectDictionaries(from: object, into: &dictionaries)

        for dictionary in dictionaries {
            guard let modelUsages = dictionary["modelTokenUsage"] as? [[String: Any]] else { continue }
            return modelUsages.flatMap { modelUsage -> [UsageRecord] in
                guard let model = stringValue(modelUsage, keys: ["model", "modelName", "model_name"]),
                      let rows = modelUsage["usageDetail"] as? [[Any]] else {
                    return []
                }
                return rows.compactMap { row in
                    usageRecord(model: model, row: row, sourceFile: sourceFile)
                }
            }
        }

        for dictionary in dictionaries {
            guard let tokenUsage = dictionary["tokenUsage"] as? [String: Any] else { continue }
            let promptTokens = intValue(tokenUsage, keys: ["inputToken", "input_token", "inputTokens", "prompt_tokens"]) ?? 0
            let completionTokens = intValue(tokenUsage, keys: ["outputToken", "output_token", "outputTokens", "completion_tokens"]) ?? 0
            let totalTokens = intValue(tokenUsage, keys: ["totalToken", "total_token", "totalTokens", "total_tokens"]) ?? promptTokens + completionTokens
            let cacheTokens = intValue(tokenUsage, keys: ["cacheToken", "cache_token", "cacheTokens", "cached_tokens"]) ?? 0
            guard totalTokens > 0 else { continue }
            return [
                usageRecord(
                    model: "MiMo API",
                    date: Calendar.current.startOfDay(for: Date()),
                    promptTokens: Int64(promptTokens),
                    completionTokens: Int64(completionTokens),
                    cacheHitTokens: Int64(cacheTokens),
                    totalTokens: Int64(totalTokens),
                    cost: 0,
                    currency: "CNY",
                    sourceFile: sourceFile
                )
            ]
        }

        return []
    }

    private static func dailyCostRecords(from object: Any, sourceFile: String) -> [UsageRecord] {
        var records: [UsageRecord] = []
        collectDailyCostRecords(from: object, keyHint: nil, sourceFile: sourceFile, into: &records)
        return deduplicated(records)
    }

    private static func collectDailyCostRecords(from object: Any, keyHint: String?, sourceFile: String, into records: inout [UsageRecord]) {
        if let dictionary = object as? [String: Any] {
            if let record = dailyCostRecord(from: dictionary, sourceFile: sourceFile) {
                records.append(record)
            }
            records.append(contentsOf: pairedDailyCostRecords(from: dictionary, sourceFile: sourceFile))
            for (key, value) in dictionary {
                collectDailyCostRecords(from: value, keyHint: key, sourceFile: sourceFile, into: &records)
            }
        } else if let array = object as? [Any] {
            if isCostKey(keyHint) {
                records.append(contentsOf: array.compactMap { item in
                    if let row = item as? [Any] {
                        return dailyCostRecord(from: row, sourceFile: sourceFile)
                    }
                    if let dictionary = item as? [String: Any] {
                        return dailyCostRecord(from: dictionary, sourceFile: sourceFile)
                    }
                    return nil
                })
            }
            for value in array {
                collectDailyCostRecords(from: value, keyHint: keyHint, sourceFile: sourceFile, into: &records)
            }
        }
    }

    private static func dailyCostRecord(from dictionary: [String: Any], sourceFile: String) -> UsageRecord? {
        guard let date = dateValue(dictionary, keys: ["date", "day", "created_at", "createdAt", "time", "timestamp"]) else {
            return nil
        }
        let cost = usageCost(from: dictionary)
        guard cost > 0 else { return nil }
        let currency = stringValue(dictionary, keys: ["currency", "currency_code"])?.uppercased() ?? "CNY"
        return usageRecord(
            model: "MiMo API",
            date: date,
            promptTokens: 0,
            completionTokens: 0,
            cacheHitTokens: 0,
            totalTokens: 0,
            cost: cost,
            currency: currency,
            sourceFile: sourceFile
        )
    }

    private static func pairedDailyCostRecords(from dictionary: [String: Any], sourceFile: String) -> [UsageRecord] {
        let dateArrays = dictionary.compactMap { key, value -> [Date]? in
            guard isDateSeriesKey(key), let values = value as? [Any] else { return nil }
            let dates = values.compactMap { monthDayDate($0) ?? dateFromAny($0) }
            return dates.count == values.count ? dates : nil
        }
        guard !dateArrays.isEmpty else { return [] }

        let costArrays = costSeriesArrays(from: dictionary)
        var records: [UsageRecord] = []
        for dates in dateArrays {
            for costs in costArrays where dates.count == costs.count {
                for (date, cost) in zip(dates, costs) where cost > 0 {
                    records.append(usageRecord(
                        model: "MiMo API",
                        date: date,
                        promptTokens: 0,
                        completionTokens: 0,
                        cacheHitTokens: 0,
                        totalTokens: 0,
                        cost: cost,
                        currency: "CNY",
                        sourceFile: sourceFile
                    ))
                }
            }
        }
        return records
    }

    private static func costSeriesArrays(from dictionary: [String: Any]) -> [[Double]] {
        var arrays: [[Double]] = []
        for (key, value) in dictionary {
            if isCostKey(key), let values = value as? [Any] {
                let costs = values.compactMap(doubleFromAny)
                if costs.count == values.count {
                    arrays.append(costs)
                }
            }
            if key.localizedCaseInsensitiveContains("series"), let series = value as? [[String: Any]] {
                for item in series {
                    let name = stringValue(item, keys: ["name", "label", "title"])
                    guard isCostKey(name) || item.keys.contains(where: isCostKey) else { continue }
                    for (seriesKey, seriesValue) in item where isCostKey(seriesKey) || seriesKey == "data" || seriesKey == "values" {
                        guard let values = seriesValue as? [Any] else { continue }
                        let costs = values.compactMap(doubleFromAny)
                        if costs.count == values.count {
                            arrays.append(costs)
                        }
                    }
                }
            }
        }
        return arrays
    }

    private static func dailyCostRecord(from row: [Any], sourceFile: String) -> UsageRecord? {
        guard row.count >= 2,
              let date = monthDayDate(row[0]) ?? dateFromAny(row[0]),
              let cost = doubleFromAny(row[1]),
              cost > 0 else {
            return nil
        }
        return usageRecord(
            model: "MiMo API",
            date: date,
            promptTokens: 0,
            completionTokens: 0,
            cacheHitTokens: 0,
            totalTokens: 0,
            cost: cost,
            currency: "CNY",
            sourceFile: sourceFile
        )
    }

    private static func usageRecord(model: String, row: [Any], sourceFile: String) -> UsageRecord? {
        if let billingRecord = billingUsageRecord(model: model, row: row, sourceFile: sourceFile) {
            return billingRecord
        }

        guard row.count >= 4,
              let date = monthDayDate(row[0]),
              let promptTokens = intFromAny(row[1]),
              let completionTokens = intFromAny(row[2]),
              let totalTokens = intFromAny(row[3]) else {
            return nil
        }
        let cacheTokens = row.count > 4 ? intFromAny(row[4]) ?? 0 : 0
        return usageRecord(
            model: model,
            date: date,
            promptTokens: Int64(promptTokens),
            completionTokens: Int64(completionTokens),
            cacheHitTokens: Int64(cacheTokens),
            totalTokens: Int64(totalTokens),
            cost: 0,
            currency: "CNY",
            sourceFile: sourceFile
        )
    }

    private static func billingUsageRecord(model: String, row: [Any], sourceFile: String) -> UsageRecord? {
        guard row.count >= 9,
              let date = monthDayDate(row[0]) ?? dateFromAny(row[0]),
              let cost = doubleFromAny(row[1]),
              let totalTokens = intFromAny(row[5]),
              let cacheHitTokens = intFromAny(row[6]),
              let promptTokens = intFromAny(row[7]),
              let completionTokens = intFromAny(row[8]) else {
            return nil
        }

        return usageRecord(
            model: model,
            date: date,
            promptTokens: Int64(promptTokens),
            completionTokens: Int64(completionTokens),
            cacheHitTokens: Int64(cacheHitTokens),
            totalTokens: Int64(totalTokens),
            cost: cost,
            currency: "CNY",
            sourceFile: sourceFile
        )
    }

    private static func usageRecord(
        model: String,
        date: Date,
        promptTokens: Int64,
        completionTokens: Int64,
        cacheHitTokens: Int64,
        totalTokens: Int64,
        cost: Double,
        currency: String,
        sourceFile: String
    ) -> UsageRecord {
        let canonical = [
            "mimo",
            model,
            ISO8601DateFormatter().string(from: date),
            "\(promptTokens)",
            "\(completionTokens)",
            "\(cacheHitTokens)",
            "\(totalTokens)",
            "\(cost)",
            currency
        ].joined(separator: "|")

        return UsageRecord(
            provider: .mimo,
            model: model,
            date: date,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cacheHitTokens: cacheHitTokens,
            totalTokens: totalTokens,
            cost: cost,
            currency: currency,
            sourceFile: sourceFile,
            rowHash: stableHash(canonical)
        )
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
            if let value = dictionary[key] as? Double { return value }
            if let value = dictionary[key] as? Int { return Double(value) }
            if let value = dictionary[key] as? String, let parsed = doubleFromString(value) { return parsed }
        }
        return nil
    }

    private static func intValue(_ dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key] as? Int { return value }
            if let value = dictionary[key] as? Double { return Int(value) }
            if let value = dictionary[key] as? String, let parsed = Int(value.replacingOccurrences(of: ",", with: "")) { return parsed }
        }
        return nil
    }

    private static func intFromAny(_ value: Any) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value.replacingOccurrences(of: ",", with: "")) }
        return nil
    }

    private static func doubleFromAny(_ value: Any) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return doubleFromString(value) }
        return nil
    }

    private static func doubleFromString(_ value: String) -> Double? {
        let normalized = value
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private static func usageCost(from dictionary: [String: Any]) -> Double {
        if let total = doubleValue(dictionary, keys: [
            "consumedAmount",
            "consumptionAmount",
            "modelConsumptionAmount",
            "singleModelConsumptionAmount",
            "totalAmountConsumption",
            "monthlyExpense",
            "cost",
            "amount",
            "fee",
            "price",
            "spend",
            "spent"
        ]) {
            return total
        }

        return [
            "inputHitAmount",
            "inputMissAmount",
            "outputAmount",
            "webSearchAmount",
            "pluginTotalAmount"
        ].compactMap { doubleValue(dictionary, keys: [$0]) }.reduce(0, +)
    }

    private static func isCostKey(_ key: String?) -> Bool {
        guard let key = key?.lowercased() else { return false }
        return [
            "cost",
            "amount",
            "expense",
            "fee",
            "spend",
            "spent",
            "consume",
            "consumption"
        ].contains { key.contains($0) }
    }

    private static func isDateSeriesKey(_ key: String) -> Bool {
        let key = key.lowercased()
        return [
            "date",
            "day",
            "time",
            "xaxis",
            "x_axis",
            "category",
            "categories"
        ].contains { key.contains($0) }
    }

    private static func monthDayDate(_ value: Any) -> Date? {
        guard let value = value as? String else { return nil }
        let year = Calendar.current.component(.year, from: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: "\(year)-\(value)")
    }

    private static func dateFromAny(_ value: Any) -> Date? {
        guard let value = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func dateValue(_ dictionary: [String: Any], keys: [String]) -> Date? {
        guard let value = stringValue(dictionary, keys: keys) else { return nil }
        if let seconds = TimeInterval(value), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(url)
        }
        return result
    }

    private static func deduplicated(_ records: [UsageRecord]) -> [UsageRecord] {
        var seen: Set<String> = []
        var result: [UsageRecord] = []
        for record in records {
            guard !seen.contains(record.rowHash) else { continue }
            seen.insert(record.rowHash)
            result.append(record)
        }
        return result
    }

    private static func mergeRecordsByDateAndModel(_ records: [UsageRecord], sourceFile: String) -> [UsageRecord] {
        let calendar = Calendar.current
        struct Key: Hashable {
            let day: Date
            let model: String
        }
        var groups: [Key: [UsageRecord]] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            let key = Key(day: day, model: record.model)
            groups[key, default: []].append(record)
        }
        var merged: [UsageRecord] = []
        for (key, group) in groups {
            if group.count == 1 {
                merged.append(group[0])
                continue
            }
            let hasCost = group.contains { $0.cost > 0 }
            let hasTokens = group.contains { $0.totalTokens > 0 }
            if hasCost && hasTokens {
                let bestCost = group.max { $0.cost < $1.cost }!
                let bestTokens = group.max { $0.totalTokens < $1.totalTokens }!
                let prompt = max(bestCost.promptTokens, bestTokens.promptTokens)
                let completion = max(bestCost.completionTokens, bestTokens.completionTokens)
                let cache = max(bestCost.cacheHitTokens, bestTokens.cacheHitTokens)
                let total = max(bestCost.totalTokens, bestTokens.totalTokens)
                merged.append(usageRecord(
                    model: key.model,
                    date: key.day,
                    promptTokens: prompt,
                    completionTokens: completion,
                    cacheHitTokens: cache,
                    totalTokens: total,
                    cost: bestCost.cost,
                    currency: bestCost.currency,
                    sourceFile: sourceFile
                ))
            } else {
                let totalPrompt = group.map { $0.promptTokens }.max() ?? 0
                let totalCompletion = group.map { $0.completionTokens }.max() ?? 0
                let totalCache = group.map { $0.cacheHitTokens }.max() ?? 0
                let totalTokens = group.map { $0.totalTokens }.max() ?? 0
                let totalCost = group.map { $0.cost }.max() ?? 0
                let currency = group.first { $0.currency != "USD" }?.currency ?? (group.first?.currency ?? "CNY")
                if totalTokens > 0 || totalCost > 0 {
                    merged.append(usageRecord(
                        model: key.model,
                        date: key.day,
                        promptTokens: totalPrompt,
                        completionTokens: totalCompletion,
                        cacheHitTokens: totalCache,
                        totalTokens: totalTokens,
                        cost: totalCost,
                        currency: currency,
                        sourceFile: sourceFile
                    ))
                }
            }
        }
        return merged.sorted { $0.date < $1.date }
    }
}
