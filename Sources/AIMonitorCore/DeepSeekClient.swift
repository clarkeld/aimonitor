import Foundation

public struct DeepSeekClient: Sendable {
    public var endpoint: URL
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "https://api.deepseek.com/user/balance")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    public func fetchBalances(apiKey: String) async throws -> [BalanceSnapshot] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIMonitorError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw AIMonitorError.importFailed("DeepSeek HTTP \(httpResponse.statusCode)")
        }
        return try Self.parseBalanceResponse(data: data, capturedAt: Date())
    }

    public static func parseBalanceResponse(data: Data, capturedAt: Date = Date()) throws -> [BalanceSnapshot] {
        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        guard !response.balanceInfos.isEmpty else {
            return [
                BalanceSnapshot(
                    provider: .deepseek,
                    currency: "CNY",
                    totalBalance: 0,
                    grantedBalance: 0,
                    toppedUpBalance: 0,
                    isAvailable: response.isAvailable,
                    source: .api,
                    capturedAt: capturedAt
                )
            ]
        }
        return response.balanceInfos.map { item in
            // 金额字符串转 Double 后四舍五入到 2 位小数，避免 "15.33" 变成 15.329999999...
            let total = Double(item.totalBalance).flatMap { round($0 * 100) / 100 }
            let granted = Double(item.grantedBalance).flatMap { round($0 * 100) / 100 }
            let toppedUp = Double(item.toppedUpBalance).flatMap { round($0 * 100) / 100 }
            return BalanceSnapshot(
                provider: .deepseek,
                currency: item.currency,
                totalBalance: total,
                grantedBalance: granted,
                toppedUpBalance: toppedUp,
                isAvailable: response.isAvailable,
                source: .api,
                capturedAt: capturedAt
            )
        }
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    var isAvailable: Bool
    var balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    var currency: String
    var totalBalance: String
    var grantedBalance: String
    var toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}
