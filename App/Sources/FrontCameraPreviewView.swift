//
//  FrontCameraPreviewView.swift
//  CueSync AR
//
//  Detection-preview-only FRONT camera mode (M2-01 evaluation): a plain
//  AVCapture session with a preview layer, forwarding throttled, deep-
//  copied frames into the same SessionModel preview loop the AR path uses.
//  No ARKit here — world tracking is back-camera only, so calibration and
//  live tracking are unavailable in this mode by design.
//

import CueSyncCore
import SwiftUI

#if canImport(AVFoundation) && !targetEnvironment(simulator)
import ARExperience
import AVFoundation
import PerceptionKit

struct FrontCameraPreviewView: UIViewRepresentable {
    @Environment(SessionModel.self) private var model

    func makeUIView(context: Context) -> FrontCameraCaptureView {
        let view = FrontCameraCaptureView()
        let modelRef = model
        view.onFrame = { frame in
            Task { @MainActor in
                modelRef.ingestPreviewFrame(frame)
            }
        }
        view.start()
        return view
    }

    func updateUIView(_ uiView: FrontCameraCaptureView, context: Context) {}

    static func dismantleUIView(_ uiView: FrontCameraCaptureView, coordinator: ()) {
        uiView.stop()
    }
}

final class FrontCameraCaptureView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cuesync.frontCamera")
    private let delegateProxy = FrameForwarder()

    /// Called off-main with a throttled, pool-decoupled frame.
    var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { delegateProxy.onFrame }
        set { delegateProxy.onFrame = newValue }
    }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    func start() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        sessionQueue.async { [session, delegateProxy] in
            guard session.inputs.isEmpty,
                  let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(delegateProxy,
                                           queue: DispatchQueue(label: "cuesync.frontFrames"))
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            session.stopRunning()
        }
    }
}

/// Sample-buffer delegate: throttles to the preview cadence and hands out a
/// DEEP COPY of each forwarded pixel buffer, so nothing downstream can pin
/// AVCapture's pool across the hosted-API round trip (same discipline as
/// the ARKit path).
private final class FrameForwarder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                    @unchecked Sendable {
    var onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var lastForwardedAt: TimeInterval = 0
    /// Forward at ~4 Hz; SessionModel applies its own 0.5 s throttle.
    private let minimumInterval: TimeInterval = 0.25

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp - lastForwardedAt >= minimumInterval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let copy = ARSessionCoordinator.copyPixelBuffer(buffer) else { return }
        lastForwardedAt = timestamp
        // Identity transform = "no pose" — SessionModel skips the motion
        // gate for poseless sources.
        onFrame?(CapturedFrame(timestamp: timestamp,
                               cameraTransform: .identity,
                               image: PixelBufferImage(pixelBuffer: copy)))
    }
}
#endif
