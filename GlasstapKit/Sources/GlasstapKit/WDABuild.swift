import Foundation

/// The user's Apple team, and the bundle id prefix of the WDA runner.
public struct WDASigning: Sendable, Equatable {
    public var teamID: String
    public var bundlePrefix: String

    public init(teamID: String, bundlePrefix: String) {
        self.teamID = teamID
        self.bundlePrefix = bundlePrefix
    }

    public static func defaultBundlePrefix(teamID: String) -> String {
        "glasstap.wda.\(teamID.lowercased())"
    }

    /// Xcode appends ".xctrunner" to the id of a UI test runner.
    public var runnerBundleID: String { bundlePrefix + ".xctrunner" }
}

/// One signed WDA build. A build serves every start until one of these values changes.
public struct WDABuild: Sendable, Equatable {
    public var wdaVersion: String
    public var signing: WDASigning
    public var iOSMajorVersion: Int

    public init(wdaVersion: String, signing: WDASigning, iOSMajorVersion: Int) {
        self.wdaVersion = wdaVersion
        self.signing = signing
        self.iOSMajorVersion = iOSMajorVersion
    }

    /// The name of the build folder. Settings validation keeps team and prefix to letters, digits, "." and "-".
    public var cacheKey: String {
        "\(wdaVersion)-\(signing.teamID)-\(signing.bundlePrefix)-ios\(iOSMajorVersion)"
    }

    /// The signing settings for `xcodebuild -xcconfig`. WDA derives the runner id from
    /// PRODUCT_BUNDLE_IDENTIFIER. Only the runner target gets the prefix. The other targets keep their own ids.
    public var xcconfig: String {
        """
        // Written by glasstap for the WebDriverAgent build.
        DEVELOPMENT_TEAM = \(signing.teamID)
        CODE_SIGN_STYLE = Automatic
        CODE_SIGN_IDENTITY = Apple Development
        WDA_BID_WebDriverAgentRunner = \(signing.bundlePrefix)
        PRODUCT_BUNDLE_IDENTIFIER = $(WDA_BID_$(TARGET_NAME):default=$(inherited))

        """
    }

    public func buildArguments(project: URL, udid: String, derivedData: URL, xcconfig: URL) -> [String] {
        ["build-for-testing",
         "-project", project.path,
         "-scheme", "WebDriverAgentRunner",
         "-destination", "id=\(udid)",
         "-derivedDataPath", derivedData.path,
         "-xcconfig", xcconfig.path,
         "-allowProvisioningUpdates"]
    }

    public static func testArguments(testRun: URL, udid: String) -> [String] {
        ["test-without-building", "-xctestrun", testRun.path, "-destination", "id=\(udid)"]
    }

    /// The `.xctestrun` file of a finished build, such as `WebDriverAgentRunner_iphoneos27.0-arm64.xctestrun`.
    public static func findTestRun(inDerivedData derivedData: URL) -> URL? {
        let products = derivedData.appendingPathComponent("Build/Products")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? []
        return names
            .filter { $0.hasPrefix("WebDriverAgentRunner_iphoneos") && $0.hasSuffix(".xctestrun") }
            .sorted()
            .last
            .map { products.appendingPathComponent($0) }
    }
}

/// The output of one xcodebuild run, line by line: its last lines, and the errors that decide what
/// happens next. A signing error can be far from the end of a long output, so each line is checked.
public struct XcodebuildScan: Sendable {
    public private(set) var tail: LineTail
    public private(set) var sawSigningError = false
    public private(set) var sawDeviceNotReady = false

    public init(keepLines: Int = 200) {
        tail = LineTail(limit: keepLines)
    }

    public mutating func consume(_ line: String) {
        tail.append(line)
        if XcodebuildOutput.isSigningError(line) { sawSigningError = true }
        if XcodebuildOutput.isDeviceNotReady(line) { sawDeviceNotReady = true }
    }

    public var lines: [String] { tail.lines }

    /// Signing comes first: its fix is the user's, and a retry cannot help.
    public var failureKind: WDABuildFailure.Kind {
        sawSigningError ? .signing : sawDeviceNotReady ? .deviceNotReady : .other
    }
}

/// What the output of `xcodebuild` says.
public enum XcodebuildOutput {
    /// WDA prints `ServerURLHere->http://<address>:8100<-ServerURLHere` when it listens.
    /// The address is the iPhone's Wi-Fi address, so only the port is of use.
    public static func serverURL(in line: String) -> URL? {
        guard let start = line.range(of: "ServerURLHere->"),
              let end = line.range(of: "<-ServerURLHere", range: start.upperBound..<line.endIndex)
        else { return nil }
        return URL(string: String(line[start.upperBound..<end.lowerBound]))
    }

    /// Phrases of signing and provisioning errors. A new build can fix them, for example
    /// when a free account's profile expires after 7 days. Matched without regard to case.
    static let signingErrorPhrases = [
        "no profiles for",
        "requires a development team",
        "no account for team",
        "errsecinternalcomponent",
        "application verification failed",
        "could not be verified",
        "not been explicitly trusted",
        "invalid code signature",
        "inadequate entitlements",
        "invalid entitlements",
    ]

    /// These also appear in a good build ("Provisioning Profile: …" under each CodeSign step),
    /// so they count only on a line that reports a failure.
    static let signingTopics = ["provisioning profile", "signing certificate", "code signature", "entitlements"]
    static let failureWords = ["error", "failed", "expired", "invalid", "not found"]

    public static func isSigningError(_ line: String) -> Bool {
        let lower = line.lowercased()
        if signingErrorPhrases.contains(where: lower.contains) { return true }
        return signingTopics.contains(where: lower.contains) && failureWords.contains(where: lower.contains)
    }

    /// Phrases of a build that failed because the iPhone was not ready: locked, busy, still
    /// "Preparing…" after it was plugged in, or not yet connected. A later try can work.
    static let deviceNotReadyPhrases = [
        "unable to find a destination", "busy", "locked", "not available", "preparing", "not connected",
    ]

    public static func isDeviceNotReady(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("error") && deviceNotReadyPhrases.contains(where: lower.contains)
    }

    /// A test run on a locked iPhone prints `"Unlock <name> to Continue"` and waits. It goes on by itself
    /// after the unlock.
    public static func isWaitingForUnlock(_ line: String) -> Bool {
        line.contains("com.apple.dt.deviceprep") && line.contains("Unlock ") && line.contains(" to Continue")
    }

    public static let signingHint = "WebDriverAgent could not be signed or installed. Open Xcode > Settings > Accounts and sign in. "
        + "If the iPhone asks, trust your developer in Settings > General > VPN & Device Management."
}
