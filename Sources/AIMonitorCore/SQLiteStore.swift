import Foundation
import SQLite3

public final class SQLiteStore: @unchecked Sendable {
    private let db: OpaquePointer?
    private let isoFormatter = ISO8601DateFormatter()

    public init(path: URL) throws {
        var handle: OpaquePointer?
        if sqlite3_open(path.path, &handle) != SQLITE_OK {
            throw AIMonitorError.databaseFailed(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("AIMonitor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("monitor.sqlite")
    }

    public func saveAccount(_ account: ProviderAccount) throws {
        let sql = """
        INSERT INTO provider_accounts(provider, display_name, api_key_ref, billing_mode, currency, last_refresh_at)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(provider) DO UPDATE SET
          display_name=excluded.display_name,
          api_key_ref=excluded.api_key_ref,
          billing_mode=excluded.billing_mode,
          currency=excluded.currency,
          last_refresh_at=excluded.last_refresh_at
        """
        try withStatement(sql) { statement in
            bindText(statement, 1, account.provider.rawValue)
            bindText(statement, 2, account.displayName)
            bindText(statement, 3, account.apiKeyRef)
            bindText(statement, 4, account.billingMode.rawValue)
            bindText(statement, 5, account.currency)
            bindDate(statement, 6, account.lastRefreshAt)
            try stepDone(statement)
        }
    }

    public func accounts() throws -> [ProviderAccount] {
        try query("SELECT provider, display_name, api_key_ref, billing_mode, currency, last_refresh_at FROM provider_accounts") { statement in
            ProviderAccount(
                provider: Provider(rawValue: columnText(statement, 0)) ?? .deepseek,
                displayName: columnText(statement, 1),
                apiKeyRef: columnText(statement, 2),
                billingMode: BillingMode(rawValue: columnText(statement, 3)) ?? .payAsYouGo,
                currency: columnText(statement, 4),
                lastRefreshAt: columnDate(statement, 5)
            )
        }
    }

    public func upsertBalances(_ snapshots: [BalanceSnapshot]) throws {
        for snapshot in snapshots {
            let sql = """
            INSERT OR REPLACE INTO balance_snapshots(
              id, provider, currency, total_balance, granted_balance, topped_up_balance,
              credit_total, credit_used, credit_remaining, monthly_cost, is_available, source, captured_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            try withStatement(sql) { statement in
                bindText(statement, 1, snapshot.id)
                bindText(statement, 2, snapshot.provider.rawValue)
                bindText(statement, 3, snapshot.currency)
                bindDouble(statement, 4, snapshot.totalBalance)
                bindDouble(statement, 5, snapshot.grantedBalance)
                bindDouble(statement, 6, snapshot.toppedUpBalance)
                bindDouble(statement, 7, snapshot.creditTotal)
                bindDouble(statement, 8, snapshot.creditUsed)
                bindDouble(statement, 9, snapshot.creditRemaining)
                bindDouble(statement, 10, snapshot.monthlyCost)
                sqlite3_bind_int(statement, 11, snapshot.isAvailable ? 1 : 0)
                bindText(statement, 12, snapshot.source.rawValue)
                bindDate(statement, 13, snapshot.capturedAt)
                try stepDone(statement)
            }
        }
    }

    public func latestBalances(provider: Provider) throws -> [BalanceSnapshot] {
        let sql = """
        SELECT id, provider, currency, total_balance, granted_balance, topped_up_balance,
               credit_total, credit_used, credit_remaining, monthly_cost, is_available, source, captured_at
        FROM balance_snapshots
        WHERE provider = ?
          AND captured_at IN (
            SELECT MAX(captured_at) FROM balance_snapshots WHERE provider = ? GROUP BY currency
          )
        ORDER BY currency
        """
        return try query(sql, bind: { statement in
            bindText(statement, 1, provider.rawValue)
            bindText(statement, 2, provider.rawValue)
        }, map: mapBalance)
    }

    public func insertUsageRecords(_ records: [UsageRecord]) throws -> Int {
        var inserted = 0
        for record in records {
            let sql = """
            INSERT OR IGNORE INTO usage_records(
              id, provider, model, date, prompt_tokens, completion_tokens, cache_hit_tokens,
              total_tokens, cost, currency, source_file, row_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            try withStatement(sql) { statement in
                bindText(statement, 1, record.id)
                bindText(statement, 2, record.provider.rawValue)
                bindText(statement, 3, record.model)
                bindDate(statement, 4, record.date)
                sqlite3_bind_int64(statement, 5, record.promptTokens)
                sqlite3_bind_int64(statement, 6, record.completionTokens)
                sqlite3_bind_int64(statement, 7, record.cacheHitTokens)
                sqlite3_bind_int64(statement, 8, record.totalTokens)
                sqlite3_bind_double(statement, 9, record.cost)
                bindText(statement, 10, record.currency)
                bindText(statement, 11, record.sourceFile)
                bindText(statement, 12, record.rowHash)
                try stepDone(statement)
                inserted += Int(sqlite3_changes(db))
            }
        }
        return inserted
    }

    public func deleteUsageRecords(provider: Provider) throws {
        let sql = "DELETE FROM usage_records WHERE provider = ?"
        try withStatement(sql) { statement in
            bindText(statement, 1, provider.rawValue)
            try stepDone(statement)
        }
    }

    public func usageRecords(provider: Provider) throws -> [UsageRecord] {
        let sql = """
        SELECT id, provider, model, date, prompt_tokens, completion_tokens, cache_hit_tokens,
               total_tokens, cost, currency, source_file, row_hash
        FROM usage_records WHERE provider = ? ORDER BY date ASC
        """
        return try query(sql, bind: { statement in
            bindText(statement, 1, provider.rawValue)
        }, map: mapUsage)
    }

    public func usageSummary(provider: Provider, asOf: Date = Date(), calendar: Calendar = .current) throws -> UsageSummary {
        let records = try usageRecords(provider: provider)
        guard !records.isEmpty else { return .empty }

        let todayStart = calendar.startOfDay(for: asOf)
        let month = calendar.dateComponents([.year, .month], from: asOf)
        let monthStart = calendar.date(from: month) ?? todayStart
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart

        var todayCost = 0.0
        var monthCost = 0.0
        var todayTokens: Int64 = 0
        var monthTokens: Int64 = 0
        var modelBuckets: [String: (tokens: Int64, cost: Double, currency: String)] = [:]
        var dayBuckets: [Date: (tokens: Int64, cost: Double)] = [:]
        var totalTokens: Int64 = 0
        let currency = records.last?.currency ?? "CNY"

        for record in records {
            let day = calendar.startOfDay(for: record.date)
            if day == todayStart {
                todayCost += record.cost
                todayTokens += record.totalTokens
            }
            if record.date >= monthStart {
                monthCost += record.cost
                monthTokens += record.totalTokens
            }
            if record.date >= sevenDaysAgo {
                var dayBucket = dayBuckets[day] ?? (0, 0)
                dayBucket.tokens += record.totalTokens
                dayBucket.cost += record.cost
                dayBuckets[day] = dayBucket
            }

            var modelBucket = modelBuckets[record.model] ?? (0, 0, record.currency)
            modelBucket.tokens += record.totalTokens
            modelBucket.cost += record.cost
            modelBucket.currency = record.currency
            modelBuckets[record.model] = modelBucket
            totalTokens += record.totalTokens
        }

        // 金额四舍五入到 2 位小数，避免 Double 浮点累加误差（0.01 + 0.01 != 0.02 的问题）
        todayCost = round(todayCost * 100) / 100
        monthCost = round(monthCost * 100) / 100

        let modelUsages = modelBuckets
            .map { ModelUsage(model: $0.key, totalTokens: $0.value.tokens, cost: round($0.value.cost * 100) / 100, currency: $0.value.currency) }
            .sorted { $0.totalTokens > $1.totalTokens }

        let dailyUsages = (0..<7).compactMap { offset -> DailyUsage? in
            guard let day = calendar.date(byAdding: .day, value: offset - 6, to: todayStart) else { return nil }
            let bucket = dayBuckets[day] ?? (0, 0)
            return DailyUsage(date: day, totalTokens: bucket.tokens, cost: round(bucket.cost * 100) / 100)
        }

        return UsageSummary(
            todayCost: todayCost,
            monthCost: monthCost,
            todayTokens: todayTokens,
            monthTokens: monthTokens,
            currency: currency,
            modelUsages: modelUsages,
            dailyUsages: dailyUsages,
            totalTokens: totalTokens
        )
    }

    public func purgeImportedData() throws {
        try execute("DELETE FROM balance_snapshots WHERE source != 'api'")
        try execute("""
        DELETE FROM usage_records
        WHERE source_file LIKE '%.csv'
           OR source_file LIKE '%.xlsx'
           OR source_file = 'inline.csv'
           OR source_file = 'embedded-html'
        """)
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS provider_accounts(
          provider TEXT PRIMARY KEY,
          display_name TEXT NOT NULL,
          api_key_ref TEXT NOT NULL,
          billing_mode TEXT NOT NULL,
          currency TEXT NOT NULL,
          last_refresh_at TEXT
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS balance_snapshots(
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL,
          currency TEXT NOT NULL,
          total_balance REAL,
          granted_balance REAL,
          topped_up_balance REAL,
          credit_total REAL,
          credit_used REAL,
          credit_remaining REAL,
          monthly_cost REAL,
          is_available INTEGER NOT NULL,
          source TEXT NOT NULL,
          captured_at TEXT NOT NULL
        )
        """)
        // 为已存在的旧数据库（建表时没有 monthly_cost 列）添加该列。
        // 老版本 SQLite 不支持 "ADD COLUMN IF NOT EXISTS"，因此先查询 pragma_table_info 判断。
        do {
            let columns: [[String: Any]] = try query("PRAGMA table_info(balance_snapshots)", bind: { _ in }, map: { statement in
                [
                    "name": columnText(statement, 1)
                ]
            })
            let columnNames = columns.compactMap { $0["name"] as? String }
            if !columnNames.contains("monthly_cost") {
                try execute("ALTER TABLE balance_snapshots ADD COLUMN monthly_cost REAL")
            }
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_balance_provider_time ON balance_snapshots(provider, captured_at)")
        try execute("""
        CREATE TABLE IF NOT EXISTS usage_records(
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL,
          model TEXT NOT NULL,
          date TEXT NOT NULL,
          prompt_tokens INTEGER NOT NULL,
          completion_tokens INTEGER NOT NULL,
          cache_hit_tokens INTEGER NOT NULL,
          total_tokens INTEGER NOT NULL,
          cost REAL NOT NULL,
          currency TEXT NOT NULL,
          source_file TEXT NOT NULL,
          row_hash TEXT NOT NULL,
          UNIQUE(source_file, row_hash)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_provider_date ON usage_records(provider, date)")
    }

    private func execute(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw AIMonitorError.databaseFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AIMonitorError.databaseFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func query<T>(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in },
        map: (OpaquePointer?) -> T
    ) throws -> [T] {
        var rows: [T] = []
        try withStatement(sql) { statement in
            bind(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(map(statement))
            }
        }
        return rows
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AIMonitorError.databaseFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func mapBalance(_ statement: OpaquePointer?) -> BalanceSnapshot {
        BalanceSnapshot(
            id: columnText(statement, 0),
            provider: Provider(rawValue: columnText(statement, 1)) ?? .deepseek,
            currency: columnText(statement, 2),
            totalBalance: columnOptionalDouble(statement, 3),
            grantedBalance: columnOptionalDouble(statement, 4),
            toppedUpBalance: columnOptionalDouble(statement, 5),
            creditTotal: columnOptionalDouble(statement, 6),
            creditUsed: columnOptionalDouble(statement, 7),
            creditRemaining: columnOptionalDouble(statement, 8),
            monthlyCost: columnOptionalDouble(statement, 9),
            isAvailable: sqlite3_column_int(statement, 10) == 1,
            source: DataSource(rawValue: columnText(statement, 11)) ?? .api,
            capturedAt: columnDate(statement, 12) ?? Date()
        )
    }

    private func mapUsage(_ statement: OpaquePointer?) -> UsageRecord {
        UsageRecord(
            id: columnText(statement, 0),
            provider: Provider(rawValue: columnText(statement, 1)) ?? .deepseek,
            model: columnText(statement, 2),
            date: columnDate(statement, 3) ?? Date(),
            promptTokens: sqlite3_column_int64(statement, 4),
            completionTokens: sqlite3_column_int64(statement, 5),
            cacheHitTokens: sqlite3_column_int64(statement, 6),
            totalTokens: sqlite3_column_int64(statement, 7),
            cost: sqlite3_column_double(statement, 8),
            currency: columnText(statement, 9),
            sourceFile: columnText(statement, 10),
            rowHash: columnText(statement, 11)
        )
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
    sqlite3_bind_text(statement, index, value, -1, transientDestructor)
}

private func bindDate(_ statement: OpaquePointer?, _ index: Int32, _ value: Date?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    bindText(statement, index, ISO8601DateFormatter().string(from: value))
}

private func bindDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_double(statement, index, value)
}

private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
}

private func columnOptionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
    if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
    return sqlite3_column_double(statement, index)
}

private func columnDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
    let value = columnText(statement, index)
    guard !value.isEmpty else { return nil }
    return ISO8601DateFormatter().date(from: value)
}
