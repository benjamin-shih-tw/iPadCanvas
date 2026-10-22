import Foundation
import AVFoundation
import CoreMediaIO
import CoreVideo

struct USBiPadDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

final class USBCaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onPixelBuffer: ((CVPixelBuffer, CGSize) -> Void)?
    var onDevicesUpdated: (([USBiPadDevice]) -> Void)?
    var onConnectionStateChanged: ((Bool, String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.ipadcanvas.usbcapture", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()

    override init() {
        super.init()
        enableScreenCaptureDevices()
        setupSession()
        observeDeviceChanges()
    }

    private func enableScreenCaptureDevices() {
        var property = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &property,
            0,
            nil,
            dataSize,
            &allow
        )
    }

    private func setupSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        captureSession.commitConfiguration()
    }

    private func observeDeviceChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceChanged),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceChanged),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }

    @objc private func handleDeviceChanged(_ notification: Notification) {
        let devices = availableDevices()
        DispatchQueue.main.async { [weak self] in
            self?.onDevicesUpdated?(devices)
        }
    }

    func availableDevices() -> [USBiPadDevice] {
        enableScreenCaptureDevices()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: nil,
            position: .unspecified
        )
        return discovery.devices
            .filter { dev in
                dev.hasMediaType(AVMediaType.video) || dev.hasMediaType(AVMediaType.muxed)
            }
            .map { USBiPadDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func startCapture(deviceID: String? = nil) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.enableScreenCaptureDevices()

            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: nil,
                position: .unspecified
            )
            let candidates = discovery.devices.filter {
                $0.hasMediaType(AVMediaType.video) || $0.hasMediaType(AVMediaType.muxed)
            }

            let targetDevice: AVCaptureDevice?
            if let id = deviceID, let matched = candidates.first(where: { $0.uniqueID == id }) {
                targetDevice = matched
            } else if let iPadMatch = candidates.first(where: { $0.localizedName.localizedCaseInsensitiveContains("iPad") }) {
                targetDevice = iPadMatch
            } else {
                targetDevice = candidates.first
            }

            guard let device = targetDevice else {
                DispatchQueue.main.async {
                    self.onConnectionStateChanged?(false, "尚未偵測到 USB 連接的 iPad")
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.captureSession.beginConfiguration()
                if let oldInput = self.currentInput {
                    self.captureSession.removeInput(oldInput)
                }
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                    self.currentInput = input
                }
                self.captureSession.commitConfiguration()

                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                let name = device.localizedName
                DispatchQueue.main.async {
                    self.onConnectionStateChanged?(true, name)
                }
            } catch {
                DispatchQueue.main.async {
                    self.onConnectionStateChanged?(false, "無法啟動 USB 擷取：\(error.localizedDescription)")
                }
            }
        }
    }

    func stopCapture() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async {
                self.onConnectionStateChanged?(false, "")
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        onPixelBuffer?(pixelBuffer, CGSize(width: width, height: height))
    }
}
