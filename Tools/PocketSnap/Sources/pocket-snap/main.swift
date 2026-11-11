//
//  main.swift
//  CueSync AR
//
//  pocket-snap <frame.gray> <width> <height> <scale> <pocket:x:y>...
//
//  Refines rough pocket picks against a raw 8-bit grayscale frame with
//  TableSpace.PocketSnap and prints one `pocket:x:y method shift` line per
//  pocket. Picks and output are in VIEW points; `scale` is image pixels per
//  view point (2 for a debug-mirror frame of an iPad). Make the frame with
//  `ffmpeg -i frame.jpg -vf format=gray -f rawvideo frame.gray`.
//

import CueSyncCore
import Foundation
import TableSpace

let arguments = CommandLine.arguments
guard arguments.count >= 6,
      let width = Int(arguments[2]), let height = Int(arguments[3]),
      let scale = Double(arguments[4]), scale > 0 else {
    FileHandle.standardError.write(Data(
        "usage: pocket-snap <frame.gray> <width> <height> <scale> <pocket:x:y>...\n".utf8))
    exit(2)
}
guard let data = FileManager.default.contents(atPath: arguments[1]),
      let image = LumaImage(width: width, height: height, pixels: [UInt8](data)) else {
    FileHandle.standardError.write(Data("cannot read a \(width)x\(height) gray frame\n".utf8))
    exit(1)
}
var taps: [PocketID: Vec2] = [:]
for argument in arguments.dropFirst(5) {
    let parts = argument.split(separator: ":")
    guard parts.count == 3, let pocket = PocketID(rawValue: String(parts[0])),
          let x = Double(parts[1]), let y = Double(parts[2]) else {
        FileHandle.standardError.write(Data("bad pick \(argument)\n".utf8))
        exit(2)
    }
    taps[pocket] = Vec2(x * scale, y * scale)
}
if ProcessInfo.processInfo.environment["POCKET_SNAP_LINES"] != nil {
    func describe(_ line: PocketSnap.Line?) -> String {
        guard let line else { return "none" }
        return String(format: "rms %.2f px, %d inliers, through %.1f,%.1f dir %.3f,%.3f", line.rms,
                      line.inliers, line.point.x, line.point.y, line.direction.x, line.direction.y)
    }
    for (index, pair) in PocketSnap.sideLines(image, taps: taps).enumerated() {
        print("side \(index): rail \(describe(pair.rail)); nose \(describe(pair.nose))")
    }
}
// POCKET_SNAP_BALLS="x:y:r;x:y:r" (view points): size check with the balls
// as a ruler across the table (TableSpace.TableSizeFromImage).
if let spec = ProcessInfo.processInfo.environment["POCKET_SNAP_BALLS"] {
    let balls = spec.split(separator: ";").compactMap { entry -> TableSizeFromImage.Ball? in
        let v = entry.split(separator: ":").compactMap { Double($0) }
        guard v.count == 3 else { return nil }
        return TableSizeFromImage.Ball(centre: Vec2(v[0] * scale, v[1] * scale), radius: v[2] * scale)
    }
    let lines = PocketSnap.sideLines(image, taps: taps)
    let across = lines[1].nose?.direction ?? lines[3].rail?.direction ?? Vec2(1, 0)
    for ball in balls {
        let width = TableSizeFromImage.ballWidth(image, centre: ball.centre, radius: ball.radius, along: across)
        print(String(format: "ball at %.0f,%.0f: %@ px", ball.centre.x, ball.centre.y,
                     width.map { String(format: "%.2f", $0) } ?? "none"))
    }
    if let left = lines[0].nose, let right = lines[2].nose,
       let estimate = TableSizeFromImage.estimate(image, leftNose: left, rightNose: right,
                                                  across: across, balls: balls) {
        print(estimate.summary)
    } else {
        print("size: no estimate")
    }
}
let results = PocketSnap.refine(image, taps: taps)
for pocket in PocketID.allCases {
    guard let result = results[pocket] else { continue }
    print(String(format: "%@:%.1f:%.1f %@ %.1f", pocket.rawValue, result.point.x / scale,
                 result.point.y / scale, result.method.rawValue, result.shift / scale))
}
