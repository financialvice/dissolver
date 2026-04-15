import AppKit

enum WindowHider {
    static func hideAllOtherApps() {
        let me = NSRunningApplication.current.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != me else { continue }
            app.hide()
        }
    }
}
