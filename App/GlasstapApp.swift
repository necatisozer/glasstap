import AppKit
import GlasstapKit
import SwiftUI

@main
struct GlasstapApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: AppModel

    init() {
        // A menu-style extra builds its content only when the menu opens, so start here.
        let model = AppModel()
        let setupWindow = SetupWindowController(model: model)
        model.showSetup = { setupWindow.show() }
        AppDelegate.beforeQuit = { await model.prepareToQuit() }
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Stops WDA. It can take up to 5 s, so the quit waits for it.
    static var beforeQuit: (@MainActor () async -> Void)?
    /// The longest that a quit waits for WDA to stop.
    static let quitDeadline: Duration = .seconds(10)
    private var quitPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The first request replies when WDA has stopped. A second one must not quit at once.
        if quitPending { return .terminateCancel }
        guard let beforeQuit = Self.beforeQuit else { return .terminateNow }
        quitPending = true
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await beforeQuit()
            reply()
        }
        // A stuck stop must not keep the app from quitting.
        Task {
            try? await Task.sleep(for: Self.quitDeadline)
            reply()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The token in the link stops working at quit, so the file goes too.
        ViewerLink().remove()
    }
}
