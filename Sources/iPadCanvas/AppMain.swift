import AppKit
import SwiftUI
import Carbon.HIToolbox

final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: CanvasWindow!
    private var statusItem: NSStatusItem!
    private var hotKeyShowHideRef: EventHotKeyRef?
    private var hotKeyClickThroughRef: EventHotKeyRef?
    private let state = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconImage = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon") {
            NSApp.applicationIconImage = iconImage
        }
        setupMainMenu()
        setupStatusItem()
        setupMainWindow()
        registerGlobalHotKeys()
        state.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        bringMainWindowToFront()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringMainWindowToFront()
        return true
    }

    private func bringMainWindowToFront() {
        guard let win = window else { return }
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hk1 = hotKeyShowHideRef {
            UnregisterEventHotKey(hk1)
        }
        if let hk2 = hotKeyClickThroughRef {
            UnregisterEventHotKey(hk2)
        }
        state.stop()
    }

    private func setupMainWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 960, height: 720)
        window = CanvasWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "iPad 畫布視窗"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)
        window.minSize = NSSize(width: 380, height: 280)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isExcludedFromWindowsMenu = false

        let hostingView = NSHostingView(rootView: ContentView(state: state))
        window.contentView = hostingView
        window.center()

        state.mainWindow = window
        state.applyWindowAttributes()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu Bar & Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "ipad.and.iphone", accessibilityDescription: "iPad 畫布視窗")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "顯示 / 隱藏 iPad 視窗 (⌥Space)", action: #selector(menuToggleWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "切換視窗置頂 (Always on Top)", action: #selector(menuToggleAlwaysOnTop), keyEquivalent: "t")
        menu.addItem(withTitle: "切換無邊框純淨模式 (Borderless)", action: #selector(menuToggleBorderless), keyEquivalent: "b")
        menu.addItem(withTitle: "切換滑鼠點擊穿透 (⌥E)", action: #selector(menuToggleClickThrough), keyEquivalent: "e")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "水平鏡像翻轉 (檢查構圖)", action: #selector(menuToggleFlip), keyEquivalent: "f")
        menu.addItem(withTitle: "順時針旋轉 90°", action: #selector(menuRotate), keyEquivalent: "r")
        menu.addItem(withTitle: "貼合 iPad 畫布比例", action: #selector(menuFitAspect), keyEquivalent: "0")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "重新廣播 AirPlay 訊號", action: #selector(menuRestartAirPlay), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "結束 iPad 畫布視窗", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "關於 iPad 畫布視窗", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隱藏 iPad 畫布視窗", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "結束 iPad 畫布視窗", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Canvas & Window Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "畫布與視窗")
        viewMenuItem.submenu = viewMenu

        let topItem = NSMenuItem(title: "切換視窗置頂 (Always on Top)", action: #selector(menuToggleAlwaysOnTop), keyEquivalent: "t")
        topItem.target = self
        viewMenu.addItem(topItem)

        let borderlessItem = NSMenuItem(title: "切換無邊框純淨模式 (Borderless)", action: #selector(menuToggleBorderless), keyEquivalent: "b")
        borderlessItem.target = self
        viewMenu.addItem(borderlessItem)

        let clickThroughItem = NSMenuItem(title: "切換滑鼠點擊穿透 (描圖對照)", action: #selector(menuToggleClickThrough), keyEquivalent: "e")
        clickThroughItem.target = self
        viewMenu.addItem(clickThroughItem)

        viewMenu.addItem(NSMenuItem.separator())

        let flipItem = NSMenuItem(title: "水平鏡像翻轉 (檢查構圖)", action: #selector(menuToggleFlip), keyEquivalent: "f")
        flipItem.target = self
        viewMenu.addItem(flipItem)

        let rotateItem = NSMenuItem(title: "順時針旋轉 90°", action: #selector(menuRotate), keyEquivalent: "r")
        rotateItem.target = self
        viewMenu.addItem(rotateItem)

        let fitItem = NSMenuItem(title: "貼合 iPad 畫布比例", action: #selector(menuFitAspect), keyEquivalent: "0")
        fitItem.target = self
        viewMenu.addItem(fitItem)

        viewMenu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: "複製當前畫面至剪貼簿", action: #selector(menuCopyScreenshot), keyEquivalent: "c")
        copyItem.target = self
        viewMenu.addItem(copyItem)

        let saveItem = NSMenuItem(title: "儲存截圖至桌面", action: #selector(menuSaveScreenshot), keyEquivalent: "s")
        saveItem.target = self
        viewMenu.addItem(saveItem)

        // Window Menu (Required by macOS WindowServer for Cmd+Tab, Stage Manager, Mission Control)
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "視窗")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "縮放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "前移全部視窗", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuToggleWindow() {
        state.toggleWindowVisibility()
    }

    @objc private func menuToggleAlwaysOnTop() {
        state.toggleAlwaysOnTop()
    }

    @objc private func menuToggleBorderless() {
        state.toggleBorderless()
    }

    @objc private func menuToggleClickThrough() {
        state.toggleClickThrough()
    }

    @objc private func menuToggleFlip() {
        state.toggleHorizontalFlip()
    }

    @objc private func menuRotate() {
        state.rotateClockwise()
    }

    @objc private func menuFitAspect() {
        state.fitWindowToVideoAspect()
    }

    @objc private func menuCopyScreenshot() {
        state.copyScreenshotToClipboard()
    }

    @objc private func menuSaveScreenshot() {
        state.saveScreenshotToDesktop()
    }

    @objc private func menuRestartAirPlay() {
        state.restartAirPlayServer()
    }

    // MARK: - Global Carbon HotKeys (No Accessibility Permission Needed)

    private func registerGlobalHotKeys() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1:
                        AppState.shared.toggleWindowVisibility()
                    case 2:
                        AppState.shared.toggleClickThrough()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            nil
        )

        // HotKey 1: Option + Space -> Show / Hide iPad Window
        let id1 = EventHotKeyID(signature: OSType(0x49504356), id: 1) // 'IPCV'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            id1,
            GetApplicationEventTarget(),
            0,
            &hotKeyShowHideRef
        )

        // HotKey 2: Option + E -> Toggle Click-Through Mode
        let id2 = EventHotKeyID(signature: OSType(0x49504356), id: 2)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(optionKey),
            id2,
            GetApplicationEventTarget(),
            0,
            &hotKeyClickThroughRef
        )
    }
}

@main
struct iPadCanvasApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
