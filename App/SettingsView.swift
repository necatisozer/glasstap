import GlasstapKit
import SwiftUI

/// Edits a draft. Apply saves it, so that typing a number does not restart the encoder at each key.
struct SettingsView: View {
    let model: AppModel
    @State private var draft = SettingsInput(.defaults)
    /// Settings that wait for the user to confirm another listen address than 127.0.0.1.
    @State private var pendingExposure: GlasstapSettings?

    private var validated: Result<GlasstapSettings, SettingsProblem> { draft.validate() }
    private var usable: GlasstapSettings? { try? validated.get() }

    private var defaultPrefix: String {
        let team = draft.teamID.trimmingCharacters(in: .whitespaces)
        return team.isEmpty ? "glasstap.wda.<team id>" : WDASigning.defaultBundlePrefix(teamID: team)
    }

    var body: some View {
        Form {
            Section("Video") {
                Picker("Codec", selection: $draft.codec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Width (px)", value: $draft.width, format: .number.grouping(.never))
                TextField("Bitrate (kbit/s)", value: $draft.bitrateKbps, format: .number.grouping(.never))
                TextField("Frame rate (fps)", value: $draft.fps, format: .number.grouping(.never))
            }
            Section {
                Picker("Listen on", selection: $draft.listenAddress) {
                    Text("This Mac only (127.0.0.1)").tag(ListenAddress.loopback)
                    ForEach(model.listenAddresses) { Text(label($0)).tag($0.address) }
                    // The saved address, while its interface is down, so that the picker still shows it.
                    if let missing = missingAddress {
                        Text("\(missing) (not available now)").tag(missing)
                    }
                }
                TextField("Viewer port", value: $draft.controlPort, format: .number.grouping(.never))
                TextField("Video port", value: $draft.videoPort, format: .number.grouping(.never))
            } header: {
                Text("Network")
            } footer: {
                Text(networkFooter).foregroundStyle(.secondary)
            }
            Section {
                TextField("Team id", text: $draft.teamID, prompt: Text("ABCDE12345"))
                TextField("Bundle id prefix", text: $draft.wdaBundlePrefix, prompt: Text(defaultPrefix))
                TextField("WDA URL override", text: $draft.wdaURL, prompt: Text("Automatic"))
            } header: {
                Text("WebDriverAgent")
            } footer: {
                Text("glasstap builds WDA with your team and installs it as <prefix>.xctrunner. "
                    + "Leave the URL empty, so that glasstap starts WDA itself. A URL is for a WDA that you run.")
                    .foregroundStyle(.secondary)
            }
            if case let .failure(problem) = validated {
                Text(problem.message).foregroundStyle(.red)
            }
            HStack {
                Button("Restore Defaults") { draft = SettingsInput(.defaults) }
                Spacer()
                Button("Apply") {
                    guard let usable else { return }
                    // Another address exposes the iPhone to a network, so the user confirms it first.
                    if usable.listenAddress != ListenAddress.loopback, usable.listenAddress != model.settings.listenAddress {
                        pendingExposure = usable
                    } else {
                        model.apply(usable)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(usable == nil || usable == model.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { draft = SettingsInput(model.settings) }
        .confirmationDialog(
            "Listen on \(pendingExposure?.listenAddress ?? "")?",
            isPresented: Binding(get: { pendingExposure != nil }, set: { if !$0 { pendingExposure = nil } })
        ) {
            Button("Listen on \(pendingExposure?.listenAddress ?? "")") {
                if let pendingExposure { model.apply(pendingExposure) }
                pendingExposure = nil
            }
            Button("Cancel", role: .cancel) { pendingExposure = nil }
        } message: {
            Text("The traffic between this Mac and the browser is not encrypted, unless it goes through Tailscale. "
                + "Anyone on that network who gets the viewer link can see and control the iPhone.")
        }
    }

    private func label(_ address: ListenAddress) -> String {
        address.kind == .tailscale
            ? "\(address.address) (Tailscale, \(address.interface))"
            : "\(address.address) (\(address.interface))"
    }

    private var missingAddress: String? {
        let offered = Set(model.listenAddresses.map(\.address)).union([ListenAddress.loopback])
        return [draft.listenAddress, model.settings.listenAddress].first { !offered.contains($0) }
    }

    private var networkFooter: String {
        let address = draft.listenAddress == ListenAddress.loopback ? "127.0.0.1 only" : draft.listenAddress
        return "Both ports listen on \(address). Tailscale is the safer choice for another address. "
            + "A change of address or port closes the open viewer."
    }
}
