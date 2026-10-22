import AppKit
import SwiftUI
import CoreVideo
import CoreImage
import CoreMedia

enum ConnectionMode: String, CaseIterable, Identifiable {
    case wifiAirPlay = "Wi-Fi 無線鏡像 (AirPlay)"
    case usbCable = "USB 有線直連"

    var id: String { rawValue }
}

enum AirPlayQualityPreset: String, CaseIterable, Identifiable {
    case ultraFast60 = "⚡️ 零延遲繪圖推薦 (1920 × 1440 @ 60 FPS · 逼近有線速度)"
    case lightning60 = "🚀 極致低延遲響應 (1440 × 1080 @ 60 FPS · 最低傳輸延遲)"
    case pro2K60 = "🎨 2K 超清視網膜 (2560 × 1920 @ 60 FPS · 最佳精細度)"

    var id: String { rawValue }

    var dimensions: (width: Int, height: Int, fps: Int) {
        switch self {
        case .ultraFast60: return (1920, 1440, 60)
        case .lightning60: return (1440, 1080, 60)
        case .pro2K60: return (2560, 1920, 60)
        }
    }
}

final class AppState: ObservableObject {
    static let shared = AppState()

    // Connection & Streaming State
    @Published var connectionMode: ConnectionMode = .wifiAirPlay {
        didSet {
            if oldValue != connectionMode {
                switchConnectionMode(to: connectionMode)
            }
        }
    }
    @Published var qualityPreset: AirPlayQualityPreset = .ultraFast60 {
        didSet {
            if oldValue != qualityPreset && connectionMode == .wifiAirPlay {
                restartAirPlayServer()
            }
        }
    }
    @Published var serverName: String = "iPad 畫布視窗"
    @Published var enableP2P: Bool = false {
        didSet {
            if oldValue != enableP2P && connectionMode == .wifiAirPlay {
                restartAirPlayServer()
            }
        }
    }
    @Published var isServerRunning: Bool = false
    @Published var airPlayPort: Int = 0
    @Published var isStreaming: Bool = false
    @Published var connectedDeviceName: String = ""
    @Published var connectedDeviceModel: String = ""
    @Published var statusMessage: String = "正在啟動極速無線接收服務..."
    @Published var videoSize: CGSize = CGSize(width: 1920, height: 1440)
    @Published var currentFPS: Int = 0
    @Published var currentLatencyMs: Double = 0.0

    // USB State
    @Published var usbDevices: [USBiPadDevice] = []
    @Published var selectedUSBDeviceID: String = ""

    // Window & Artist Controls
    @Published var isAlwaysOnTop: Bool = false {
        didSet { applyWindowAttributes() }
    }
    @Published var isBorderless: Bool = false {
        didSet { applyWindowStyleMask() }
    }
    @Published var isFlippedHorizontally: Bool = false
    @Published var rotationDegrees: Int = 0
    @Published var windowOpacity: Double = 1.0 {
        didSet { applyWindowAttributes() }
    }
    @Published var isClickThrough: Bool = false {
        didSet {
            if isClickThrough && !isAlwaysOnTop {
                isAlwaysOnTop = true
            }
            applyWindowAttributes()
        }
    }
    @Published var toastMessage: String? = nil

    // Underlying components
    let canvasView = VideoCanvasNSView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
    weak var mainWindow: NSWindow?

    private let decoder = H264HardwareDecoder()
    private let usbManager = USBCaptureManager()
    private let bufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?

    private var frameCounter: Int = 0
    private var fpsTimer: Timer?
    private var toastWorkItem: DispatchWorkItem?

    private init() {
        setupDecoder()
        setupUSBManager()
        startFPSTimer()
    }

    private func setupDecoder() {
        decoder.onDecodedPixelBuffer = { [weak self] pixelBuffer in
            guard let self = self else { return }
            self.handleIncomingPixelBuffer(pixelBuffer)
        }
    }

