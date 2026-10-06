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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // The token in the link stops working at quit, so the file goes too.
        ViewerLink().remove()
    }
}
