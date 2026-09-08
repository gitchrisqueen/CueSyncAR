import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("SettingsModel")
struct SettingsModelTests {
    // MARK: Defaults

    @Test func freshInstallUsesTheDocumentedDefaults() {
        let settings = SettingsModel()
        #expect(settings.tableSize == .useMeasured)
        #expect(settings.detectionProvider == .onDevice)
        #expect(settings.guideSpeed == SettingsModel.defaultGuideSpeed)
        // The device sits at the table out of reach — the mirror is ON
        // unless the owner turned it off.
        #expect(settings.debugMirrorEnabled)
        #expect(settings.practiceMode == .freePlay)
        #expect(settings.visibleMissGrace == SettingsModel.defaultVisibleMissGrace)
        // The Neural Engine probe decides by itself unless the owner pins.
        #expect(settings.detectorPinnedToCPU == false)
    }

    @Test func loadingAnEmptyStoreYieldsTheDefaults() {
        #expect(SettingsModel(loading: InMemorySettingsStore()) == SettingsModel())
    }

    // MARK: Round trip (write → fresh instance → read back)

    @Test func everySettingRoundTripsThroughAnInMemoryStore() {
        let store = InMemorySettingsStore()
        var written = SettingsModel()
        written.tableSize = .standard(.eightFoot)
        written.detectionProvider = .hosted
        written.guideSpeed = 5.25
        written.debugMirrorEnabled = false
        written.practiceMode = .calledShots
        written.visibleMissGrace = 1.5
        written.detectorPinnedToCPU = true
        written.persist(to: store)

        let reloaded = SettingsModel(loading: store)
        #expect(reloaded.tableSize == .standard(.eightFoot))
        #expect(reloaded.detectionProvider == .hosted)
        #expect(reloaded.guideSpeed == 5.25)
        #expect(reloaded.debugMirrorEnabled == false)
        #expect(reloaded.practiceMode == .calledShots)
        #expect(reloaded.visibleMissGrace == 1.5)
        #expect(reloaded.detectorPinnedToCPU)
        #expect(reloaded == written)
    }

    @Test func everySettingRoundTripsThroughUserDefaults() throws {
        let suite = "cuesync.settings.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)

        var written = SettingsModel()
        written.tableSize = .standard(.nineFoot)
        written.detectionProvider = .hosted
        written.guideSpeed = 2.5
        written.debugMirrorEnabled = false
        written.practiceMode = .guidedDrill
        written.visibleMissGrace = 0.4
        written.detectorPinnedToCPU = true
        written.persist(to: store)

        // A brand-new store instance over the same defaults — the app's
        // "relaunch and the setting is still there" path.
        let reloaded = SettingsModel(loading: UserDefaultsSettingsStore(defaults: defaults))
        #expect(reloaded == written)
    }