    private func setupUSBManager() {
        usbDevices = usbManager.availableDevices()
        usbManager.onDevicesUpdated = { [weak self] devices in
            guard let self = self else { return }
            self.usbDevices = devices
            if self.connectionMode == .usbCable && !self.isStreaming && !devices.isEmpty {
                self.usbManager.startCapture(deviceID: self.selectedUSBDeviceID.isEmpty ? nil : self.selectedUSBDeviceID)
            }
        }
        usbManager.onConnectionStateChanged = { [weak self] connected, info in
            guard let self = self, self.connectionMode == .usbCable else { return }
            self.isStreaming = connected
            if connected {
                self.connectedDeviceName = info
                self.statusMessage = "已透過 USB 連接：\(info)"
            } else {
                self.connectedDeviceName = ""
                self.statusMessage = info.isEmpty ? "等待 USB 連接 iPad..." : info
                self.canvasView.clearFrame()
            }
        }
        usbManager.onPixelBuffer = { [weak self] pixelBuffer, size in
            guard let self = self, self.connectionMode == .usbCable else { return }
            self.handleIncomingPixelBuffer(pixelBuffer, reportedSize: size)
        }
    }

    private func startFPSTimer() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.bufferLock.lock()
            let count = self.frameCounter
            self.frameCounter = 0
            self.bufferLock.unlock()
            if self.currentFPS != count {
                self.currentFPS = count
            }
        }
    }

    func start() {
        switchConnectionMode(to: connectionMode)
    }

    func stop() {
        airplay_bridge_stop()
        usbManager.stopCapture()
        decoder.reset()
        isServerRunning = false
        isStreaming = false
    }

    private func switchConnectionMode(to mode: ConnectionMode) {
        canvasView.clearFrame()
        decoder.reset()
        isStreaming = false
        currentFPS = 0
        currentLatencyMs = 0.0

        switch mode {
        case .wifiAirPlay:
            usbManager.stopCapture()
            startAirPlayServer()
        case .usbCable:
            airplay_bridge_stop()
            isServerRunning = false
            usbDevices = usbManager.availableDevices()
            usbManager.startCapture(deviceID: selectedUSBDeviceID.isEmpty ? nil : selectedUSBDeviceID)
        }
    }

    func startAirPlayServer() {
        let dims = qualityPreset.dimensions
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = serverName.withCString { namePtr -> Int32 in
            return airplay_bridge_start(
                namePtr,
                Int32(dims.width),
                Int32(dims.height),
                Int32(dims.fps),
                enableP2P,
                ctx,
                cVideoFrameCallback,
                cVideoSizeCallback,
                cClientStateCallback,
                cLogCallback
            )
        }

        if result == 0 {
            isServerRunning = true
            airPlayPort = Int(airplay_bridge_get_port())
            statusMessage = "等待 iPad 螢幕鏡像輸出至「\(serverName)」..."
        } else {
            isServerRunning = false
            statusMessage = "AirPlay 服務啟動失敗 (錯誤碼 \(result))"
        }
    }

    func restartAirPlayServer() {
        guard connectionMode == .wifiAirPlay else { return }
        showToast("正在重新啟動無線極速鏡像服務...")
        airplay_bridge_stop()
        decoder.reset()
        canvasView.clearFrame()
        isStreaming = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.startAirPlayServer()
        }
    }

    func disconnectCurrentClient() {
        if connectionMode == .wifiAirPlay {
            airplay_bridge_disconnect_client()
            decoder.reset()
            canvasView.clearFrame()
            isStreaming = false
            showToast("已中斷目前的 iPad 連線")
        } else {
            usbManager.stopCapture()
            canvasView.clearFrame()
            isStreaming = false
        }
    }

    fileprivate func handleRawVideoPacket(data: UnsafePointer<UInt8>, length: Int, isH265: Bool, latencyMs: Float) {
        guard !isH265 else { return }
        if latencyMs > 0 {
            let lat = Double(latencyMs)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentLatencyMs = self.currentLatencyMs == 0.0 ? lat : (self.currentLatencyMs * 0.8 + lat * 0.2)
            }
        }
        decoder.decodeAnnexB(data: data, length: length)
    }

    fileprivate func handleVideoSizeReport(widthSource: Float, heightSource: Float, width: Float, height: Float) {
        let w = CGFloat(widthSource > 0 ? widthSource : width)
        let h = CGFloat(heightSource > 0 ? heightSource : height)
        guard w > 0, h > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.videoSize != CGSize(width: w, height: h) {
                self.videoSize = CGSize(width: w, height: h)
            }
        }
    }

    fileprivate func handleClientState(connected: Bool, name: String, model: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isStreaming = connected
            if connected {
                self.connectedDeviceName = name.isEmpty ? "iPad" : name
                self.connectedDeviceModel = model
                self.statusMessage = "已連線：\(self.connectedDeviceName)"
                self.showToast("已連上 \(self.connectedDeviceName)")
            } else {
                self.connectedDeviceName = ""
                self.connectedDeviceModel = ""
                self.currentFPS = 0
                self.currentLatencyMs = 0.0
                self.decoder.reset()
                self.canvasView.clearFrame()
                self.statusMessage = "等待 iPad 螢幕鏡像輸出至「\(self.serverName)」..."
            }
        }
    }

    private func handleIncomingPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        reportedSize: CGSize? = nil
    ) {
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        frameCounter += 1
        bufferLock.unlock()

        // Ultra-low latency direct GPU rendering
        canvasView.displayPixelBuffer(pixelBuffer)

        let w = reportedSize?.width ?? CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = reportedSize?.height ?? CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        if w > 0 && h > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.isStreaming {
                    self.isStreaming = true
                }
                if self.videoSize != CGSize(width: w, height: h) {
                    self.videoSize = CGSize(width: w, height: h)
                }
            }
        }
    }

    // MARK: - Window & Artist Actions

    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
        showToast(isAlwaysOnTop ? "📌 已開啟視窗置頂 (Always on Top)" : "已切換為一般視窗 (可用 Cmd+Tab 切換)")
    }

    func toggleBorderless() {
        isBorderless.toggle()
        showToast(isBorderless ? "🖼️ 已切換為無邊框純淨畫布模式" : "已恢復標準視窗標題列")
    }

    func toggleHorizontalFlip() {
        isFlippedHorizontally.toggle()
        showToast(isFlippedHorizontally ? "↔️ 已開啟水平鏡像翻轉 (繪圖骨架/構圖檢查)" : "已恢復正常方向")
    }

    func rotateClockwise() {
        rotationDegrees = (rotationDegrees + 90) % 360
        showToast("🔄 畫面旋轉：\(rotationDegrees)°")
        fitWindowToVideoAspect()
    }

    func toggleClickThrough() {
        isClickThrough.toggle()
        showToast(isClickThrough ? "👻 已開啟滑鼠穿透描圖模式 (按 Option+E 或從右上選單列關閉)" : "已關閉滑鼠穿透模式")
    }

    func fitWindowToVideoAspect() {
        guard let window = mainWindow else { return }
        let isQuarterTurn = (abs(rotationDegrees) % 180) == 90
        let rawW = max(videoSize.width, 100)
        let rawH = max(videoSize.height, 100)
        let targetAspect = isQuarterTurn ? (rawH / rawW) : (rawW / rawH)

        var frame = window.frame
        let currentArea = max(frame.width * frame.height, 480 * 360)
        var newWidth = sqrt(currentArea * targetAspect)
        var newHeight = newWidth / targetAspect

        if let screenFrame = window.screen?.visibleFrame {
            let maxW = screenFrame.width * 0.92
            let maxH = screenFrame.height * 0.92
            if newWidth > maxW {
                newWidth = maxW
                newHeight = newWidth / targetAspect
            }
            if newHeight > maxH {
                newHeight = maxH
                newWidth = newHeight * targetAspect
            }
        }

        let centerX = frame.midX
        let centerY = frame.midY
        frame.size = NSSize(width: round(newWidth), height: round(newHeight))
        frame.origin = NSPoint(x: round(centerX - newWidth / 2), y: round(centerY - newHeight / 2))
        window.setFrame(frame, display: true, animate: true)
        showToast("📐 已貼合 iPad 畫布比例")
    }

    func applyWindowAttributes() {
        guard let window = mainWindow else { return }
        window.level = isAlwaysOnTop ? .floating : .normal
        window.alphaValue = CGFloat(max(0.2, min(1.0, windowOpacity)))
        window.ignoresMouseEvents = isClickThrough

        if isAlwaysOnTop {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            // Standard window behavior: perfectly participates in Cmd+Tab, Stage Manager, Mission Control, and window cycle
            window.collectionBehavior = [.participatesInCycle, .managed, .fullScreenPrimary]
        }
    }

    func applyWindowStyleMask() {
        guard let window = mainWindow else { return }
        let savedFrame = window.frame
        // Keep .titled so macOS WindowServer / Stage Manager / Cmd+Tab always tracks the window
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = isBorderless
        window.standardWindowButton(.miniaturizeButton)?.isHidden = isBorderless
        window.standardWindowButton(.zoomButton)?.isHidden = isBorderless
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.setFrame(savedFrame, display: true)
        applyWindowAttributes()
        window.makeKeyAndOrderFront(nil)
    }

    func toggleWindowVisibility() {
        guard let window = mainWindow else { return }
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Screenshot Export

    private func renderCurrentNSImage() -> NSImage? {
        bufferLock.lock()
        let pixelBuffer = latestPixelBuffer
        bufferLock.unlock()

        guard let pb = pixelBuffer else { return nil }
        var ciImage = CIImage(cvPixelBuffer: pb)

        if isFlippedHorizontally {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: ciImage.extent.width, y: 0))
        }

        switch rotationDegrees {
        case 90:
            ciImage = ciImage.oriented(.right)
        case 180:
            ciImage = ciImage.oriented(.down)
        case 270:
            ciImage = ciImage.oriented(.left)
        default:
            break
        }

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func copyScreenshotToClipboard() {
        guard let image = renderCurrentNSImage() else {
            showToast("⚠️ 目前尚無 iPad 畫面可截圖")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        showToast("📋 已將當前畫布複製到剪貼簿")
    }

    func saveScreenshotToDesktop() {
        guard let image = renderCurrentNSImage(),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            showToast("⚠️ 目前尚無 iPad 畫面可儲存")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "iPad-Canvas-\(formatter.string(from: Date())).png"
        let desktopURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)

        do {
            try pngData.write(to: desktopURL)
            showToast("📸 已儲存截圖至桌面：\(filename)")
        } catch {
            showToast("⚠️ 儲存失敗：\(error.localizedDescription)")
        }
    }

    func showToast(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.toastWorkItem?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) {
                self.toastMessage = message
            }
            let item = DispatchWorkItem { [weak self] in
                withAnimation(.easeInOut(duration: 0.25)) {
                    self?.toastMessage = nil
                }
            }
            self.toastWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: item)
        }
    }
}

