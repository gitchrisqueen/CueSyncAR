//
//  SessionPresetTests.swift
//  CueSync AR
//

import Testing
@testable import CoachKit

@Suite("Session presets")
struct SessionPresetTests {

    @Test("A game with friends draws no aim lines")
    func gameTurnsGuidesOff() {
        // The owner's ruling, and the whole reason the preset layer exists:
        // every PracticeMode sets showsShotGuides true, so without this the
        // flag has no consumer that ever reads false.
        #expect(!SessionPreset.withFriends.configuration.showsShotGuides)
        #expect(SessionPreset.solo.configuration.showsShotGuides)
        #expect(SessionPreset.tv.configuration.showsShotGuides)
    }

    @Test("The game preset still keeps score")
    func gameStillTracksTheCalledPocket() {
        // "Guides off" must not mean "the app does nothing" — it is the
        // scoring posture, not an off switch.
        #expect(SessionPreset.withFriends.configuration.requiresCalledPocket)
    }

    @Test("Parked is about where the phone is, not what it draws")
    func parkedFollowsPosture() {
        #expect(!SessionPreset.solo.deviceParked)
        #expect(SessionPreset.withFriends.deviceParked)
        #expect(SessionPreset.tv.deviceParked)
    }

    @Test("Only the TV preset wants a second scene")
    func externalScene() {
        #expect(SessionPreset.tv.wantsExternalScene)
        #expect(!SessionPreset.solo.wantsExternalScene)
        #expect(!SessionPreset.withFriends.wantsExternalScene)
    }

    @Test("Every preset round-trips through its stored value")
    func codable() {
        for preset in SessionPreset.allCases {
            #expect(SessionPreset(rawValue: preset.rawValue) == preset)
        }
        // Stable raw values: these are persisted, so a rename would
        // silently reset everyone's choice.
        #expect(SessionPreset.allCases.map(\.rawValue) == ["solo", "withFriends", "tv"])
    }

    @Test("Every preset says what it is and what it changes, in plain words")
    func copyIsForPlayers() {
        for preset in SessionPreset.allCases {
            #expect(!preset.title.isEmpty)
            #expect(preset.detail.count > 20, "\(preset) has no real explanation")
            for jargon in ["ModeConfiguration", "devicePose", "showsShotGuides", "nil"] {
                #expect(!preset.detail.contains(jargon), "\(preset.detail) leaks \(jargon)")
            }
        }
    }

    @Test("The preset selects a practice mode rather than replacing it")
    func presetsMapToModes() {
        #expect(SessionPreset.solo.practiceMode == .freePlay)
        #expect(SessionPreset.withFriends.practiceMode == .calledShots)
        #expect(SessionPreset.tv.practiceMode == .freePlay)
    }
}
