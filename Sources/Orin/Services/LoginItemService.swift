import Foundation
import Observation
import ServiceManagement

/// Manages whether Orin registers itself as a login item using SMAppService.
/// Registration requires the app to be installed in /Applications and signed;
/// in development SPM builds it will fail gracefully with an error message.
@Observable
final class LoginItemService: Service {
    private(set) var isEnabled = false
    private(set) var errorMessage: String?

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enable: Bool) {
        errorMessage = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            // Fails in dev builds (unsigned / not in /Applications) — surface the reason
            errorMessage = error.localizedDescription
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