// MARK: - C Bridge Function Callbacks

private let cVideoFrameCallback: ap_video_frame_cb = { ctx, data, dataLen, isH265, _, latencyMs in
    guard let ctx = ctx, let data = data, dataLen > 0 else { return }
    let state = Unmanaged<AppState>.fromOpaque(ctx).takeUnretainedValue()
    state.handleRawVideoPacket(data: data, length: Int(dataLen), isH265: isH265, latencyMs: latencyMs)
}

private let cVideoSizeCallback: ap_video_size_cb = { ctx, wSrc, hSrc, w, h in
    guard let ctx = ctx else { return }
    let state = Unmanaged<AppState>.fromOpaque(ctx).takeUnretainedValue()
    state.handleVideoSizeReport(widthSource: wSrc, heightSource: hSrc, width: w, height: h)
}

private let cClientStateCallback: ap_client_state_cb = { ctx, connected, namePtr, modelPtr in
    guard let ctx = ctx else { return }
    let state = Unmanaged<AppState>.fromOpaque(ctx).takeUnretainedValue()
    let name = namePtr != nil ? String(cString: namePtr!) : ""
    let model = modelPtr != nil ? String(cString: modelPtr!) : ""
    state.handleClientState(connected: connected, name: name, model: model)
}

private let cLogCallback: ap_log_cb = { _, _, _ in
    // Quiet in production
}
