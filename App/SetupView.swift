import AppKit
import AVFoundation
import GlasstapKit
import SwiftUI

/// The checklist of what glasstap needs. Each row has a state and one way to fix it.
struct SetupView: View {
    let model: AppModel
    @State private var teamDraft = ""
    @State private var teamProblem: String?

    var body: some View {
        let problems = model.setupProblems
        Form {
            Section {
                xcodeRow(problems)
                teamRow(problems)
                if model.sessions.isEmpty {
                    noIPhoneRow()
                } else {
                    ForEach(model.sessions) { iPhoneRow($0, problems) }
                }
                cameraRow(problems)
                if model.sessions.isEmpty {
                    CheckRow(title: "WebDriverAgent", state: .waiting,
                             line: WDAState.notConfigured.summary(teamSet: !model.settings.teamID.isEmpty).capitalizedFirst) {}
                } else {
                    ForEach(model.sessions) { wdaRow($0, problems) }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Check Again") { model.checkAgain() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 640)
        .onAppear { teamDraft = model.settings.teamID }
    }

    // MARK: - Rows

    private func xcodeRow(_ problems: [SetupProblem]) -> some View {
        let status = model.xcodeStatus
        let state: CheckState = problems.contains(.xcode) ? .problem : status == nil ? .checking : .ok
        return CheckRow(title: "Xcode", state: state, line: xcodeLine(status)) {
            if let status, !status.isReady {
                Text("Xcode is required (devicectl and xcodebuild). The Command Line Tools alone are not enough. "
                    + "Install Xcode, open it once, then run: sudo xcode-select -s /Applications/Xcode.app")
                    .hint()
                Button("Get Xcode") { open("macappstore://apps.apple.com/app/xcode/id497799835") }
            }
        }
    }

    private func xcodeLine(_ status: XcodeStatus?) -> String {
        switch status {
        case nil: "Checking…"
        case let .ready(dir)?: "Found at \(dir)"
        case let .commandLineToolsOnly(dir)?: "Only the Command Line Tools are selected (\(dir))."
        case let .noDevicectl(dir)?: "devicectl is missing from \(dir). Update Xcode."
        case .notFound?: "Not found."
        }
    }

    private func teamRow(_ problems: [SetupProblem]) -> some View {
        let team = model.settings.teamID
        let state: CheckState = problems.contains(.teamID) ? .problem : team.isEmpty ? .waiting : .ok
        return CheckRow(title: "Team id", state: state,
                        line: team.isEmpty ? "Not set. glasstap signs WebDriverAgent with your team." : team) {
            HStack {
                TextField("Team id", text: $teamDraft, prompt: Text("ABCDE12345"))
                    .labelsHidden()
                    .onSubmit(saveTeam)
                Button("Save", action: saveTeam)
                    .disabled(teamDraft.trimmingCharacters(in: .whitespaces).uppercased() == team)
            }
            if let teamProblem {
                Text(teamProblem).hint()
            }
            Text("Xcode > Settings > Accounts shows your team. The id is also the OU of your certificate: "
                + #"security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject"#)
                .hint()
                .textSelection(.enabled)
        }
    }

    private func saveTeam() {
        teamProblem = model.saveTeamID(teamDraft)?.message
        if teamProblem == nil { teamDraft = model.settings.teamID }
    }

    private func noIPhoneRow() -> some View {
        let searching = model.isSearching
        return CheckRow(title: "iPhone", state: searching ? .checking : .waiting,
                        line: searching ? "Looking for an iPhone on USB…" : "No iPhone found.") {
            if !searching {
                Text("Plug in the iPhone with a USB cable, unlock it, and tap Trust when it asks.").hint()
            }
        }
    }

    /// One row for each iPhone, so that each one shows its own problem.
    private func iPhoneRow(_ session: DeviceSession, _ problems: [SetupProblem]) -> some View {
        let name = session.screen.name
        let state: CheckState
        let line: String
        var hint: String?
        switch session.deviceIdentity {
        case nil:
            (state, line) = (.checking, "\(name): looking it up with devicectl…")
        case let .success(core)?:
            (state, line) = (.ok, "\(core.name), iOS \(core.osVersion ?? "?"), Developer Mode on")
        case let .failure(problem)?:
            // A young failure may still clear by itself, as the tunnel comes up.
            let lasting = problems.contains(.iPhone(device: session.id, problem))
            (state, line) = (lasting ? .problem : .checking, "\(name): \(problem.message)")
            hint = problem.hint
        }
        return CheckRow(title: "iPhone", state: state, line: line) {
            if let hint { Text(hint).hint() }
        }
    }

    private func cameraRow(_ problems: [SetupProblem]) -> some View {
        let state: CheckState
        let line: String
        if problems.contains(.camera) {
            (state, line) = (.problem, "Not allowed")
        } else if model.cameraStatus == .authorized {
            (state, line) = (.ok, "Allowed")
        } else {
            (state, line) = (.waiting, "macOS asks at the first capture, because it treats the iPhone screen as a camera.")
        }
        return CheckRow(title: "Camera access", state: state, line: line) {
            if state == .problem {
                Button("Open Camera Settings") {
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
                }
            }
        }
    }

    private func wdaRow(_ session: DeviceSession, _ problems: [SetupProblem]) -> some View {
        let status = session.wdaStatus
        let state: CheckState = switch status.state {
        case .failed: .problem
        case .running: .ok
        case .notConfigured, .waitingForUnlock: .waiting
        default: .checking
        }
        let summary = status.state.summary(teamSet: !model.settings.teamID.isEmpty).capitalizedFirst
        // With more than one iPhone, each row names its iPhone.
        let line = model.sessions.count > 1 ? "\(session.screen.name): \(summary)" : summary
        return CheckRow(title: "WebDriverAgent", state: state, line: line) {
            if let error = status.lastError, status.state != .running, !line.contains(error) {
                Text(error).hint()
            }
            if !status.lastLines.isEmpty, status.state != .running {
                ScrollView {
                    Text(status.lastLines.suffix(40).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
            if status.state != .notConfigured {
                Button("Restart WDA") { session.restartWDA() }
            }
        }
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

enum CheckState {
    case ok, problem, waiting, checking
}

/// A row: a status icon, a title with one line of state, and what to do about it.
struct CheckRow<Detail: View>: View {
    let title: String
    let state: CheckState
    let line: String
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(line).foregroundStyle(.secondary)
                detail
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
        case .problem: Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        }
    }
}

private extension Text {
    func hint() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The Setup window. It is an AppKit window, because the app must open it by itself at launch,
/// and a SwiftUI `Window` scene opens only from a view's `openWindow`.
@MainActor
final class SetupWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
            window.title = "glasstap Setup"
            window.styleMask = [.titled, .closable, .resizable]
            // A grouped form scrolls, so it may report no height of its own.
            window.setContentSize(NSSize(width: 560, height: 640))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // A menu-bar app is not active, so its window would open behind the others.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
