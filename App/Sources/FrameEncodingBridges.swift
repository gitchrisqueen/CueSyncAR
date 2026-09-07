//
//  FrameEncodingBridges.swift
//  CueSync AR
//
//  Frame-encoding glue that used to sit at the foot of SessionModel.swift:
//  the non-Apple-platform stub encoder and the bridge that lets
//  DetectionRoboflow's JPEG encoder read PerceptionKit's frame image.
//  Split out to keep SessionModel.swift under SwiftLint's file_length
//  ceiling; no behavior change.
//

import CueSyncCore
import DetectionRoboflow
import Foundation

#if !canImport(CoreImage)
struct UnsupportedEncoder: FrameJPEGEncoding {
    func encodeJPEG(from frame: CapturedFrame) throws -> (data: Data, width: Int, height: Int) {
        throw RoboflowError.frameNotEncodable
    }
}
#endif

#if canImport(CoreVideo)
import CoreVideo
import PerceptionKit

// Bridge PerceptionKit's frame image type to DetectionRoboflow's encoder seam.
extension PixelBufferImage: @retroactive DetectionRoboflow.PixelBufferProviding {
    public var cvPixelBuffer: CVPixelBuffer { pixelBuffer }
}
#endif
