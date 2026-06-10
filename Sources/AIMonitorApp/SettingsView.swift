import AIMonitorCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: MonitorViewModel
    var onSave: () -> Void = {}

    @State private var deepSeekKey = ""
    @State private var deepSeekDashboardToken = ""
    @State private var mimoCookie = ""
    @State private var mimoBalanceURL = ""
    @State private var mimoUsageURL = ""
    @State private var mimoBillingMode: BillingMode = .tokenPlan
    @State private var preferredCurrency = "CNY"
    @State private var refreshIntervalMinutes: Int = 30

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSection("API Keys") {
                        SecureField(model.apiKeyExists(provider: .deepseek) ? "DeepSeek API Key 已保存" : "DeepSeek API Key", text: $deepSeekKey)
                            .textFieldStyle(.roundedBorder)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.deepSeekDashboardTokenAvailable ? "DeepSeek Dashboard Token 已保存，留空表示保留原值" : "DeepSeek Dashboard Token 或 userToken JSON")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    HelpWindowPresenter.shared.showDeepSeekTokenHelp()
                                } label: {
                                    Label("获取方法", systemImage: "questionmark.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                            TextEditor(text: $deepSeekDashboardToken)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 76)
                                .scrollContentBackground(.hidden)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(.separator.opacity(0.65))
                                }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.apiKeyExists(provider: .mimo) ? "MiMo Cookie 已保存，留空表示保留原值" : "MiMo Dashboard Cookie 或 cookies JSON")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $mimoCookie)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 118)
                                .scrollContentBackground(.hidden)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(.separator.opacity(0.65))
                                }
                        }

                        Text("已保存的 Key/Token/Cookie 不会明文显示；DeepSeek 可粘贴 localStorage 的 userToken JSON，MiMo 可粘贴浏览器导出的 cookies JSON。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection("MiMo") {
                        TextField("余额 URL", text: $mimoBalanceURL)
                            .textFieldStyle(.roundedBorder)
                        TextField("明细 URL", text: $mimoUsageURL)
                            .textFieldStyle(.roundedBorder)
                        Text("示例：/console/balance 和 /console/usage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("计费方式", selection: $mimoBillingMode) {
                            ForEach(BillingMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    settingsSection("展示") {
                        Picker("默认货币", selection: $preferredCurrency) {
                            Text("CNY").tag("CNY")
                            Text("USD").tag("USD")
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("自动刷新间隔")
                                Spacer()
                                TextField("", value: $refreshIntervalMinutes, format: .number)
                                    .frame(width: 80)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                Text("分钟")
                                    .foregroundStyle(.secondary)
                            }
                            Text("最小 1 分钟；默认 30 分钟。过小的频率可能增加被限流的风险。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .task {
            let account = model.account(for: .mimo)
            mimoBillingMode = account.billingMode
            preferredCurrency = account.currency
            let urls = model.mimoDashboardURLs()
            mimoBalanceURL = urls.balanceURL
            mimoUsageURL = urls.usageURL
            refreshIntervalMinutes = model.refreshIntervalMinutes
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let message = model.lastImportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("取消") {
                onSave()
            }
            Button {
                let enteredDeepSeekKey = !deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let enteredDeepSeekDashboardToken = !deepSeekDashboardToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hadDeepSeekKey = model.apiKeyExists(provider: .deepseek)
                let hadDeepSeekDashboardToken = model.deepSeekDashboardTokenAvailable
                let saved = model.saveSettings(
                    deepSeekKey: deepSeekKey,
                    deepSeekDashboardToken: deepSeekDashboardToken,
                    mimoCookie: mimoCookie,
                    mimoBalanceURL: mimoBalanceURL,
                    mimoUsageURL: mimoUsageURL,
                    mimoBillingMode: mimoBillingMode,
                    preferredCurrency: preferredCurrency,
                    refreshIntervalMinutes: refreshIntervalMinutes
                )
                guard saved else { return }
                deepSeekKey = ""
                deepSeekDashboardToken = ""
                mimoCookie = ""
                onSave()
                if enteredDeepSeekKey || hadDeepSeekKey || enteredDeepSeekDashboardToken || hadDeepSeekDashboardToken {
                    Task { await model.refresh(provider: .deepseek) }
                }
            } label: {
                Label("保存", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}
