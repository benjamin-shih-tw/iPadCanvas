import AppKit
import SwiftUI
import QuartzCore
import CoreVideo
import IOSurface

final class VideoCanvasNSView: NSView {
    private let videoLayer = CALayer()
    private var videoAspectSize: CGSize = CGSize(width: 1920, height: 1440)
    private var rotationDegrees: Int = 0
    private var isFlippedHorizontally: Bool = false

    private var pendingIOSurface: IOSurface?
    private var isRenderScheduled = false
    private let renderLock = NSLock()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1.0).cgColor
        layer?.masksToBounds = true

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.magnificationFilter = .trilinear
        videoLayer.minificationFilter = .trilinear
        videoLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(videoLayer)
    }

    override var mouseDownCanMoveWindow: Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func layout() {
        super.layout()
        updateVideoLayerGeometry()
    }

    func updateTransform(rotation: Int, flippedHorizontally: Bool, aspectSize: CGSize) {
        let changed = (rotationDegrees != rotation)
            || (isFlippedHorizontally != flippedHorizontally)
            || (videoAspectSize != aspectSize)
        rotationDegrees = rotation
        isFlippedHorizontally = flippedHorizontally
        if aspectSize.width > 0 && aspectSize.height > 0 {
            videoAspectSize = aspectSize
        }
        if changed {
            updateVideoLayerGeometry()
        }
    }

    /// Thread-safe ultra-low latency direct GPU rendering (zero copy, zero queue backlog)
    func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return
        }
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        renderLock.lock()
        pendingIOSurface = ioSurface
        let scheduled = isRenderScheduled
        isRenderScheduled = true
        renderLock.unlock()

        if !scheduled {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.renderLock.lock()
                let surface = self.pendingIOSurface
                self.pendingIOSurface = nil
                self.isRenderScheduled = false
                self.renderLock.unlock()

                guard let surface = surface else { return }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if w > 0 && h > 0 && self.videoAspectSize != CGSize(width: w, height: h) {
                    self.videoAspectSize = CGSize(width: w, height: h)
                    self.updateVideoLayerGeometry()
                }
                self.videoLayer.contents = surface
                CATransaction.commit()
            }
        }
    }

    func clearFrame() {
        renderLock.lock()
        pendingIOSurface = nil
        isRenderScheduled = false
        renderLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.videoLayer.contents = nil
            CATransaction.commit()
        }
    }

    private func updateVideoLayerGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        videoLayer.position = center

        let isQuarterTurn = (abs(rotationDegrees) % 180) == 90
        if isQuarterTurn {
            videoLayer.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
        } else {
            videoLayer.bounds = bounds
        }

        let radians = -CGFloat(rotationDegrees) * .pi / 180.0
        var transform = CATransform3DMakeRotation(radians, 0, 0, 1)
        if isFlippedHorizontally {
            transform = CATransform3DScale(transform, -1.0, 1.0, 1.0)
        }
        videoLayer.transform = transform

        CATransaction.commit()
    }
}

struct VideoSurfaceRepresentable: NSViewRepresentable {
    let canvasView: VideoCanvasNSView
    let rotationDegrees: Int
    let isFlippedHorizontally: Bool
    let videoSize: CGSize

    func makeNSView(context: Context) -> VideoCanvasNSView {
        canvasView.updateTransform(
            rotation: rotationDegrees,
            flippedHorizontally: isFlippedHorizontally,
            aspectSize: videoSize
        )
        return canvasView
    }

    func updateNSView(_ nsView: VideoCanvasNSView, context: Context) {
        nsView.updateTransform(
            rotation: rotationDegrees,
            flippedHorizontally: isFlippedHorizontally,
            aspectSize: videoSize
        )
    }
}
