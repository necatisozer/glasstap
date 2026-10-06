import GlasstapKit
import SwiftUI

/// Edits a draft. Apply saves it, so that typing a number does not restart the encoder at each key.
struct SettingsView: View {
    let model: AppModel
    @State private var draft = SettingsInput(.defaults)

    private var validated: Result<GlasstapSettings, SettingsProblem> { draft.validate() }
    private var usable: GlasstapSettings? { try? validated.get() }

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
                TextField("Viewer port", value: $draft.controlPort, format: .number.grouping(.never))
                TextField("Video port", value: $draft.videoPort, format: .number.grouping(.never))
                TextField("WDA URL", text: $draft.wdaURL)
            } header: {
                Text("Network")
            } footer: {
                Text("Both ports listen on 127.0.0.1 only. A change of port closes the open viewer.")
                    .foregroundStyle(.secondary)
            }
            if case let .failure(problem) = validated {
                Text(problem.message).foregroundStyle(.red)
            }
            HStack {
                Button("Restore Defaults") { draft = SettingsInput(.defaults) }
                Spacer()
                Button("Apply") {
                    if let usable { model.apply(usable) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(usable == nil || usable == model.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { draft = SettingsInput(model.settings) }
    }
}
