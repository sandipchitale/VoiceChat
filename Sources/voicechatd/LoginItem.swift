import Foundation
import ServiceManagement

// Spec §10, R-APP-5 — the "Launch at Login" menu item, backed by
// `SMAppService.mainApp`: macOS starts the app itself at login, with no helper
// or launch agent. It works for the `.app` bundle only (not a bare SwiftPM
// build product), which is how VoiceChat is always run.

@MainActor
enum LoginItem {
    /// Registered, including while macOS waits for the person to approve it in
    /// System Settings, so the menu item's check mark matches their choice.
    static var isEnabled: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    /// Registered but not yet allowed in System Settings → General → Login Items.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Registers or unregisters the app. When macOS needs the person's approval,
    /// opens Login Items settings so they can give it.
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write(Data("[voicechatd] Launch at Login: \(error.localizedDescription)\n".utf8))
        }
        if needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
