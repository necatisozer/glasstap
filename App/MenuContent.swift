import GlasstapKit
import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(deviceLine)
        ForEach(model.setupProblems, id: \.self) { problem in
            if case let .iPhone(deviceProblem) = problem { Text(deviceProblem.message) }
        }
        Text(captureLine)
        if let adaptingLine { Text(adaptingLine) }
        Text(model.viewerConnected ? "Viewer connected" : "No viewer connected")
        Text(wdaLine)
        if model.showWakeHint {
            Text("Wake the iPhone: its display seems to be off")
        }
        if case let .failed(message) = model.controlState {
            Text("Viewer port \(String(model.settings.controlPort)) unavailable: \(message)")
        }
        if case let .failed(message) = model.videoState {
            Text("Video port \(String(model.settings.videoPort)) unavailable: \(message)")
        }

        Divider()

        if case .failed = model.captureStatus {
            Button("Restart Capture") { model.restartCapture() }
                .keyboardShortcut("r")
        }
        if model.wdaStatus.state != .notConfigured {
            Button("Restart WDA") { model.restartWDA() }
        }
        Button("Open Viewer") { model.openViewer() }
            .keyboardShortcut("o")
        Button("Copy Viewer Link") { model.copyViewerLink() }
            .keyboardShortcut("c")
        if model.devices.count > 1 {
            Picker("iPhone", selection: Binding(
                get: { model.selectedDeviceID ?? "" },
                set: { model.selectDevice($0) }
            )) {
                ForEach(model.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
        }

        Divider()

        Button("Setup…") { model.openSetup() }
        Button("Settings…") {
            // A menu-bar app is not active, so its window would open behind the others.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit glasstap") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var deviceLine: String {
        if let device = model.selectedDevice { return device.name }
        return model.isSearching ? "Looking for an iPhone…" : "No iPhone found"
    }

    private var captureLine: String {
        switch model.captureStatus {
        case .idle: "Capture: not running"
        case .waitingForPermission: "Capture: allow camera access for glasstap"
        case .noPermission: "Capture: no camera access. Allow it in System Settings › Privacy & Security › Camera."
        case .starting: "Capture: starting…"
        case .running: "Capture: \(model.fps) fps"
        case let .failed(message): "Capture failed: \(message)"
        }
    }

    /// Shown only while adaptive bitrate holds the encoder below the settings.
    private var adaptingLine: String? {
        guard model.captureStatus == .running, let target = model.encoderTarget else { return nil }
        let set = model.settings.encoder
        guard target.bitrate != set.bitrate else { return nil }
        return "Bitrate: \(target.bitrate / 1000) kbit/s (adapting)"
    }

    private var wdaLine: String {
        "WDA: " + model.wdaStatus.state.summary(teamSet: !model.settings.teamID.isEmpty)
    }
}

extension WDAState {
    /// One line for the menu and the Setup window.
    func summary(teamSet: Bool) -> String {
        switch self {
        case .notConfigured: teamSet ? "waiting for the iPhone" : "enter your team id in Setup"
        case .downloading: "downloading WebDriverAgent…"
        case .building: "building (the first build takes a few minutes)…"
        case .starting: "starting…"
        case .running: "running"
        case let .restarting(delay): "restarting in \(delay.components.seconds) s"
        case let .failed(reason): "failed. \(reason)"
        }
    }
}

/// The menu bar icon: no iPhone, an iPhone, or an iPhone that a viewer watches.
struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        if model.selectedDevice == nil { return "iphone.slash" }
        return model.captureStatus == .running && model.viewerConnected ? "iphone.radiowaves.left.and.right" : "iphone"
    }
}
