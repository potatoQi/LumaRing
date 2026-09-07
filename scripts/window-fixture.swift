// Manual integration fixture. Creates only disposable windows owned by this app.
import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Test Windows", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = submenu; menu.addItem(appItem); NSApp.mainMenu = menu
        for index in 1...10 {
            let window = NSWindow(contentRect: NSRect(x: 100 + index * 22, y: 160 + index * 12, width: 600, height: 360),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = String(format: "LumaRing Test %02d", index)
            window.collectionBehavior = [.fullScreenPrimary]
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "LumaRing 窗口验证\n\n真实 macOS 窗口 #\(index)\n\n此窗口不包含任何工作文件")
            label.alignment = .center
            label.font = .systemFont(ofSize: 23, weight: .medium)
            label.frame = NSRect(x: 40, y: 90, width: 520, height: 180)
            label.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(label)
            window.backgroundColor = NSColor(calibratedHue: CGFloat(index) / 16, saturation: 0.09, brightness: 0.98, alpha: 1)
            window.orderFront(nil)
            windows.append(window)
        }
        windows[1].miniaturize(nil)
        windows[0].makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
let application = NSApplication.shared
let delegate = FixtureDelegate()
application.delegate = delegate
application.run()
