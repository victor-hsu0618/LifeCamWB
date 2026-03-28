import SwiftUI
import AVFoundation
import AppKit

/// NSView that hosts an AVCaptureVideoPreviewLayer and resizes it automatically.
final class PreviewView: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let layer = previewLayer {
                wantsLayer = true
                self.layer?.addSublayer(layer)
                layer.frame = bounds
            }
        }
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        fixRotation()
    }

    private func fixRotation() {
        guard let conn = previewLayer?.connection else { return }
        if #available(macOS 14.0, *) {
            if conn.isVideoRotationAngleSupported(0) {
                conn.videoRotationAngle = 0
            } else if conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
        } else {
            conn.videoOrientation = .landscapeRight
        }
    }
}

/// SwiftUI wrapper for the preview view.
struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer?

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.previewLayer = layer
    }
}
