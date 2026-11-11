//
//  MeasuredBallPatches.swift
//  PerceptionKitTests
//
//  Numbers only, no images: the mean colour and neutral/chromatic pixel
//  fractions of every hand-labelled ball in the 2026-11-10 ball-detection
//  research, sampled the way BallPatchSampler samples (inset disc at 0.80
//  of the radius, specular pixels >= 0.97 dropped) from the labelled
//  centres. Two sets:
//
//  - `clips`: 9 frames from three web clips and one iPad still, 79 balls,
//    including 8 true eight-balls (black cloth is NOT in this set).
//  - `ipadSession`: 22 frames (every 8th) of recorded iPad session
//    device-20261111T021910Z, four static balls: red, orange, cue, and the
//    dark BLUE ball the app used to name the 8-ball. 88 balls.
//
//  Source of the labels: docs/research/ball-labels-2026-11-10.json and
//  docs/research/ball-labels-ipad-session.json on claude/research-ball-detection.
//

import CueSyncCore
import Foundation

@testable import PerceptionKit

struct MeasuredBall {
    let frame: String
    /// The hand label, e.g. "red", "maroon", "red-stripe", "black", "white".
    let label: String
    let isCue: Bool
    let patch: BallPatch

    init(_ frame: String, _ label: String, _ isCue: Bool,
         _ r: Double, _ g: Double, _ b: Double,
         _ whiteFraction: Double, _ chromaFraction: Double, _ samples: Int) {
        self.frame = frame
        self.label = label
        self.isCue = isCue
        self.patch = BallPatch(meanRGB: Vec3(r, g, b), whiteFraction: whiteFraction,
                               chromaFraction: chromaFraction, sampleCount: samples)
    }

    /// The colour family the label names, stripe or not.
    var family: ColorFamily? {
        ColorFamily(rawValue: label.replacingOccurrences(of: "-stripe", with: ""))
    }
}

