import Foundation
import Testing
@testable import AIMonitorCore

struct MiMoDashboardClientTests {
    @Test func expandsTokenPlanDashboardURLsToAPIEndpoints() throws {
        let urls = MiMoDashboardClient.dashboardAPIURLs(
            from: [try #require(URL(string: "https://platform.xiaomimimo.com/console/balance"))],
            billingMode: .tokenPlan
        )

        #expect(urls.map(\.absoluteString) == [
            "https://platform.xiaomimimo.com/api/v1/tokenPlan/detail",
            "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage"
        ])
    }

    @Test func expandsMiMoDashboardURLsEvenWhenBillingModeIsPayAsYouGo() throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 6, day: 9)))
        let urls = MiMoDashboardClient.dashboardAPIURLs(
            from: [
                try #require(URL(string: "https://platform.xiaomimimo.com/console/balance")),
                try #require(URL(string: "https://platform.xiaomimimo.com/console/usage"))
            ],
            billingMode: .payAsYouGo,
            date: date,
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(urls.map(\.absoluteString) == [
            "https://platform.xiaomimimo.com/api/v1/balance",
            "https://platform.xiaomimimo.com/api/v1/usage/detail/list?year=2026&month=6"
        ])
    }

    @Test func parsesPayAsYouGoBalanceAndUsageDetail() throws {
        let balanceJSON = """
        {"code":0,"message":"","data":{"balance":"25.89","frozenBalance":"0.00","currency":"CNY","giftBalance":"25.89","cashBalance":"0.00"}}
        """
        let usageJSON = """
        {"code":0,"message":"","data":{"tokenUsage":[["06-06",15441278,26637,15467915,14591040]],"modelTokenUsage":[{"model":"mimo-v2.5","usageDetail":[["06-06",15441278,26637,15467915,14591040]]}]}}
        """

        let balance = try MiMoDashboardClient.parse(data: Data(balanceJSON.utf8), billingMode: .payAsYouGo)
        let usage = try MiMoDashboardClient.parse(data: Data(usageJSON.utf8), billingMode: .payAsYouGo)

        #expect(balance.balanceSnapshots.first?.totalBalance == 25.89)
        #expect(balance.balanceSnapshots.first?.currency == "CNY")
        #expect(usage.records.first?.model == "mimo-v2.5")
        #expect(usage.records.first?.promptTokens == 15441278)
        #expect(usage.records.first?.completionTokens == 26637)
        #expect(usage.records.first?.totalTokens == 15467915)
        #expect(usage.records.first?.cacheHitTokens == 14591040)
    }

    @Test func parsesPayAsYouGoUsageDetailAmounts() throws {
        let usageJSON = """
        {
          "code": 0,
          "message": "",
          "data": {
            "modelTokenUsage": [
              {
                "model": "mimo-v2.5",
                "usageDetail": [
                  ["06-09", "0.42", "0.03", "0.09", "0.30", 15467915, 14591040, 850238, 26637]
                ]
              }
            ]
          }
        }
        """

        let usage = try MiMoDashboardClient.parse(data: Data(usageJSON.utf8), billingMode: .payAsYouGo)
        let record = try #require(usage.records.first)

        #expect(record.model == "mimo-v2.5")
        #expect(record.cost == 0.42)
        #expect(record.totalTokens == 15467915)
        #expect(record.cacheHitTokens == 14591040)
        #expect(record.promptTokens == 850238)
        #expect(record.completionTokens == 26637)
    }

    @Test func parsesDailyAmountSeriesWhenTokenRowsHaveNoCosts() throws {
        let usageJSON = """
        {
          "code": 0,
          "message": "",
          "data": {
            "tokenUsage": [["06-09", 100, 50, 150, 25]],
            "modelTokenUsage": [
              {"model": "mimo-v2.5", "usageDetail": [["06-09", 100, 50, 150, 25]]}
            ],
            "consumedAmount": [
              ["06-09", "0.42"],
              ["06-08", "0.10"]
            ]
          }
        }
        """

        let usage = try MiMoDashboardClient.parse(data: Data(usageJSON.utf8), billingMode: .payAsYouGo)

        #expect(usage.records.contains { $0.model == "mimo-v2.5" && $0.totalTokens == 150 })
        #expect(usage.records.contains { $0.model == "MiMo API" && $0.cost == 0.42 })
        #expect(usage.records.contains { $0.model == "MiMo API" && $0.cost == 0.10 })
    }

    @Test func parsesConsumptionBillChartAmounts() throws {
        let usageJSON = """
        {
          "code": 0,
          "message": "",
          "data": {
            "currency": "CNY",
            "totalAmountConsumption": "4.27",
            "consumptionBill": {
              "dateList": ["2026-06-06", "2026-06-07", "2026-06-08", "2026-06-09"],
              "consumedAmount": ["0.00", "1.25", "1.75", "1.27"]
            }
          }
        }
        """

        let usage = try MiMoDashboardClient.parse(data: Data(usageJSON.utf8), billingMode: .payAsYouGo)

        #expect(usage.records.filter { $0.model == "MiMo API" }.map(\.cost).reduce(0, +) == 4.27)
        #expect(usage.records.contains { $0.cost == 1.27 })
    }

    @Test func parsesConsumptionBillDailyObjects() throws {
        let usageJSON = """
        {
          "code": 0,
          "message": "",
          "data": {
            "dailyBill": [
              {"date": "2026-06-08", "consumptionAmount": "1.75", "currency": "CNY"},
              {"date": "2026-06-09", "totalAmountConsumption": "1.27", "currency": "CNY"}
            ]
          }
        }
        """

        let usage = try MiMoDashboardClient.parse(data: Data(usageJSON.utf8), billingMode: .payAsYouGo)

        #expect(usage.records.contains { $0.cost == 1.75 && $0.currency == "CNY" })
        #expect(usage.records.contains { $0.cost == 1.27 && $0.currency == "CNY" })
    }

    @Test func parsesCamelCaseTokenPlanCredits() throws {
        let json = """
        {
          "data": {
            "totalCredits": 1000000,
            "usedCredits": 250000,
            "remainingCredits": 750000
          }
        }
        """

        let result = try MiMoDashboardClient.parse(data: Data(json.utf8))

        #expect(result.balanceSnapshots.first?.creditTotal == 1000000)
        #expect(result.balanceSnapshots.first?.creditUsed == 250000)
        #expect(result.balanceSnapshots.first?.creditRemaining == 750000)
    }

    @Test func parsesFlexibleDashboardJSON() throws {
        let json = """
        {
          "data": {
            "quota_total": 1000,
            "quota_used": 125,
            "quota_remaining": 875,
            "currency": "USD",
            "items": [
              {
                "created_at": "2026-06-08T12:00:00Z",
                "model_name": "V4 Flash",
                "input_tokens": 100,
                "output_tokens": 50,
                "cost": "0.03",
                "currency": "USD"
              }
            ]
          }
        }
        """

        let result = try MiMoDashboardClient.parse(data: Data(json.utf8))

        #expect(result.balanceSnapshots.count == 1)
        #expect(result.balanceSnapshots[0].creditRemaining == 875)
        #expect(result.records.count == 1)
        #expect(result.records[0].provider == .mimo)
        #expect(result.records[0].model == "V4 Flash")
        #expect(result.records[0].totalTokens == 150)
    }

    @Test func parsesPayAsYouGoUsageDetailListArray() throws {
        let usageJSON = """
        {
          "code": 0,
          "message": "",
          "data": [
            {
              "date": "2026-06-09",
              "model": "mimo-v2.5",
              "apiKey": "sk-c4w1ya************************************ih6ki5",
              "currency": "CNY",
              "consumedAmount": "0.156665",
              "inputHitAmount": "0.028766",
              "inputMissAmount": "0.099323",
              "outputAmount": "0.028576",
              "totalToken": 1551883,
              "inputHitToken": 1438272,
              "inputMissToken": 99323,
              "outputToken": 14288,
              "requestCount": 29,
              "inputAudioDuration": 0
            },
            {
              "date": "2026-06-08",
              "model": "mimo-v2.5",
              "apiKey": "sk-c4w1ya************************************ih6ki5",
              "currency": "CNY",
              "consumedAmount": "0.093196",
              "inputHitAmount": "0.018159",
              "inputMissAmount": "0.065081",
              "outputAmount": "0.009956",
              "totalToken": 977963,
              "inputHitToken": 907904,
              "inputMissToken": 65081,
              "outputToken": 4978,
              "requestCount": 30,
              "inputAudioDuration": 0
            }
          ]
        }
        """

        let usage = try MiMoDashboardClient.parse(data: Data(usageJSON.utf8), billingMode: .payAsYouGo)

        #expect(usage.records.count == 2)
        let first = try #require(usage.records.first { $0.date == Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 6, day: 9)) })
        #expect(first.model == "mimo-v2.5")
        #expect(first.cost == 0.156665)
        #expect(first.currency == "CNY")
        #expect(first.totalTokens == 1551883)
        #expect(first.cacheHitTokens == 1438272)
        #expect(first.promptTokens == 99323)
        #expect(first.completionTokens == 14288)

        let totalCost = usage.records.reduce(0.0) { $0 + $1.cost }
        #expect(abs(totalCost - (0.156665 + 0.093196)) < 0.0001)
    }

}
