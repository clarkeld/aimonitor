import SwiftUI

struct DeepSeekTokenHelpView: View {
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    helpSection("它是做什么的") {
                        Text("DeepSeek API Key 只能稳定获取官方 API 余额；Dashboard userToken 用来读取控制台里的本月用量、模型 token 消耗和趋势。")
                        Text("如果你只关心余额，可以只填 API Key；如果想看到模型用量，需要填写 userToken。")
                    }

                    helpSection("Chrome / Edge 获取方法") {
                        step("打开 https://platform.deepseek.com 并登录。")
                        step("按 Option + Command + I 打开开发者工具。")
                        step("进入 Application 标签页，在左侧 Storage 里展开 Local Storage。")
                        step("选择 https://platform.deepseek.com，找到名为 userToken 的项目。")
                        step("复制它的 Value，可以复制完整 JSON，也可以只复制 value 里的 token 字符串。")
                        step("回到 AIMonitor 设置，粘贴到 DeepSeek Dashboard Token 输入框并保存。")
                    }

                    helpSection("Safari 获取方法") {
                        step("先在 Safari 设置的 Advanced 里打开 Show features for web developers。")
                        step("登录 https://platform.deepseek.com。")
                        step("菜单栏选择 Develop > Show Web Inspector。")
                        step("进入 Storage 标签页，选择 Local Storage 下的 platform.deepseek.com。")
                        step("找到 userToken，复制 Value 后粘贴到 AIMonitor 设置里。")
                    }

                    helpSection("可直接粘贴的格式") {
                        Text("AIMonitor 支持两种格式：")
                        codeBlock(#"{"value":"这里是你的 token","__version":"0"}"#)
                        codeBlock("这里只粘贴 token 字符串也可以")
                    }

                    helpSection("安全提醒") {
                        Text("userToken 等同于网页登录状态的一部分，不要发给别人，也不要放到截图里。")
                        Text("如果 DeepSeek 控制台退出登录、清浏览器数据、或登录状态过期，旧 userToken 可能失效，需要按上面步骤重新复制。")
                    }
                }
                .font(.body)
                .padding(22)
            }

            Divider()
            HStack {
                Spacer()
                Button("关闭") {
                    HelpWindowPresenter.shared.close()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DeepSeek userToken 获取方法")
                .font(.title2.bold())
            Text("下次忘了就照这页走。复制出来后直接粘到设置里的 DeepSeek Dashboard Token。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func helpSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            content()
                .foregroundStyle(.primary)
        }
    }

    private func step(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.blue)
                .padding(.top, 1)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator.opacity(0.65))
            }
    }
}
