import AIMonitorCore
import Charts
import SwiftUI

struct MonitorPanelView: View {
    @EnvironmentObject private var model: MonitorViewModel

    private var provider: Provider { model.selectedProvider }
    private var account: ProviderAccount { model.account(for: provider) }
    private var balance: BalanceSnapshot? { model.balances[provider]?.first }
    private var summary: UsageSummary { model.summaries[provider] ?? .empty }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.33, blue: 0.46),
                    Color(red: 0.12, green: 0.49, blue: 0.48),
                    Color(red: 0.87, green: 0.70, blue: 0.39)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 8) {
                    header
                    providerPicker
                    balanceCard
                    modelList
                    trendCard
                    footer
                }
                .padding(10)
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(provider == .deepseek ? AnyShapeStyle(.white) : AnyShapeStyle(.blue.gradient))
                if provider == .deepseek {
                    if let deepSeekMark = AppResources.image(named: "DeepSeekMark") {
                        Image(nsImage: deepSeekMark)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .bold))
                    }
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .bold))
                }
            }
            .frame(width: 44, height: 44)
            .shadow(color: .blue.opacity(0.45), radius: 10, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(provider.displayName) Monitor")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("v\(AppVersion.current)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            iconButton("刷新", systemImage: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise") {
                Task { await model.refreshSelectedProvider() }
            }
            iconButton("设置", systemImage: "gearshape") {
                SettingsWindowPresenter.shared.show(model: model)
            }
            iconButton("退出", systemImage: "xmark") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(height: 48)
    }

    private var providerPicker: some View {
        Picker("Provider", selection: $model.selectedProvider) {
            ForEach(Provider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("账户余额", systemImage: "creditcard")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            if provider == .mimo, account.billingMode == .tokenPlan,
               balance?.creditRemaining != nil || balance?.creditTotal != nil {
                tokenPlanBalance
            } else {
                Text(NumberFormatting.money(balance?.totalBalance, currency: balance?.currency ?? account.currency))
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            HStack(spacing: 12) {
                statTile(title: "当日消耗", value: consumptionText(tokens: summary.todayTokens, cost: summary.todayCost, authoritativeCost: balance?.monthlyCost), image: "sun.max")
                statTile(title: "本月消耗", value: consumptionText(tokens: summary.monthTokens, cost: summary.monthCost, authoritativeCost: balance?.monthlyCost, isMonthly: true), image: "calendar")
            }
        }
        .padding(12)
        .glassPanel()
    }

    private var tokenPlanBalance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(formatCredit(balance?.creditRemaining)) Credits")
                .font(.system(size: 36, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack {
                Text("已用 \(formatCredit(balance?.creditUsed))")
                Spacer()
                Text("总量 \(formatCredit(balance?.creditTotal))")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(balance?.isAvailable == false ? .orange : .mint)
                .frame(width: 8, height: 8)
            Text(balance == nil ? "待刷新" : "可用")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18)))
    }

    private var modelList: some View {
        VStack(spacing: 9) {
            if summary.modelUsages.isEmpty {
                emptyModelRow
            } else {
                ForEach(summary.modelUsages.prefix(2)) { usage in
                    ModelUsageRow(usage: usage, maxTokens: summary.modelUsages.first?.totalTokens ?? 1)
                }
            }
        }
    }

    private var emptyModelRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .bold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text("暂无模型用量")
                    .font(.headline.weight(.bold))
                Text(provider == .mimo ? "填写 MiMo Cookie 后刷新" : "填写 DeepSeek Dashboard Token 后刷新")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
        }
        .padding(13)
        .glassPanel()
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("消耗趋势", systemImage: "chart.bar")
                    .font(.headline)
                Spacer()
                Text("合计 \(NumberFormatting.tokens(summary.totalTokens))")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.78))
            }

            if summary.dailyUsages.allSatisfy({ $0.totalTokens == 0 }) {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 28))
                    Text("暂无最近 7 日用量")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
                .foregroundStyle(.white.opacity(0.68))
            } else {
                Chart(summary.dailyUsages) { day in
                    BarMark(
                        x: .value("Date", shortDate(day.date)),
                        y: .value("Tokens", day.totalTokens)
                    )
                    .foregroundStyle(.linearGradient(colors: [.blue, .cyan], startPoint: .bottom, endPoint: .top))
                    .cornerRadius(6)
                    .annotation(position: .top) {
                        Text(NumberFormatting.tokens(day.totalTokens))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel()
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .frame(height: 110)
            }
        }
        .padding(12)
        .glassPanel()
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer()

                if let date = account.lastRefreshAt {
                    Text("刷新于 \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                }
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let message = model.lastImportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.mint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func statTile(title: String, value: String, image: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: image)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow.opacity(0.92))
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.11)))
    }

    private func iconButton(_ tooltip: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func formatCredit(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f", value)
    }

    private func consumptionText(tokens: Int64, cost: Double, authoritativeCost: Double? = nil, isMonthly: Bool = false) -> String {
        // 如果有权威的月度消耗值（从 summary 中解析），本月消耗直接使用它
        if isMonthly, let authoritativeCost = authoritativeCost, authoritativeCost > 0 {
            return NumberFormatting.money(authoritativeCost, currency: summary.currency)
        }
        if provider == .mimo, cost == 0, tokens > 0 {
            return "\(NumberFormatting.tokens(tokens)) Tokens"
        }
        // 金额四舍五入到 2 位小数后再格式化，避免浮点误差
        let roundedCost = round(cost * 100) / 100
        return NumberFormatting.money(roundedCost, currency: summary.currency)
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}

private struct ModelUsageRow: View {
    var usage: ModelUsage
    var maxTokens: Int64

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconGradient)
                Image(systemName: usage.model.localizedCaseInsensitiveContains("flash") ? "bolt.fill" : "brain.head.profile")
                    .font(.system(size: 22, weight: .bold))
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(usage.model)
                        .font(.headline.weight(.bold))
                    Spacer()
                    Text(NumberFormatting.money(usage.cost, currency: usage.currency))
                        .font(.headline.weight(.bold))
                }
                HStack(spacing: 12) {
                    Text("\(usage.totalTokens.formatted()) Tokens")
                        .font(.caption)
                    ProgressView(value: Double(usage.totalTokens), total: max(Double(maxTokens), 1))
                        .tint(.cyan)
                    Text(NumberFormatting.tokens(usage.totalTokens))
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.76))
            }
        }
        .padding(12)
        .glassPanel()
    }

    private var iconGradient: LinearGradient {
        if usage.model.localizedCaseInsensitiveContains("pro") {
            LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private extension View {
    func glassPanel() -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}
