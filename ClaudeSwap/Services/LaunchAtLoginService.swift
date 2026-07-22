//
//  LaunchAtLoginService.swift
//  ClaudeSwap
//
//  Wraps `SMAppService.mainApp` (macOS 13+) so the rest of the app never
//  touches ServiceManagement directly.
//

import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private init() {}

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Attempts to register/unregister for launch at login. Throws if the
    /// user needs to approve it in System Settings; callers should surface
    /// that as a gentle prompt, not a hard error.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
