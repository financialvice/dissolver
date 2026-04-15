import AppKit
import Foundation

let args = CommandLine.arguments

if args.contains("--help") || args.contains("-h") {
    print("""
    dissolve — dissolve all visible windows with a Metal shader effect.

    Usage:
      dissolve           Trigger the dissolve animation and return immediately.
      dissolve --help    Show this help.
    """)
    exit(0)
}

// Internal flag: we've already detached and are the child that runs the animation.
let runFlag = "--__run"

if !args.contains(runFlag) {
    let exeURL = Bundle.main.executableURL ?? URL(fileURLWithPath: args[0])
    let child = Process()
    child.executableURL = exeURL
    child.arguments = [runFlag]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    do {
        try child.run()
    } catch {
        FileHandle.standardError.write(Data("dissolve: failed to spawn: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// Child: ignore SIGHUP so we survive the parent shell closing its tty mid-animation.
signal(SIGHUP, SIG_IGN)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: DissolveOverlay?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let capture = try await ScreenCapture.captureWindows()
                guard let screen = NSScreen.main, !capture.windows.isEmpty else {
                    NSApp.terminate(nil); return
                }
                let overlay = DissolveOverlay()
                self.overlay = overlay
                overlay.present(windows: capture.windows,
                                displaySize: capture.displaySize,
                                on: screen,
                                duration: 2.5) {
                    NSApp.terminate(nil)
                }
                // Let the overlay paint a frame (showing the captured windows) before
                // we hide the real ones underneath. ~33 ms = two frames at 60 Hz.
                try? await Task.sleep(nanoseconds: 33_000_000)
                WindowHider.hideAllOtherApps()
            } catch {
                FileHandle.standardError.write(Data("dissolve failed: \(error)\n".utf8))
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
