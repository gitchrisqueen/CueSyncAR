//
//  MirrorUISnapshot.swift
//  CueSync AR
//
//  Backs `GET /ui.jpg` on the debug mirror: the app's whole window as the
//  player sees it, SwiftUI HUD included. `/frame.jpg` is an ARView snapshot
//  (camera + RealityKit overlays, no SwiftUI), so until now nothing could show
//  the HUD, the calibration screens or the sheets of a device nobody is
//  standing next to. The camera layer may render black here (Metal-backed
//  ARView); pair it with `/frame.jpg` for the full picture.
//
//  Rendering costs a few ms on the main thread, so it only happens while a
//  client has asked for `/ui.jpg` in the last 15 s (see
//  `DebugMirrorServer.wantsUISnapshot`), and at most once a second
//  (`MirrorPacing`). Only the drawing has to be on the main actor; the JPEG
//  encode of a window-sized image is done off it.
//

import Foundation

#if canImport(UIKit)
import UIKit

enum MirrorUISnapshot {
    /// JPEG of the foreground window, or nil when there is no window yet.
    @MainActor
    static func jpeg() -> Data? {
        image()?.jpegData(compressionQuality: 0.8)
    }

    /// The window drawn into an image. This is the part that must run on the
    /// main actor.
    @MainActor
    static func image() -> UIImage? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.keyWindow ?? scene?.windows.first else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    /// Draw on the main actor, encode on a utility queue, so the encode does
    /// not hold up the overlay.
    @MainActor
    static func jpegEncodedOffMain() async -> Data? {
        guard let rendered = image() else { return nil }
        nonisolated(unsafe) let handoff = rendered
        return await Task.detached(priority: .utility) {
            handoff.jpegData(compressionQuality: 0.8)
        }.value
    }
}
#else
enum MirrorUISnapshot {
    @MainActor
    static func jpeg() -> Data? { nil }

    @MainActor
    static func jpegEncodedOffMain() async -> Data? { nil }
}
#endif
