import GlasstapKit
import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.sessions.isEmpty {
            Text(model.isSearching ? "Looking for an iPhone…" : "No iPhone found")
        }
        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
            // Only the first iPhone gets the shortcuts: a menu cannot give one shortcut to two items.
            DeviceSection(model: model, session: session, isFirst: index == 0)
        }
        if let notice = model.listenNotice {
            Text(notice)
        } else if model.boundAddress != ListenAddress.loopback {
            Text("Listening on \(model.boundAddress)")
        }
        if let message = model.controlState.problem {
            Text("Viewer port \(String(model.settings.controlPort)) unavailable: \(message)")
        }
        if let message = model.videoState.problem {
            Text("Video port \(String(model.settings.videoPort)) unavailable: \(message)")
        }

        Divider()

        if model.sessions.isEmpty {
            Button("Open Viewer") { model.openViewer() }
                .keyboardShortcut("o")
        }
        Button("Copy Viewer Link") { model.copyViewerLink() }
            .keyboardShortcut("c")

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
}

/// The lines and actions of one iPhone.
struct DeviceSection: View {
    let model: AppModel
    let session: DeviceSession
    let isFirst: Bool

    var body: some View {
        Section(session.screen.name) {
            ForEach(model.setupProblems, id: \.self) { problem in
                if case let .iPhone(device, deviceProblem) = problem, device == session.id { Text(deviceProblem.message) }
            }
            Text(captureLine)
            if let adaptingLine { Text(adaptingLine) }
            Text(session.viewerConnected ? "Viewer connected" : "No viewer connected")
            Text(wdaLine)
            if session.showWakeHint {
                Text("Wake the iPhone: its display seems to be off")
            }
            if case .failed = session.captureStatus {
                Button("Restart Capture") { session.restartCapture() }
                    .keyboardShortcut(isFirst ? KeyboardShortcut("r") : nil)
            }
            Button("Open Viewer") { model.openViewer(session) }
                .keyboardShortcut(isFirst ? KeyboardShortcut("o") : nil)
            if session.wdaStatus.state != .notConfigured {
                Button("Restart WDA") { session.restartWDA() }
            }
        }
    }

    private var captureLine: String {
        switch session.captureStatus {
        case .idle: "Capture: not running"
        case .waitingForPermission: "Capture: allow camera access for glasstap"
        case .noPermission: "Capture: no camera access. Allow it in System Settings › Privacy & Security › Camera."
        case .starting: "Capture: starting…"
        case .running: "Capture: \(session.fps) fps"
        case let .failed(message): "Capture failed: \(message)"
        }
    }

    /// Shown only while adaptive bitrate holds the encoder below the settings.
    private var adaptingLine: String? {
        guard session.captureStatus == .running, let target = session.encoderTarget else { return nil }
        guard target.bitrate != model.settings.encoder.bitrate else { return nil }
        return "Bitrate: \(target.bitrate / 1000) kbit/s (adapting)"
    }

    private var wdaLine: String {
        if session.overrideIsIdle { return "WDA: the URL override works with one iPhone only" }
        return "WDA: " + session.wdaStatus.state.summary(teamSet: !model.settings.teamID.isEmpty)
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
        case .waitingForUnlock: WDAState.unlockHint
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
        if model.sessions.isEmpty { return "iphone.slash" }
        let watched = model.sessions.contains { $0.captureStatus == .running && $0.viewerConnected }
        return watched ? "iphone.radiowaves.left.and.right" : "iphone"
    }
}

extension ListenerState {
    /// Why the listener does not serve, for the menu.
    var problem: String? {
        switch self {
        case let .failed(message), let .waiting(message): message
        case .ready, .stopped: nil
        }
    }
}
