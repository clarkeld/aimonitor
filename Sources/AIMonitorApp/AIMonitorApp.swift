import AIMonitorCore
import SwiftUI

@main
struct AIMonitorApp: App {
    @StateObject private var model: MonitorViewModel

    init() {
        let model = MonitorViewModel()
        _model = StateObject(wrappedValue: model)
        Task { @MainActor in
            await model.load()
            await model.startAutoRefresh()
        }
    }

    var body: some Scene {
        MenuBarExtra("AI Monitor", systemImage: "chart.bar.xaxis") {
            MonitorPanelView()
                .environmentObject(model)
                .frame(width: 360, height: 660)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 580, height: 470)
        }
    }
}