extension MeasuredBall {
    /// Frames of one set, in order, each with its balls.
    static func frames(_ balls: [MeasuredBall]) -> [(id: String, balls: [MeasuredBall])] {
        var order: [String] = []
        var grouped: [String: [MeasuredBall]] = [:]
        for ball in balls {
            if grouped[ball.frame] == nil { order.append(ball.frame) }
            grouped[ball.frame, default: []].append(ball)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    static let clips: [MeasuredBall] = [
        .init("ipad-f1", "red", false, 0.6993, 0.2355, 0.2908, 0.000, 1.000, 539),
        .init("ipad-f1", "orange", false, 0.7616, 0.4114, 0.1618, 0.000, 1.000, 230),
        .init("ipad-f1", "white", true, 0.6739, 0.5464, 0.4789, 0.008, 0.965, 847),
        .init("ipad-f1", "blue", false, 0.2483, 0.2521, 0.3096, 0.327, 0.174, 961),
        .init("pub-f0005", "white", true, 0.6850, 0.8142, 0.5594, 0.000, 0.966, 116),
        .init("pub-f0005", "blue", false, 0.0828, 0.3090, 0.4769, 0.000, 0.984, 244),
        .init("pub-f0005", "red", false, 0.8584, 0.2809, 0.2261, 0.000, 1.000, 175),
        .init("pub-f0005", "black", false, 0.0943, 0.1299, 0.1015, 0.089, 0.008, 246),
        .init("pub-f0005", "maroon", false, 0.6192, 0.2585, 0.2445, 0.013, 0.978, 225),
        .init("pub-f0005", "yellow-stripe", false, 0.8783, 0.8048, 0.3064, 0.000, 1.000, 109),
        .init("pub-f0005", "orange-stripe", false, 0.8492, 0.4302, 0.1209, 0.000, 1.000, 216),
        .init("pub-f0030", "black", false, 0.0946, 0.1302, 0.1021, 0.089, 0.008, 246),
        .init("pub-f0030", "maroon", false, 0.6065, 0.2596, 0.2351, 0.013, 0.982, 226),
        .init("pub-f0030", "white", true, 0.7803, 0.8041, 0.5297, 0.000, 0.968, 126),
        .init("pub-f0030", "yellow-stripe", false, 0.8802, 0.8017, 0.2844, 0.000, 1.000, 118),
        .init("pub-f0030", "orange-stripe", false, 0.8467, 0.4249, 0.1261, 0.000, 1.000, 211),
        .init("pub-f0055", "white", true, 0.7352, 0.8302, 0.5385, 0.009, 0.991, 108),
        .init("pub-f0055", "black", false, 0.0885, 0.1270, 0.1075, 0.090, 0.012, 245),
        .init("pub-f0055", "yellow-stripe", false, 0.8744, 0.8109, 0.3198, 0.000, 1.000, 130),
        .init("speed-f0005", "red", false, 0.5968, 0.3662, 0.5049, 0.018, 0.982, 271),
        .init("speed-f0005", "yellow", false, 0.7008, 0.6034, 0.2825, 0.094, 0.808, 224),
        .init("speed-f0005", "yellow", false, 0.7709, 0.6711, 0.2844, 0.094, 0.890, 254),
        .init("speed-f0005", "red", false, 0.5767, 0.1974, 0.3620, 0.000, 0.960, 301),
        .init("speed-f0005", "white", true, 0.7389, 0.7549, 0.7392, 0.601, 0.276, 286),
        .init("speed-f0005", "red", false, 0.5726, 0.1948, 0.3182, 0.020, 0.980, 296),
        .init("speed-f0005", "yellow", false, 0.8307, 0.6481, 0.1706, 0.010, 0.990, 209),
        .init("speed-f0005", "red", false, 0.5351, 0.1663, 0.3043, 0.000, 0.901, 304),
        .init("speed-f0005", "yellow", false, 0.8262, 0.6427, 0.1421, 0.000, 1.000, 246),
        .init("speed-f0005", "black", false, 0.3284, 0.3563, 0.3821, 0.367, 0.208, 289),
        .init("speed-f0005", "yellow", false, 0.7896, 0.6088, 0.1504, 0.008, 0.992, 249),
        .init("speed-f0005", "red", false, 0.5603, 0.1681, 0.2949, 0.027, 0.910, 300),
        .init("speed-f0005", "yellow", false, 0.7750, 0.5683, 0.1231, 0.000, 1.000, 258),
        .init("speed-f0005", "yellow", false, 0.8444, 0.6725, 0.2316, 0.083, 0.887, 266),
        .init("speed-f0030", "yellow", false, 0.6901, 0.6135, 0.2871, 0.098, 0.865, 275),
        .init("speed-f0030", "white", true, 0.6495, 0.7115, 0.7407, 0.581, 0.393, 298),
        .init("speed-f0030", "yellow", false, 0.7950, 0.6666, 0.2284, 0.083, 0.917, 228),
        .init("speed-f0030", "red", false, 0.5976, 0.2236, 0.3618, 0.003, 0.974, 302),
        .init("speed-f0030", "yellow", false, 0.8527, 0.6808, 0.1792, 0.028, 0.972, 211),
        .init("speed-f0030", "red", false, 0.5719, 0.1737, 0.3148, 0.020, 0.887, 300),
        .init("speed-f0030", "yellow", false, 0.8180, 0.6433, 0.1407, 0.004, 0.996, 254),
        .init("speed-f0030", "yellow", false, 0.8225, 0.6462, 0.1360, 0.000, 1.000, 243),
        .init("speed-f0030", "red", false, 0.5502, 0.1742, 0.2898, 0.039, 0.895, 304),
        .init("speed-f0030", "black", false, 0.3245, 0.3621, 0.3859, 0.317, 0.307, 290),
        .init("speed-f0030", "yellow", false, 0.7678, 0.5752, 0.1218, 0.000, 1.000, 279),
        .init("speed-f0030", "yellow", false, 0.8359, 0.6274, 0.1277, 0.022, 0.978, 268),
        .init("speed-f0055", "yellow", false, 0.6913, 0.6155, 0.2804, 0.079, 0.906, 278),
        .init("speed-f0055", "yellow", false, 0.7951, 0.6717, 0.2260, 0.081, 0.906, 235),
        .init("speed-f0055", "yellow", false, 0.8480, 0.6845, 0.2086, 0.062, 0.929, 225),
        .init("speed-f0055", "red", false, 0.5765, 0.1741, 0.3171, 0.030, 0.931, 303),
        .init("speed-f0055", "white", true, 0.7336, 0.7528, 0.7383, 0.697, 0.197, 304),
        .init("speed-f0055", "yellow", false, 0.7909, 0.6156, 0.1047, 0.000, 1.000, 275),
        .init("speed-f0055", "yellow", false, 0.8270, 0.6399, 0.1354, 0.000, 1.000, 254),
        .init("speed-f0055", "black", false, 0.3277, 0.3565, 0.3809, 0.323, 0.288, 288),
        .init("speed-f0055", "yellow", false, 0.7649, 0.5729, 0.1269, 0.000, 1.000, 281),
        .init("speed-f0055", "yellow", false, 0.8386, 0.6278, 0.1210, 0.022, 0.978, 274),
        .init("home-f0030", "red", false, 0.7691, 0.2705, 0.2923, 0.000, 0.991, 221),
        .init("home-f0030", "purple-stripe", false, 0.6342, 0.5386, 0.5696, 0.151, 0.663, 279),
        .init("home-f0030", "green", false, 0.4200, 0.6581, 0.5039, 0.000, 0.993, 276),
        .init("home-f0030", "orange-stripe", false, 0.7291, 0.4986, 0.2931, 0.000, 1.000, 232),
        .init("home-f0030", "white", true, 0.8586, 0.7728, 0.6210, 0.000, 1.000, 243),
        .init("home-f0030", "yellow", false, 0.7434, 0.6102, 0.4070, 0.000, 1.000, 284),
        .init("home-f0030", "red-stripe", false, 0.6503, 0.3965, 0.3670, 0.034, 0.888, 232),
        .init("home-f0030", "black", false, 0.2661, 0.2426, 0.2120, 0.220, 0.108, 277),
        .init("home-f0030", "orange", false, 0.7911, 0.4937, 0.0565, 0.000, 1.000, 202),
        .init("home-f0030", "blue", false, 0.2030, 0.3606, 0.5161, 0.066, 0.863, 271),
        .init("home-f0030", "maroon", false, 0.6107, 0.1088, 0.1714, 0.026, 0.956, 271),
        .init("home-f0030", "purple", false, 0.3607, 0.2986, 0.3890, 0.411, 0.414, 280),
        .init("home-f0030", "green-stripe", false, 0.1397, 0.2438, 0.2294, 0.093, 0.396, 280),
        .init("home-f0055", "red", false, 0.7770, 0.2719, 0.2907, 0.000, 0.996, 227),
        .init("home-f0055", "purple-stripe", false, 0.6306, 0.5370, 0.5646, 0.165, 0.652, 279),
        .init("home-f0055", "green", false, 0.4161, 0.6524, 0.4967, 0.000, 0.982, 276),
        .init("home-f0055", "orange-stripe", false, 0.7259, 0.5019, 0.2983, 0.000, 1.000, 236),
        .init("home-f0055", "black", false, 0.2621, 0.2380, 0.2118, 0.202, 0.097, 277),
        .init("home-f0055", "orange", false, 0.8123, 0.5052, 0.0481, 0.000, 1.000, 233),
        .init("home-f0055", "blue", false, 0.1942, 0.3511, 0.5070, 0.074, 0.878, 270),
        .init("home-f0055", "purple", false, 0.3527, 0.2916, 0.3786, 0.294, 0.416, 279),
        .init("home-f0055", "green-stripe", false, 0.1383, 0.2424, 0.2254, 0.106, 0.390, 282),
        .init("home-f0055", "white", true, 0.7623, 0.7345, 0.6330, 0.311, 0.512, 283),
        .init("home-f0055", "red-stripe", false, 0.3680, 0.1702, 0.1935, 0.088, 0.566, 274),
    ]

    static let ipadSession: [MeasuredBall] = [
        .init("sess-f001", "red", false, 0.6687, 0.2032, 0.2651, 0.000, 1.000, 234),
        .init("sess-f001", "orange", false, 0.7454, 0.4203, 0.1660, 0.000, 1.000, 115),
        .init("sess-f001", "white", true, 0.6476, 0.5349, 0.4638, 0.041, 0.871, 410),
        .init("sess-f001", "blue", false, 0.2491, 0.2417, 0.2878, 0.454, 0.000, 427),
        .init("sess-f002", "red", false, 0.6756, 0.1978, 0.2506, 0.000, 1.000, 237),
        .init("sess-f002", "orange", false, 0.7459, 0.4077, 0.1566, 0.000, 1.000, 111),
        .init("sess-f002", "white", true, 0.6569, 0.5356, 0.4628, 0.024, 0.968, 412),
        .init("sess-f002", "blue", false, 0.2266, 0.2400, 0.2994, 0.279, 0.141, 426),
        .init("sess-f003", "red", false, 0.6685, 0.2068, 0.2571, 0.000, 1.000, 240),
        .init("sess-f003", "orange", false, 0.7351, 0.4080, 0.1631, 0.000, 1.000, 109),
        .init("sess-f003", "white", true, 0.6560, 0.5386, 0.4619, 0.024, 0.904, 415),
        .init("sess-f003", "blue", false, 0.2347, 0.2414, 0.2863, 0.275, 0.146, 426),
        .init("sess-f004", "red", false, 0.6636, 0.2113, 0.2588, 0.000, 1.000, 238),
        .init("sess-f004", "orange", false, 0.7502, 0.4135, 0.1773, 0.000, 1.000, 115),
        .init("sess-f004", "white", true, 0.6542, 0.5359, 0.4664, 0.087, 0.903, 412),
        .init("sess-f004", "blue", false, 0.2388, 0.2430, 0.2851, 0.328, 0.119, 427),
        .init("sess-f005", "red", false, 0.6658, 0.2029, 0.2512, 0.000, 1.000, 236),
        .init("sess-f005", "orange", false, 0.7336, 0.4064, 0.1547, 0.000, 1.000, 109),
        .init("sess-f005", "white", true, 0.6525, 0.5314, 0.4600, 0.025, 0.919, 408),
        .init("sess-f005", "blue", false, 0.2356, 0.2331, 0.2879, 0.299, 0.148, 425),
        .init("sess-f006", "red", false, 0.6665, 0.2000, 0.2398, 0.000, 1.000, 233),
        .init("sess-f006", "orange", false, 0.7570, 0.4160, 0.1657, 0.000, 1.000, 116),
        .init("sess-f006", "white", true, 0.6494, 0.5292, 0.4589, 0.042, 0.875, 409),
        .init("sess-f006", "blue", false, 0.2321, 0.2353, 0.2902, 0.247, 0.200, 425),
        .init("sess-f007", "red", false, 0.6774, 0.2110, 0.2686, 0.000, 1.000, 239),
        .init("sess-f007", "orange", false, 0.7482, 0.4048, 0.1747, 0.000, 1.000, 113),
        .init("sess-f007", "white", true, 0.6581, 0.5337, 0.4597, 0.024, 0.959, 413),
        .init("sess-f007", "blue", false, 0.2421, 0.2437, 0.2996, 0.287, 0.098, 428),
        .init("sess-f008", "red", false, 0.6639, 0.2007, 0.2527, 0.000, 1.000, 236),
        .init("sess-f008", "orange", false, 0.7439, 0.4079, 0.1625, 0.000, 1.000, 112),
        .init("sess-f008", "white", true, 0.6551, 0.5307, 0.4571, 0.024, 0.902, 410),
        .init("sess-f008", "blue", false, 0.2382, 0.2402, 0.2960, 0.288, 0.159, 427),
        .init("sess-f009", "red", false, 0.6846, 0.1957, 0.2552, 0.000, 1.000, 239),
        .init("sess-f009", "orange", false, 0.7509, 0.4142, 0.1670, 0.000, 1.000, 116),
        .init("sess-f009", "white", true, 0.6526, 0.5326, 0.4551, 0.025, 0.895, 408),
        .init("sess-f009", "blue", false, 0.2464, 0.2368, 0.3006, 0.375, 0.075, 427),
        .init("sess-f010", "red", false, 0.6693, 0.1986, 0.2684, 0.000, 1.000, 236),
        .init("sess-f010", "orange", false, 0.7445, 0.4079, 0.1626, 0.000, 1.000, 113),
        .init("sess-f010", "white", true, 0.6570, 0.5367, 0.4579, 0.024, 0.904, 416),
        .init("sess-f010", "blue", false, 0.2342, 0.2411, 0.2869, 0.313, 0.118, 425),
        .init("sess-f011", "red", false, 0.6713, 0.1984, 0.2493, 0.000, 1.000, 237),
        .init("sess-f011", "orange", false, 0.7568, 0.4198, 0.1594, 0.000, 1.000, 116),
        .init("sess-f011", "white", true, 0.6509, 0.5322, 0.4543, 0.022, 0.944, 408),
        .init("sess-f011", "blue", false, 0.2388, 0.2379, 0.2855, 0.384, 0.054, 425),
        .init("sess-f012", "red", false, 0.6680, 0.1954, 0.2694, 0.000, 1.000, 234),
        .init("sess-f012", "orange", false, 0.7429, 0.4064, 0.1579, 0.000, 1.000, 111),
        .init("sess-f012", "white", true, 0.6513, 0.5357, 0.4569, 0.024, 0.903, 411),
        .init("sess-f012", "blue", false, 0.2424, 0.2354, 0.2934, 0.312, 0.124, 426),
        .init("sess-f013", "red", false, 0.6617, 0.2012, 0.2558, 0.000, 1.000, 235),
        .init("sess-f013", "orange", false, 0.7379, 0.4062, 0.1653, 0.000, 1.000, 110),
        .init("sess-f013", "white", true, 0.6534, 0.5305, 0.4617, 0.024, 0.912, 410),
        .init("sess-f013", "blue", false, 0.2323, 0.2410, 0.2916, 0.289, 0.158, 425),
        .init("sess-f014", "red", false, 0.6727, 0.1936, 0.2443, 0.000, 1.000, 237),
        .init("sess-f014", "orange", false, 0.7368, 0.4052, 0.1665, 0.000, 1.000, 111),
        .init("sess-f014", "white", true, 0.6590, 0.5380, 0.4668, 0.050, 0.887, 417),
        .init("sess-f014", "blue", false, 0.2352, 0.2351, 0.2885, 0.306, 0.118, 425),
        .init("sess-f015", "red", false, 0.6673, 0.2010, 0.2465, 0.000, 1.000, 236),
        .init("sess-f015", "orange", false, 0.7339, 0.3991, 0.1646, 0.000, 1.000, 109),
        .init("sess-f015", "white", true, 0.6615, 0.5386, 0.4677, 0.031, 0.923, 418),
        .init("sess-f015", "blue", false, 0.2405, 0.2349, 0.3005, 0.325, 0.127, 425),
        .init("sess-f016", "red", false, 0.6687, 0.2075, 0.2561, 0.000, 1.000, 240),
        .init("sess-f016", "orange", false, 0.7320, 0.4076, 0.1532, 0.000, 1.000, 112),
        .init("sess-f016", "white", true, 0.6579, 0.5355, 0.4629, 0.022, 0.959, 416),
        .init("sess-f016", "blue", false, 0.2430, 0.2337, 0.2802, 0.374, 0.061, 425),
        .init("sess-f017", "red", false, 0.6824, 0.2048, 0.2623, 0.000, 1.000, 243),
        .init("sess-f017", "orange", false, 0.7465, 0.4109, 0.1632, 0.000, 1.000, 115),
        .init("sess-f017", "white", true, 0.6573, 0.5356, 0.4665, 0.024, 0.892, 416),
        .init("sess-f017", "blue", false, 0.2360, 0.2364, 0.2919, 0.270, 0.164, 426),
        .init("sess-f018", "red", false, 0.6634, 0.2118, 0.2459, 0.000, 1.000, 238),
        .init("sess-f018", "orange", false, 0.7382, 0.4089, 0.1652, 0.000, 1.000, 114),
        .init("sess-f018", "white", true, 0.6608, 0.5358, 0.4681, 0.032, 0.903, 412),
        .init("sess-f018", "blue", false, 0.2402, 0.2384, 0.2895, 0.371, 0.103, 426),
        .init("sess-f019", "red", false, 0.6762, 0.2063, 0.2589, 0.000, 1.000, 244),
        .init("sess-f019", "orange", false, 0.7435, 0.4143, 0.1758, 0.000, 1.000, 115),
        .init("sess-f019", "white", true, 0.6539, 0.5341, 0.4546, 0.024, 0.969, 413),
        .init("sess-f019", "blue", false, 0.2331, 0.2372, 0.2877, 0.367, 0.061, 425),
        .init("sess-f020", "red", false, 0.6704, 0.2066, 0.2560, 0.000, 1.000, 239),
        .init("sess-f020", "orange", false, 0.7399, 0.4182, 0.1506, 0.000, 1.000, 116),
        .init("sess-f020", "white", true, 0.6480, 0.5290, 0.4521, 0.025, 0.921, 405),
        .init("sess-f020", "blue", false, 0.2305, 0.2364, 0.2912, 0.332, 0.134, 425),
        .init("sess-f021", "red", false, 0.6737, 0.2072, 0.2691, 0.000, 1.000, 243),
        .init("sess-f021", "orange", false, 0.7332, 0.4097, 0.1655, 0.000, 1.000, 112),
        .init("sess-f021", "white", true, 0.6487, 0.5335, 0.4643, 0.098, 0.895, 410),
        .init("sess-f021", "blue", false, 0.2435, 0.2350, 0.2840, 0.339, 0.073, 425),
        .init("sess-f022", "red", false, 0.6748, 0.2129, 0.2508, 0.000, 1.000, 244),
        .init("sess-f022", "orange", false, 0.7392, 0.4009, 0.1656, 0.000, 1.000, 112),
        .init("sess-f022", "white", true, 0.6468, 0.5309, 0.4551, 0.032, 0.901, 405),
        .init("sess-f022", "blue", false, 0.2356, 0.2346, 0.3083, 0.296, 0.184, 425),
    ]
}
