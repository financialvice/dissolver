import AppKit
import MetalKit

private final class TransparentMTKView: MTKView {
    override var isOpaque: Bool { false }
}

final class DissolveOverlay {
    private var window: NSWindow?
    private var renderer: DissolveRenderer?

    func present(windows: [CapturedWindow],
                 displaySize: CGSize,
                 on screen: NSScreen,
                 duration: CFTimeInterval,
                 onComplete: @escaping () -> Void) {
        let device = MTLCreateSystemDefaultDevice()!

        let view = TransparentMTKView(frame: screen.frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        let renderer = DissolveRenderer(device: device,
                                        windows: windows,
                                        displaySize: displaySize,
                                        duration: duration) { [weak self] in
            self?.tearDown()
            onComplete()
        }
        view.delegate = renderer
        self.renderer = renderer

        let win = NSWindow(contentRect: screen.frame,
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false,
                           screen: screen)
        // AppKit may animate a newly shown borderless window; that makes the
        // replacement screenshot appear to scale in before the real window hides.
        win.animationBehavior = .none
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .screenSaver
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.contentView = view
        win.orderFrontRegardless()
        self.window = win
    }

    private func tearDown() {
        window?.orderOut(nil)
        window = nil
        renderer = nil
    }
}
