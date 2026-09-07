//
//  PlaneRaycastingDispatchTests.swift
//  PerceptionKitTests
//
//  Guards the height-aware raycast against silently reverting to the
//  cloth-plane fallback. The pipeline holds its raycaster as
//  `any PlaneRaycasting`; if the three-argument overload is only a protocol
//  EXTENSION method it binds statically to the fallback, the sphere-centre
//  lift never engages, and every ball projects r / tan(elevation) long.
//

import Testing
import CueSyncCore
@testable import PerceptionKit

/// A raycaster whose two forms return deliberately different answers, so a
/// test can tell which one a call actually reached.
private struct DispatchProbeRaycaster: PlaneRaycasting {
    static let clothAnswer = Vec3(1, 0, 0)
    static let liftedAnswer = Vec3(2, 0, 0)

    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame) -> Vec3? {
        Self.clothAnswer
    }

    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame,
                             planeHeightOffset: Double) -> Vec3? {
        Self.liftedAnswer
    }
}

/// A raycaster that implements only the required two-argument form, to prove
/// the extension default still covers implementations without the capability.
private struct ClothOnlyRaycaster: PlaneRaycasting {
    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame) -> Vec3? {
        DispatchProbeRaycaster.clothAnswer
    }
}

@Suite struct PlaneRaycastingDispatchTests {
    private var frame: CapturedFrame {
        CapturedFrame(timestamp: 0, cameraTransform: .identity)
    }

    /// The failing case before the fix: through the existential the call bound
    /// to the extension, which discards the offset and forwards to the cloth
    /// raycast, so this returned `clothAnswer`.
    @Test func heightAwareRaycastDispatchesThroughTheExistential() {
        let raycaster: any PlaneRaycasting = DispatchProbeRaycaster()
        let hit = raycaster.raycastToTablePlane(imagePoint: Vec2(0.5, 0.5),
                                                frame: frame,
                                                planeHeightOffset: 0.028575)
        #expect(hit == DispatchProbeRaycaster.liftedAnswer,
                "the lifted implementation must be reached through `any PlaneRaycasting`")
    }

    /// Concrete-typed calls always bound correctly; kept so a regression that
    /// only breaks the existential path is still distinguishable.
    @Test func heightAwareRaycastDispatchesOnTheConcreteType() {
        let raycaster = DispatchProbeRaycaster()
        #expect(raycaster.raycastToTablePlane(imagePoint: Vec2(0.5, 0.5),
                                              frame: frame,
                                              planeHeightOffset: 0.028575)
                == DispatchProbeRaycaster.liftedAnswer)
    }

    /// The extension default must survive as a fallback: an implementation
    /// that cannot lift its plane still answers with the cloth hit.
    @Test func implementationsWithoutTheCapabilityFallBackToTheClothPlane() {
        let raycaster: any PlaneRaycasting = ClothOnlyRaycaster()
        #expect(raycaster.raycastToTablePlane(imagePoint: Vec2(0.5, 0.5),
                                              frame: frame,
                                              planeHeightOffset: 0.028575)
                == DispatchProbeRaycaster.clothAnswer)
    }
}
