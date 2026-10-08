import Foundation
@testable import TelegramUI
import XCTest

final class WhitegramKeepAliveTests: XCTestCase {
    func testPersistentWatchdogRepairsStoppedPlaybackInOneSecond() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(0)
        XCTAssertEqual(host.players.count, 1)
        XCTAssertEqual(host.volumes, [0.03])
        host.players[0].isPlaying = false
        host.advance(by: 0.99)
        XCTAssertEqual(host.players.count, 1)
        host.advance(by: 0.01)
        XCTAssertEqual(host.players.count, 2)
        XCTAssertTrue(host.players[1].isPlaying)
        XCTAssertEqual(host.requests.count, 1)
        host.players[0].stopped()
        XCTAssertTrue(host.players[1].isPlaying)
    }

    func testRecoveryUsesMixedPlaybackZeroVolumeAndFifteenSecondRetry() {
        let host = KeepAliveTestHost()
        host.failedStarts = 1
        let controller = WhitegramKeepAliveController(mode: .recovery, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        XCTAssertEqual(host.directActivations, [true])
        XCTAssertTrue(host.requests.isEmpty)
        host.advance(by: 14.99)
        XCTAssertEqual(host.players.count, 1)
        host.advance(by: 0.01)
        XCTAssertEqual(host.players.count, 2)
        XCTAssertTrue(host.players[1].isPlaying)
        XCTAssertEqual(host.volumes, [0.0, 0.0])
    }

    func testMissingManagedCallbackFallsBackAfterOneAndAHalfSeconds() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.advance(by: 1.49)
        XCTAssertTrue(host.players.isEmpty)
        host.advance(by: 0.01)
        XCTAssertEqual(host.directActivations, [false])
        XCTAssertTrue(host.players[0].isPlaying)
        host.activateRequest(0)
        XCTAssertEqual(host.players.count, 1)
    }

    func testFailedDirectFallbackRetriesWithoutNeedingForeground() {
        let host = KeepAliveTestHost()
        host.directFailures = 1
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.advance(by: 1.5)
        XCTAssertTrue(host.players.isEmpty)
        host.advance(by: 2.0)
        XCTAssertTrue(host.players[0].isPlaying)
        XCTAssertEqual(host.requests.count, 1)
    }

    func testYieldToManagedRecordingDoesNotRestartOverIt() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(0)
        host.requests[0].deactivated()
        host.advance(by: 20)
        XCTAssertTrue(host.directActivations.isEmpty)
        XCTAssertFalse(host.players.contains { $0.isPlaying })
        host.activateRequest(0)
        XCTAssertTrue(host.players.last!.isPlaying)
    }

    func testFallbackCannotTakeAnUnrelatedManagedSession() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.managedAudioActive = true
        host.advance(by: 20)
        XCTAssertTrue(host.directActivations.isEmpty)
        XCTAssertTrue(host.players.isEmpty)
    }

    func testOwnPlaybackAndCallsReleaseAndReacquireTheKeepAliveHolder() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(0)
        controller.update(wantsRunning: true, blocked: true)
        XCTAssertTrue(host.requests[0].cancelled)
        XCTAssertFalse(host.players[0].isPlaying)
        host.advance(by: 30)
        XCTAssertEqual(host.requests.count, 1)
        host.managedAudioActive = false
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(1)
        XCTAssertTrue(host.players.last!.isPlaying)
    }

    func testInterruptedAudioResumesWithoutAShouldResumeFlag() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(0)
        controller.interruptionBegan()
        host.advance(by: 40)
        XCTAssertFalse(host.players[0].isPlaying)
        controller.interruptionEnded()
        host.activateRequest(1)
        XCTAssertTrue(host.players.last!.isPlaying)
    }

    func testExpiredBackgroundLeaseRenewsAndDoesNotStopThePlayer() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(0)
        host.tasks[0].expired()
        XCTAssertEqual(host.tasks[0].ends, 1)
        XCTAssertEqual(host.tasks.count, 2)
        XCTAssertTrue(host.players[0].isPlaying)
        host.tasks[0].expired()
        XCTAssertEqual(host.tasks.count, 2)
        controller.update(wantsRunning: false, blocked: false)
        host.tasks[1].expired()
        XCTAssertEqual(host.tasks[1].ends, 1)
        XCTAssertEqual(host.tasks.count, 2)
    }

    func testCallbacksFromPreviousLifecycleCannotRestartOrPauseCurrentAudio() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        controller.update(wantsRunning: false, blocked: false)
        host.requests[0].activated()
        host.advance(by: 30)
        XCTAssertTrue(host.players.isEmpty)
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(1)
        host.requests[0].deactivated()
        host.tasks[0].expired()
        XCTAssertTrue(host.players[0].isPlaying)
        XCTAssertEqual(host.tasks.count, 2)
    }

    func testMediaServicesResetRecreatesManagedHolderAndPlayer() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(0)
        controller.mediaServicesReset()
        XCTAssertTrue(host.requests[0].cancelled)
        host.activateRequest(1)
        XCTAssertTrue(host.players[1].isPlaying)
        host.players[0].stopped()
        XCTAssertTrue(host.players[1].isPlaying)
    }

    func testSecondaryAudioHintChangesCategoryOnlyWhileUnblocked() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.activateRequest(0)
        host.otherAudioPlaying = true
        controller.secondaryAudioChanged()
        XCTAssertEqual(host.directActivations, [true])
        host.requests[0].deactivated()
        host.otherAudioPlaying = false
        controller.secondaryAudioChanged()
        XCTAssertEqual(host.directActivations, [true])
    }

    func testRecoveryStopCannotDeactivateNewManagedPlayback() {
        let host = KeepAliveTestHost()
        let controller = WhitegramKeepAliveController(mode: .recovery, environment: host)
        controller.update(wantsRunning: true, blocked: false)
        host.managedAudioActive = true
        controller.update(wantsRunning: true, blocked: true)
        XCTAssertEqual(host.directDeactivations, 0)
        XCTAssertFalse(host.players[0].isPlaying)
    }

    func testControllerDestructionReleasesTimersPlayerLeaseAndSession() {
        let host = KeepAliveTestHost()
        var controller: WhitegramKeepAliveController? = WhitegramKeepAliveController(mode: .persistent, environment: host)
        controller?.update(wantsRunning: true, blocked: false)
        host.activateRequest(0)
        controller = nil
        XCTAssertTrue(host.requests[0].cancelled)
        XCTAssertEqual(host.tasks[0].ends, 1)
        XCTAssertFalse(host.players[0].isPlaying)
        host.advance(by: 30)
        XCTAssertEqual(host.players.count, 1)
    }
}

