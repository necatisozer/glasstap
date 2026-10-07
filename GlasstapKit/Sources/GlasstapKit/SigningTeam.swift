import Foundation
import Security

/// The Apple team that signed this app. A build from source is signed with the user's own team,
/// and WDA needs the same team, so the user does not have to type it.
public enum SigningTeam {
    /// The team of the running app, or nil for an ad-hoc or unsigned build.
    public static func ofThisApp() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

extension GlasstapSettings {
    /// These settings with `team` as the WDA team, if none is set and `team` is a valid team id.
    /// `team` is read only when no team is set.
    public func withDefaultTeam(_ team: @autoclosure () -> String?) -> GlasstapSettings {
        guard teamID.isEmpty, let team = team(), Self.isTeamID(team) else { return self }
        var settings = self
        settings.teamID = team
        return settings
    }
}