    @Test func customTableSizesRoundTrip() {
        let store = InMemorySettingsStore()
        var written = SettingsModel()
        written.tableSize = .standard(.custom(width: 2.13, height: 1.07))
        written.persist(to: store)
        #expect(SettingsModel(loading: store).tableSize
                == .standard(.custom(width: 2.13, height: 1.07)))
    }

    @Test func booleanRoundTripsAsABooleanNotANumber() {
        // Regression guard: UserDefaults bridges through NSNumber, so a
        // guide speed of 1.0 must never read back as `true` (and vice
        // versa) — the typed store accessors exist for this.
        let store = InMemorySettingsStore()
        var written = SettingsModel()
        written.guideSpeed = 1.0
        written.debugMirrorEnabled = true
        written.persist(to: store)
        let reloaded = SettingsModel(loading: store)
        #expect(reloaded.guideSpeed == 1.0)
        #expect(reloaded.debugMirrorEnabled)
    }

    // MARK: Validation

    @Test func guideSpeedClampsToTheSupportedRange() {
        var settings = SettingsModel()
        settings.guideSpeed = 99
        #expect(settings.guideSpeed == SettingsModel.guideSpeedRange.upperBound)
        settings.guideSpeed = -3
        #expect(settings.guideSpeed == SettingsModel.guideSpeedRange.lowerBound)
        settings.guideSpeed = .nan
        #expect(settings.guideSpeed == SettingsModel.defaultGuideSpeed)
        settings.guideSpeed = .infinity
        #expect(settings.guideSpeed == SettingsModel.defaultGuideSpeed)
    }

    @Test func visibleMissGraceClampsToTheSupportedRange() {
        var settings = SettingsModel()
        settings.visibleMissGrace = 0
        #expect(settings.visibleMissGrace == SettingsModel.visibleMissGraceRange.lowerBound)
        settings.visibleMissGrace = 60
        #expect(settings.visibleMissGrace == SettingsModel.visibleMissGraceRange.upperBound)
        settings.visibleMissGrace = .nan
        #expect(settings.visibleMissGrace == SettingsModel.defaultVisibleMissGrace)
    }

    @Test func outOfRangeStoredNumbersClampOnLoad() {
        let store = InMemorySettingsStore(storage: [
            SettingsKey.guideSpeed: .double(1000),
            SettingsKey.visibleMissGrace: .double(-5)
        ])
        let settings = SettingsModel(loading: store)
        #expect(settings.guideSpeed == SettingsModel.guideSpeedRange.upperBound)
        #expect(settings.visibleMissGrace == SettingsModel.visibleMissGraceRange.lowerBound)
    }

    // MARK: Corrupt / partial stores

    @Test func aPartiallyWrittenStoreKeepsWhatIsValidAndDefaultsTheRest() {
        let store = InMemorySettingsStore(storage: [
            SettingsKey.practiceMode: .string("calledShots"),
            SettingsKey.guideSpeed: .double(6.0)
        ])
        let settings = SettingsModel(loading: store)
        #expect(settings.practiceMode == .calledShots)
        #expect(settings.guideSpeed == 6.0)
        // Untouched keys fall back to their defaults, not to zero/false.
        #expect(settings.tableSize == .useMeasured)
        #expect(settings.detectionProvider == .onDevice)
        #expect(settings.debugMirrorEnabled)
        #expect(settings.visibleMissGrace == SettingsModel.defaultVisibleMissGrace)
        #expect(settings.detectorPinnedToCPU == false)
    }

    @Test func corruptValuesFallBackToDefaultsWithoutLosingValidNeighbors() {
        let store = InMemorySettingsStore(storage: [
            SettingsKey.tableSize: .string("twelveFoot"),          // unknown case
            SettingsKey.detectionProvider: .double(3),             // wrong type
            SettingsKey.guideSpeed: .string("fast"),               // wrong type
            SettingsKey.debugMirrorEnabled: .string("yes"),        // wrong type
            SettingsKey.practiceMode: .string("trickShots"),       // unknown case
            SettingsKey.visibleMissGrace: .double(.nan),           // not finite
            SettingsKey.detectorPinnedToCPU: .string("true")       // wrong type
        ])
        #expect(SettingsModel(loading: store) == SettingsModel())
    }

    @Test func malformedCustomTableSizesAreRejected() {
        #expect(TableSizeSetting(storageValue: "custom:2.0") == nil)
        #expect(TableSizeSetting(storageValue: "custom:abc:1.0") == nil)
        #expect(TableSizeSetting(storageValue: "custom:0:1.0") == nil)
        #expect(TableSizeSetting(storageValue: "custom:-2:-1") == nil)
        #expect(TableSizeSetting(storageValue: "") == nil)
    }

    @Test func aCorruptStoreSelfHealsOnTheNextSave() {
        let store = InMemorySettingsStore(storage: [
            SettingsKey.guideSpeed: .string("fast")
        ])
        var settings = SettingsModel(loading: store)
        settings.guideSpeed = 4.0
        settings.persist(to: store)
        #expect(store.contents[SettingsKey.guideSpeed] == .double(4.0))
        #expect(SettingsModel(loading: store).guideSpeed == 4.0)
    }

    // MARK: Storage keys and spellings

    @Test func storageKeysMatchTheOnesTheHUDAlreadyWrites() {
        // Reusing them is what keeps ONE source of truth: the antenna
        // button and the mode menu wrote these long before the sheet did.
        #expect(SettingsKey.debugMirrorEnabled == "debugMirrorEnabled")
        #expect(SettingsKey.practiceMode == "practiceMode")
    }

    @Test func tableSizeStorageSpellingsAreStable() {
        // Renaming one of these silently resets a user's table override.
        #expect(TableSizeSetting.useMeasured.storageValue == "measured")
        #expect(TableSizeSetting.standard(.sevenFoot).storageValue == "sevenFoot")
        #expect(TableSizeSetting.standard(.eightFoot).storageValue == "eightFoot")
        #expect(TableSizeSetting.standard(.nineFoot).storageValue == "nineFoot")
        for setting in TableSizeSetting.selectable {
            #expect(TableSizeSetting(storageValue: setting.storageValue) == setting)
        }
    }

    @Test func pickerOffersUseMeasuredPlusEveryStandardSize() {
        #expect(TableSizeSetting.selectable.first == .useMeasured)
        #expect(TableSizeSetting.selectable.count == TableSize.standardSizes.count + 1)
        #expect(TableSizeSetting.useMeasured.override == nil)
        #expect(TableSizeSetting.standard(.nineFoot).override == .nineFoot)
        #expect(!TableSizeSetting.selectable.contains { $0.title.isEmpty })
        #expect(!DetectionProviderSetting.allCases.contains { $0.title.isEmpty })
    }

    // MARK: Mirror snapshot

    @Test func snapshotReflectsTheLiveValues() {
        var settings = SettingsModel()
        settings.guideSpeed = 4.5
        settings.visibleMissGrace = 1.25
        settings.tableSize = .standard(.sevenFoot)
        settings.detectionProvider = .hosted
        settings.practiceMode = .calledShots
        settings.debugMirrorEnabled = false
        settings.detectorPinnedToCPU = true

        let snapshot = settings.snapshot
        #expect(snapshot[SettingsKey.detectorPinnedToCPU] == .bool(true))
        #expect(snapshot[SettingsKey.guideSpeed] == .double(4.5))
        #expect(snapshot[SettingsKey.visibleMissGrace] == .double(1.25))
        #expect(snapshot[SettingsKey.tableSize] == .string("sevenFoot"))
        #expect(snapshot[SettingsKey.detectionProvider] == .string("hosted"))
        #expect(snapshot[SettingsKey.practiceMode] == .string("calledShots"))
        #expect(snapshot[SettingsKey.debugMirrorEnabled] == .bool(false))
        // Every setting is in the snapshot: the mirror is how the owner
        // confirms a change took effect without touching the device.
        #expect(snapshot.count == 7)
    }

    // MARK: Pipeline restart hints

    @Test func onlyDetectorAndTrackerChangesForceAPipelineRestart() {
        let base = SettingsModel()
        var cosmetic = base
        cosmetic.guideSpeed = 6
        cosmetic.practiceMode = .calledShots
        cosmetic.debugMirrorEnabled = false
        cosmetic.tableSize = .standard(.nineFoot)
        #expect(!cosmetic.requiresPipelineRestart(comparedTo: base))

        var swapped = base
        swapped.detectionProvider = .hosted
        #expect(swapped.requiresPipelineRestart(comparedTo: base))

        var retuned = base
        retuned.visibleMissGrace = 2.0
        #expect(retuned.requiresPipelineRestart(comparedTo: base))
    }
}
