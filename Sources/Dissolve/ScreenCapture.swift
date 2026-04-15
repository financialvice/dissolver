import AppKit
import ScreenCaptureKit

struct CapturedWindow {
    let image: CGImage
    let originUV: CGPoint   // top-left in main-display UV space (0..1, top-left origin)
    let sizeUV: CGSize
}

struct CaptureResult {
    let displaySize: CGSize  // in points
    let windows: [CapturedWindow]
}

enum ScreenCapture {
    static func captureWindows() async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "Dissolve", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let displaySize = display.frame.size
        let myPid = ProcessInfo.processInfo.processIdentifier

        // Real app windows only: normal layer, on screen, owned by some app, not us, big enough.
        let candidates = content.windows.filter { w in
            w.windowLayer == 0
                && w.isOnScreen
                && w.frame.width >= 50 && w.frame.height >= 50
                && (w.owningApplication?.processID).map { $0 != myPid } ?? false
        }

        // Capture each window in parallel — independent SCScreenshotManager calls.
        let captured = await withTaskGroup(of: CapturedWindow?.self) { group in
            for w in candidates {
                let frame = w.frame
                let filter = SCContentFilter(desktopIndependentWindow: w)
                group.addTask {
                    let config = SCStreamConfiguration()
                    config.width  = Int(frame.width  * 2) // retina
                    config.height = Int(frame.height * 2)
                    config.showsCursor = false
                    config.capturesAudio = false
                    // Some windows refuse to capture (protected content, etc.) — just skip.
                    guard let img = try? await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: config
                    ) else { return nil }
                    return CapturedWindow(
                        image: img,
                        originUV: CGPoint(x: frame.minX / displaySize.width,
                                          y: frame.minY / displaySize.height),
                        sizeUV: CGSize(width:  frame.width  / displaySize.width,
                                       height: frame.height / displaySize.height)
                    )
                }
            }
            var result: [CapturedWindow] = []
            for await item in group {
                if let item { result.append(item) }
            }
            return result
        }

        return CaptureResult(displaySize: displaySize, windows: captured)
    }
}
