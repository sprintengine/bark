import Foundation
import ServiceManagement

/// "Launch at login" through SMAppService: the app itself is the login item, and the user can see
/// and remove it in System Settings › General › Login Items. The system is the source of truth,
/// so nothing is saved in settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        // Demo and screenshot runs never change the real login items.
        guard !AppInfo.isDemo else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
