import Foundation
import Testing
@testable import AIMonitorCore

struct DeepSeekClientTests {
    @Test func parsesSingleCurrencyBalance() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "927.23",
              "granted_balance": "10.00",
              "topped_up_balance": "917.23"
            }
          ]
        }
        """
        let snapshots = try DeepSeekClient.parseBalanceResponse(data: Data(json.utf8))
        #expect(snapshots.count == 1)
        #expect(snapshots[0].provider == .deepseek)
        #expect(snapshots[0].currency == "CNY")
        #expect(snapshots[0].totalBalance == 927.23)
        #expect(snapshots[0].isAvailable)
    }

    @Test func parsesMultipleCurrencies() throws {
        let json = """
        {
          "is_available": false,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "12.30",
              "granted_balance": "1.00",
              "topped_up_balance": "11.30"
            },
            {
              "currency": "USD",
              "total_balance": "3.40",
              "granted_balance": "0.00",
              "topped_up_balance": "3.40"
            }
          ]
        }
        """
        let snapshots = try DeepSeekClient.parseBalanceResponse(data: Data(json.utf8))
        #expect(snapshots.map(\.currency) == ["CNY", "USD"])
        #expect(snapshots[1].totalBalance == 3.40)
        #expect(!snapshots[0].isAvailable)
    }

    @Test func extractsDashboardTokenFromLocalStorageJSON() throws {
        let raw = #"{"value":"sample-token","__version":"0"}"#

        #expect(try DeepSeekDashboardClient.normalizedUserToken(raw) == "sample-token")
    }

    @Test func parsesDashboardSummaryAndUsage() throws {
        let summaryJSON = """
        {
          "data": {
            "biz_data": {
              "current_token": 10000000,
              "monthly_usage": "132699413",
              "normal_wallets": [
                {"currency":"CNY","balance":"15.3392012000000000","token_estimation":"5113067"}
              ],
              "bonus_wallets": [
                {"currency":"CNY","balance":"1.2500000000000000","token_estimation":"0"}
              ],
              "total_available_token_estimation": "5113067",
              "monthly_costs": [
                {"currency":"CNY","amount":"6.6085262000000000"}
              ],
              "monthly_token_usage": "132699413"
            }
          }
        }
        """
        let amountJSON = """
        {
          "data": {
            "biz_data": {
              "days": [
                {
                  "date": "2026-06-09",
                  "total": {
                    "deepseek-chat": {
                      "PROMPT_TOKEN": "120",
                      "PROMPT_CACHE_HIT_TOKEN": "40",
                      "PROMPT_CACHE_MISS_TOKEN": "80",
                      "RESPONSE_TOKEN": "30",
                      "REQUEST": "2"
                    },
                    "deepseek-reasoner": {
                      "PROMPT_CACHE_MISS_TOKEN": "10",
                      "RESPONSE_TOKEN": "5"
                    }
                  }
                }
              ]
            }
          }
        }
        """
        let costJSON = """
        {
          "data": {
            "biz_data": [
              {
                "days": [
                  {
                    "date": "2026-06-09",
                    "total": {
                      "deepseek-chat": {
                        "PROMPT_CACHE_HIT_TOKEN": "0.001",
                        "PROMPT_CACHE_MISS_TOKEN": "0.008",
                        "RESPONSE_TOKEN": "0.012",
                        "REQUEST": "0"
                      },
                      "deepseek-reasoner": {
                        "PROMPT_CACHE_MISS_TOKEN": "0.010",
                        "RESPONSE_TOKEN": "0.020"
                      }
                    }
                  }
                ]
              }
            ]
          }
        }
        """

        let result = try DeepSeekDashboardClient.parse(
            summaryData: Data(summaryJSON.utf8),
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(abs((result.balanceSnapshots.first?.totalBalance ?? 0) - 16.5892012) < 0.000001)
        #expect(result.balanceSnapshots.first?.creditUsed == 132699413)
        #expect(result.records.count == 2)
        let chat = try #require(result.records.first { $0.model == "deepseek-chat" })
        #expect(chat.promptTokens == 80)
        #expect(chat.cacheHitTokens == 40)
        #expect(chat.completionTokens == 30)
        #expect(chat.totalTokens == 150)
        #expect(abs(chat.cost - 0.021) < 0.000001)
    }

    @Test func parsesDashboardUsageArrayRows() throws {
        let summaryJSON = """
        {"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"3.50"}],"bonus_wallets":[],"monthly_costs":[{"currency":"CNY","amount":"1"}]}}}
        """
        let amountJSON = """
        {
          "data": {
            "biz_data": {
              "days": [
                {
                  "date": "2026-06-09",
                  "data": [
                    {
                      "model": "deepseek-v4-pro",
                      "usage": [
                        {"type":"PROMPT_TOKEN","amount":"100"},
                        {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"25"},
                        {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"75"},
                        {"type":"RESPONSE_TOKEN","amount":"20"},
                        {"type":"REQUEST","amount":"1"}
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let costJSON = """
        {
          "data": {
            "biz_data": {
              "days": [
                {
                  "date": "2026-06-09",
                  "data": [
                    {
                      "model": "deepseek-v4-pro",
                      "usage": [
                        {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.001"},
                        {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"0.007"},
                        {"type":"RESPONSE_TOKEN","amount":"0.010"},
                        {"type":"REQUEST","amount":"0"}
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let result = try DeepSeekDashboardClient.parse(
            summaryData: Data(summaryJSON.utf8),
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8)
        )

        let record = try #require(result.records.first)
        #expect(record.model == "deepseek-v4-pro")
        #expect(record.promptTokens == 75)
        #expect(record.cacheHitTokens == 25)
        #expect(record.completionTokens == 20)
        #expect(record.totalTokens == 120)
        #expect(abs(record.cost - 0.018) < 0.000001)
    }
}
