import Foundation
import Testing
@testable import AIMonitorCore

struct SQLiteStoreTests {
    @Test func usageRecordsAreDedupedAndAggregated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: directory.appendingPathComponent("test.sqlite"))

        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 8))!
        let record = UsageRecord(
            provider: .deepseek,
            model: "deepseek-chat",
            date: date,
            promptTokens: 100,
            completionTokens: 50,
            totalTokens: 150,
            cost: 1.25,
            currency: "CNY",
            sourceFile: "deepseek-dashboard-2026-6",
            rowHash: "same-row"
        )

        #expect(try store.insertUsageRecords([record, record]) == 1)
        let summary = try store.usageSummary(provider: .deepseek, asOf: date, calendar: calendar)
        #expect(summary.todayCost == 1.25)
        #expect(summary.monthCost == 1.25)
        #expect(summary.todayTokens == 150)
        #expect(summary.monthTokens == 150)
        #expect(summary.totalTokens == 150)
        #expect(summary.modelUsages.first?.model == "deepseek-chat")
    }

    @Test func usageSummaryTracksMiMoTokenConsumptionWhenCostIsZero() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: directory.appendingPathComponent("test.sqlite"))

        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2026, month: 6, day: 9))!
        let earlierThisMonth = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let previousMonth = calendar.date(from: DateComponents(year: 2026, month: 5, day: 31))!

        let records = [
            UsageRecord(
                provider: .mimo,
                model: "mimo-v2.5",
                date: today,
                promptTokens: 100,
                completionTokens: 25,
                totalTokens: 125,
                cost: 0,
                currency: "CNY",
                sourceFile: "mimo-dashboard",
                rowHash: "today"
            ),
            UsageRecord(
                provider: .mimo,
                model: "mimo-v2.5",
                date: earlierThisMonth,
                promptTokens: 200,
                completionTokens: 50,
                totalTokens: 250,
                cost: 0,
                currency: "CNY",
                sourceFile: "mimo-dashboard",
                rowHash: "month"
            ),
            UsageRecord(
                provider: .mimo,
                model: "mimo-v2.5",
                date: previousMonth,
                promptTokens: 300,
                completionTokens: 75,
                totalTokens: 375,
                cost: 0,
                currency: "CNY",
                sourceFile: "mimo-dashboard",
                rowHash: "previous-month"
            )
        ]

        #expect(try store.insertUsageRecords(records) == 3)
        let summary = try store.usageSummary(provider: .mimo, asOf: today, calendar: calendar)
        #expect(summary.todayCost == 0)
        #expect(summary.monthCost == 0)
        #expect(summary.todayTokens == 125)
        #expect(summary.monthTokens == 375)
        #expect(summary.totalTokens == 750)
    }

    @Test func purgeImportedDataKeepsDashboardRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: directory.appendingPathComponent("test.sqlite"))

        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 6, day: 8))!
        let imported = UsageRecord(
            provider: .deepseek,
            model: "imported-model",
            date: date,
            promptTokens: 1,
            completionTokens: 1,
            totalTokens: 2,
            cost: 0.01,
            currency: "CNY",
            sourceFile: "old-bill.csv",
            rowHash: "imported"
        )
        let dashboard = UsageRecord(
            provider: .deepseek,
            model: "dashboard-model",
            date: date,
            promptTokens: 2,
            completionTokens: 2,
            totalTokens: 4,
            cost: 0.02,
            currency: "CNY",
            sourceFile: "deepseek-dashboard-2026-6",
            rowHash: "dashboard"
        )

        _ = try store.insertUsageRecords([imported, dashboard])
        try store.upsertBalances([
            BalanceSnapshot(provider: .deepseek, currency: "CNY", totalBalance: 1, source: .api, capturedAt: date)
        ])

        try store.purgeImportedData()

        let records = try store.usageRecords(provider: .deepseek)
        #expect(records.map(\.model) == ["dashboard-model"])
        #expect(try store.latestBalances(provider: .deepseek).count == 1)
    }
}
