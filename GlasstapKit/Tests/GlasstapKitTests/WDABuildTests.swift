import Foundation
import Testing
@testable import GlasstapKit

@Suite struct WDABuildTests {
    let signing = WDASigning(teamID: "ABCDE12345", bundlePrefix: WDASigning.defaultBundlePrefix(teamID: "ABCDE12345"))
    var build: WDABuild { WDABuild(wdaVersion: "16.12.10", signing: signing, iOSMajorVersion: 26) }

    @Test func defaultPrefixAndRunnerID() {
        #expect(signing.bundlePrefix == "glasstap.wda.abcde12345")
        #expect(signing.runnerBundleID == "glasstap.wda.abcde12345.xctrunner")
    }

    @Test func xcconfigSetsTheRunnerIDOnly() {
        #expect(build.xcconfig == """
            // Written by glasstap for the WebDriverAgent build.
            DEVELOPMENT_TEAM = ABCDE12345
            CODE_SIGN_STYLE = Automatic
            CODE_SIGN_IDENTITY = Apple Development
            WDA_BID_WebDriverAgentRunner = glasstap.wda.abcde12345
            PRODUCT_BUNDLE_IDENTIFIER = $(WDA_BID_$(TARGET_NAME):default=$(inherited))

            """)
    }

    @Test func cacheKeyChangesWithEachInput() {
        #expect(build.cacheKey == "16.12.10-ABCDE12345-glasstap.wda.abcde12345-ios26")
        var other = build
        other.iOSMajorVersion = 27
        #expect(other.cacheKey != build.cacheKey)
        other = build
        other.signing.bundlePrefix = "com.example.wda"
        #expect(other.cacheKey != build.cacheKey)
        other = build
        other.signing.teamID = "ZZZZZ99999"
        #expect(other.cacheKey != build.cacheKey)
        other = build
        other.wdaVersion = "16.12.11"
        #expect(other.cacheKey != build.cacheKey)
    }

    @Test func arguments() {
        let args = build.buildArguments(project: URL(fileURLWithPath: "/src/WebDriverAgent.xcodeproj"), udid: "U",
                                        derivedData: URL(fileURLWithPath: "/dd"), xcconfig: URL(fileURLWithPath: "/dd/s.xcconfig"))
        #expect(args == ["build-for-testing", "-project", "/src/WebDriverAgent.xcodeproj", "-scheme", "WebDriverAgentRunner",
                         "-destination", "id=U", "-derivedDataPath", "/dd", "-xcconfig", "/dd/s.xcconfig",
                         "-allowProvisioningUpdates"])
        #expect(WDABuild.testArguments(testRun: URL(fileURLWithPath: "/dd/x.xctestrun"), udid: "U")
            == ["test-without-building", "-xctestrun", "/dd/x.xctestrun", "-destination", "id=U"])
    }

    @Test func findsTheTestRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glasstap-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WDABuild.findTestRun(inDerivedData: root) == nil)
        let products = root.appendingPathComponent("Build/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        for name in ["Debug-iphoneos", "WebDriverAgentRunner_iphoneos27.0-arm64.xctestrun", "Other.xctestrun"] {
            FileManager.default.createFile(atPath: products.appendingPathComponent(name).path, contents: Data())
        }
        #expect(WDABuild.findTestRun(inDerivedData: root)?.lastPathComponent == "WebDriverAgentRunner_iphoneos27.0-arm64.xctestrun")
    }

    // MARK: - xcodebuild output

    @Test func serverURLLineFromARealRun() throws {
        let lines = String(decoding: try fixture("xcodebuild-test-without-building.txt"), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        let found = lines.compactMap(XcodebuildOutput.serverURL(in:))
        #expect(found == [URL(string: "http://192.0.2.10:8100")!])
        #expect(found.first?.port == 8100)
        // Nothing in a normal run reads as a signing error.
        #expect(!lines.contains(where: XcodebuildOutput.isSigningError))
    }

    @Test func serverURLNeedsBothMarkers() {
        #expect(XcodebuildOutput.serverURL(in: "ServerURLHere->http://192.0.2.10:8100") == nil)
        #expect(XcodebuildOutput.serverURL(in: "http://192.0.2.10:8100<-ServerURLHere") == nil)
        #expect(XcodebuildOutput.serverURL(in: "x ServerURLHere->http://[fd00::1]:8101<-ServerURLHere y")?.port == 8101)
    }

    /// Synthetic samples, written after the wording of Xcode's signing and launch errors.
    /// They are not captured output: no signing failure has been seen on the test Mac yet.
    static let syntheticSigningErrors = [
        #"error: No Account for Team "ABCDE12345". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'WebDriverAgentRunner' from project 'WebDriverAgent')"#,
        #"error: No profiles for 'glasstap.wda.abcde12345.xctrunner' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'glasstap.wda.abcde12345.xctrunner'. (in target 'WebDriverAgentRunner' from project 'WebDriverAgent')"#,
        #"error: Signing for "WebDriverAgentRunner" requires a development team. Select a development team in the Signing & Capabilities editor. (in target 'WebDriverAgentRunner' from project 'WebDriverAgent')"#,
        #"error: Provisioning profile "iOS Team Provisioning Profile: glasstap.wda.abcde12345.xctrunner" has expired. (in target 'WebDriverAgentRunner' from project 'WebDriverAgent')"#,
        #"error: No signing certificate "iOS Development" found: No "iOS Development" signing certificate matching team ID "ABCDE12345" with a private key was found."#,
        #"/Users/me/Library/Developer/Xcode/DerivedData/WebDriverAgentRunner-Runner.app: errSecInternalComponent"#,
        #"    Unable to launch glasstap.wda.abcde12345.xctrunner because it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user."#,
        #"    Application Verification Failed: Failed to verify code signature of /private/var/installd/.../WebDriverAgentRunner-Runner.app : 0xe8008029 (The identity used to sign the executable is no longer valid.)"#,
    ]

    /// Synthetic lines of a good build that mention signing without an error.
    static let syntheticGoodBuildLines = [
        "CodeSign /Users/me/Library/Application\\ Support/glasstap/wda-build/x/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app",
        #"    Signing Identity:     "Apple Development: Someone (ABCDE12345)""#,
        #"    Provisioning Profile: "iOS Team Provisioning Profile: *""#,
        "ProcessProductPackaging /dd/WebDriverAgentRunner.entitlements",
        "** TEST BUILD SUCCEEDED **",
        "xcodebuild: error: Unable to find a destination matching the provided destination specifier:",
    ]

    /// Synthetic samples, written after the wording of xcodebuild for an iPhone that is not ready.
    static let syntheticDeviceNotReady = [
        "xcodebuild: error: Unable to find a destination matching the provided destination specifier:",
        "\t\t{ platform:iOS, arch:arm64e, id:00008101-000A1B2C3D4E5F60, name:Test iPhone 12 Pro, error:Test iPhone 12 Pro is busy: Preparing Test iPhone 12 Pro for development }",
        "\t\t{ platform:iOS, id:00008101-000A1B2C3D4E5F60, name:Test iPhone 12 Pro, error:Device is locked }",
        "xcodebuild: error: Test iPhone 12 Pro is not available because it is unpaired.",
    ]

    @Test func aBuildOnAnIPhoneThatIsNotReady() {
        for line in Self.syntheticDeviceNotReady {
            #expect(XcodebuildOutput.isDeviceNotReady(line), "\(line)")
            #expect(!XcodebuildOutput.isSigningError(line), "\(line)")
        }
        // Without an error, the same words are no failure.
        #expect(!XcodebuildOutput.isDeviceNotReady("Preparing Test iPhone 12 Pro"))
        #expect(!XcodebuildOutput.isDeviceNotReady("error: use of unresolved identifier 'x'"))
        // A compile error about API availability is no device problem.
        #expect(!XcodebuildOutput.isDeviceNotReady("error: 'foo()' is unavailable in iOS"))
    }

    @Test func theScanDecidesTheKindOfFailure() {
        var scan = XcodebuildScan(keepLines: 2)
        #expect(scan.failureKind == .other)
        scan.consume(Self.syntheticDeviceNotReady[2])
        #expect(scan.failureKind == .deviceNotReady)
        // A signing error wins: a retry cannot fix it.
        scan.consume(Self.syntheticSigningErrors[0])
        scan.consume("** TEST BUILD FAILED **")
        #expect(scan.failureKind == .signing)
        #expect(scan.lines == [Self.syntheticSigningErrors[0], "** TEST BUILD FAILED **"])
    }

    @Test func signingErrorsAreRecognised() {
        for line in Self.syntheticSigningErrors {
            #expect(XcodebuildOutput.isSigningError(line), "\(line)")
        }
        for line in Self.syntheticGoodBuildLines {
            #expect(!XcodebuildOutput.isSigningError(line), "\(line)")
        }
        #expect(XcodebuildOutput.signingHint.contains("Open Xcode > Settings > Accounts and sign in"))
    }
}

@Suite struct XcodeCheckTests {
    @Test func fullXcode() {
        #expect(XcodeStatus.evaluate(developerDir: "/Applications/Xcode.app/Contents/Developer\n", devicectlFound: true)
            == .ready(developerDir: "/Applications/Xcode.app/Contents/Developer"))
        #expect(XcodeStatus.evaluate(developerDir: "/Applications/Xcode-beta.app/Contents/Developer", devicectlFound: true).isReady)
    }

    @Test func commandLineToolsAreNotEnough() {
        #expect(XcodeStatus.evaluate(developerDir: "/Library/Developer/CommandLineTools", devicectlFound: false)
            == .commandLineToolsOnly(developerDir: "/Library/Developer/CommandLineTools"))
        #expect(XcodeStatus.evaluate(developerDir: "/Applications/Xcode.app/Contents/Developer", devicectlFound: false)
            == .noDevicectl(developerDir: "/Applications/Xcode.app/Contents/Developer"))
        #expect(XcodeStatus.evaluate(developerDir: nil, devicectlFound: false) == .notFound)
        #expect(XcodeStatus.evaluate(developerDir: " ", devicectlFound: true) == .notFound)
    }
}
