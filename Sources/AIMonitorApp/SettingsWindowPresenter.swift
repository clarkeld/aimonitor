import SwiftUI

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private var window: NSWindow?

    private init() {}

    func show(model: MonitorViewModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = SettingsView(onSave: { [weak self] in
            self?.close()
        })
            .environmentObject(model)
            .frame(width: 640, height: 590)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 590),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Monitor 设置"
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.close()
    }
}