private final class KeepAliveTestHost: WhitegramKeepAliveEnvironment {
    final class Request {
        let activated: () -> Void
        let deactivated: () -> Void
        var cancelled = false
        init(activated: @escaping () -> Void, deactivated: @escaping () -> Void) {
            self.activated = activated
            self.deactivated = deactivated
        }
    }
    final class Task {
        let expired: () -> Void
        var ends = 0
        init(expired: @escaping () -> Void) { self.expired = expired }
    }
    final class Timer {
        var deadline: TimeInterval
        let interval: TimeInterval?
        let action: () -> Void
        var cancelled = false
        init(deadline: TimeInterval, interval: TimeInterval?, action: @escaping () -> Void) {
            self.deadline = deadline
            self.interval = interval
            self.action = action
        }
    }
    final class Player: WhitegramKeepAlivePlayer {
        var isPlaying = false
        var succeeds: Bool
        let stopped: () -> Void
        init(succeeds: Bool, stopped: @escaping () -> Void) { self.succeeds = succeeds; self.stopped = stopped }
        func play() -> Bool { self.isPlaying = self.succeeds; return self.succeeds }
        func pause() { self.isPlaying = false }
        func stop() { self.isPlaying = false }
    }
    var otherAudioPlaying = false
    var managedAudioActive = false
    var requests: [Request] = []
    var tasks: [Task] = []
    var timers: [Timer] = []
    var players: [Player] = []
    var volumes: [Float] = []
    var directActivations: [Bool] = []
    var directDeactivations = 0
    var directFailures = 0
    var failedStarts = 0
    private var now: TimeInterval = 0

    func activateRequest(_ index: Int) {
        self.managedAudioActive = true
        self.requests[index].activated()
    }

    func requestManagedAudio(mixWithOthers: Bool, activated: @escaping () -> Void, deactivated: @escaping () -> Void) -> () -> Void {
        let request = Request(activated: activated, deactivated: deactivated)
        self.requests.append(request)
        return { request.cancelled = true }
    }

    func activateDirectAudio(mixWithOthers: Bool) throws {
        if self.directFailures > 0 {
            self.directFailures -= 1
            throw NSError(domain: "KeepAliveTestHost", code: 1)
        }
        self.directActivations.append(mixWithOthers)
    }

    func deactivateDirectAudio() { self.directDeactivations += 1 }

    func makePlayer(volume: Float, stopped: @escaping () -> Void) throws -> WhitegramKeepAlivePlayer {
        let player = Player(succeeds: self.failedStarts == 0, stopped: stopped)
        self.failedStarts = max(0, self.failedStarts - 1)
        self.players.append(player)
        self.volumes.append(volume)
        return player
    }

    func schedule(after seconds: TimeInterval, repeating: Bool, _ action: @escaping () -> Void) -> () -> Void {
        let timer = Timer(deadline: self.now + seconds, interval: repeating ? seconds : nil, action: action)
        self.timers.append(timer)
        return { timer.cancelled = true }
    }

    func beginBackgroundTask(expired: @escaping () -> Void) -> (() -> Void)? {
        let task = Task(expired: expired)
        self.tasks.append(task)
        return { task.ends += 1 }
    }

    func advance(by seconds: TimeInterval) {
        let end = self.now + seconds
        while let timer = self.timers.filter({ !$0.cancelled && $0.deadline <= end }).min(by: { $0.deadline < $1.deadline }) {
            self.now = timer.deadline
            if let interval = timer.interval { timer.deadline += interval } else { timer.cancelled = true }
            timer.action()
        }
        self.now = end
    }
}
