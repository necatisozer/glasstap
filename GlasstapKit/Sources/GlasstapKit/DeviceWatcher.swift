import AVFoundation
import CoreMediaIO
import Foundation

/// An iPhone screen that macOS offers as a capture device.
public struct ScreenDevice: Sendable, Hashable, Identifiable {
    /// The capture `uniqueID`. It is not the UDID of the iPhone.
    public let id: String
    public let name: String
}

/// Finds the iPhone screens on USB and follows them as they come and go.
@MainActor
public final class DeviceWatcher {
    /// The screen device can take several seconds to appear after the opt-in.
    public static let searchDuration: Duration = .seconds(20)

    public private(set) var devices: [ScreenDevice] = []
    /// True during the first seconds, while a missing device may still appear.
    public private(set) var isSearching = true
    public var onChange: (() -> Void)?
    private var task: Task<Void, Never>?

    public init() {}

    public func start() {
        guard task == nil else { return }
        Self.allowScreenCaptureDevices()
        task = Task { [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                guard let self else { return }
                let searching = ContinuousClock.now - start < Self.searchDuration
                scan(searching: searching)
                try? await Task.sleep(for: .seconds(searching ? 1 : 2))
            }
        }
    }

    /// The iPhone screens that macOS offers now. Call it after `start()`, which opts in.
    nonisolated static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
            .devices.filter { $0.modelID == "iOS Device" }
    }

    private func scan(searching: Bool) {
        let found = Self.discover().map { ScreenDevice(id: $0.uniqueID, name: $0.localizedName) }
        let stillSearching = searching && found.isEmpty
        guard found != devices || stillSearching != isSearching else { return }
        devices = found
        isSearching = stillSearching
        onChange?()
    }

    /// iOS screen devices stay hidden until the process opts in.
    private static func allowScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }
}
