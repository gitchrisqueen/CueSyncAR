import CueSyncCore
import Testing
@testable import DisplayKit

@Suite("ExternalDisplayRouter")
struct ExternalDisplayRouterTests {
    @Test func firstConnectionPrompts() {
        var router = ExternalDisplayRouter()
        router.handle(.displayConnected)
        #expect(router.state == .prompting)
        router.handle(.userChose(.tableView))
        #expect(router.state == .tableView)
        #expect(router.isTableViewActive)
    }

    @Test func preferenceSkipsPromptOnReconnect() {
        var router = ExternalDisplayRouter()
        router.handle(.displayConnected)
        router.handle(.userChose(.tableView))
        router.handle(.displayDisconnected)
        #expect(router.state == .disconnected)
        // Reconnect: remembered choice applies immediately.
        router.handle(.displayConnected)
        #expect(router.state == .tableView)
    }

    @Test func mirrorPreferenceAlsoRemembered() {
        var router = ExternalDisplayRouter()
        router.handle(.displayConnected)
        router.handle(.userChose(.mirror))
        #expect(router.state == .mirroring)
        router.handle(.displayDisconnected)
        router.handle(.displayConnected)
        #expect(router.state == .mirroring)
    }

    @Test func modeSwitchWhileConnected() {
        var router = ExternalDisplayRouter(preferredOutput: .mirror)
        router.handle(.displayConnected)
        #expect(router.state == .mirroring)
        router.handle(.userChose(.tableView))
        #expect(router.state == .tableView)
        #expect(router.preferredOutput == .tableView)
    }

    @Test func hotPlugCyclesAreStable() {
        var router = ExternalDisplayRouter()
        for _ in 0..<3 {
            router.handle(.displayConnected)
            router.handle(.userChose(.tableView))
            router.handle(.displayDisconnected)
        }
        #expect(router.state == .disconnected)
        #expect(router.preferredOutput == .tableView)
        // Disconnect while disconnected is a no-op, never a trap.
        router.handle(.displayDisconnected)
        #expect(router.state == .disconnected)
    }
}
