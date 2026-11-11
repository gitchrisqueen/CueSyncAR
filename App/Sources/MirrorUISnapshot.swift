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
//  `DebugMirrorServer.wantsUISnapshot`).
//

import Foundation

#if canImport(UIKit)
import UIKit

enum MirrorUISnapshot {
    /// JPEG of the foreground window, or nil when there is no window yet.
    @MainActor
    static func jpeg() -> Data? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.keyWindow ?? scene?.windows.first else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}
#else
enum MirrorUISnapshot {
    @MainActor
    static func jpeg() -> Data? { nil }
}
#endif
