import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!
    var mtkView: MTKView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meadow   [WASD/arrows pan, Q/E or drag rotate, scroll zoom, C cinematic]"
        window.center()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this machine")
        }

        mtkView = InputView(frame: frame, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm_srgb
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.sampleCount = 4
        mtkView.preferredFramesPerSecond = 60
        mtkView.clearColor = MTLClearColor(red: 0.62, green: 0.75, blue: 0.82, alpha: 1.0)

        renderer = Renderer(view: mtkView)
        mtkView.delegate = renderer

        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(mtkView)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
