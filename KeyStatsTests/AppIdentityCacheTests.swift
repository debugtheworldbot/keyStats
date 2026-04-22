import XCTest
import CoreGraphics
@testable import KeyStatsCore

private final class ManualDispatcher: AppIdentityDispatcher {
    var pending: [() -> Void] = []

    func dispatch(_ work: @escaping () -> Void) {
        pending.append(work)
    }

    func drain() {
        let work = pending
        pending.removeAll()
        work.forEach { $0() }
    }
}

private final class ResolverSpy {
    private(set) var calls: [pid_t] = []
    var response: (pid_t) -> (bundleId: String, name: String)? = { _ in nil }

    func resolve(pid: pid_t) -> (bundleId: String, name: String)? {
        calls.append(pid)
        return response(pid)
    }
}

final class AppIdentityCacheTests: XCTestCase {
    private func makeCache(
        dispatcher: ManualDispatcher = ManualDispatcher(),
        spy: ResolverSpy = ResolverSpy()
    ) -> (AppIdentityCache, ManualDispatcher, ResolverSpy) {
        let cache = AppIdentityCache(resolver: spy.resolve, dispatcher: dispatcher)
        return (cache, dispatcher, spy)
    }

    // MARK: - isTapDisabledSignal

    func testIsTapDisabledSignalReturnsTrueForTimeoutAndUserInput() {
        XCTAssertTrue(isTapDisabledSignal(.tapDisabledByTimeout))
        XCTAssertTrue(isTapDisabledSignal(.tapDisabledByUserInput))
    }

    func testIsTapDisabledSignalReturnsFalseForNormalEventTypes() {
        XCTAssertFalse(isTapDisabledSignal(.keyDown))
        XCTAssertFalse(isTapDisabledSignal(.flagsChanged))
        XCTAssertFalse(isTapDisabledSignal(.mouseMoved))
        XCTAssertFalse(isTapDisabledSignal(.leftMouseDown))
        XCTAssertFalse(isTapDisabledSignal(.rightMouseDown))
        XCTAssertFalse(isTapDisabledSignal(.scrollWheel))
        XCTAssertFalse(isTapDisabledSignal(.null))
    }

    // MARK: - identity(forPID:)

    func testIdentityForNilPIDReturnsFrontmost() {
        let (cache, _, spy) = makeCache()
        cache.updateFrontmost(bundleId: "com.front", name: "Front", pid: 100)

        let result = cache.identity(forPID: nil)

        XCTAssertEqual(result, AppIdentity(bundleId: "com.front", displayName: "Front"))
        XCTAssertTrue(spy.calls.isEmpty, "nil PID 不应触发解析")
    }

    func testIdentityForZeroPIDReturnsFrontmostWithoutResolution() {
        let (cache, _, spy) = makeCache()
        cache.updateFrontmost(bundleId: "com.front", name: "Front", pid: 100)

        let result = cache.identity(forPID: 0)

        XCTAssertEqual(result.bundleId, "com.front")
        XCTAssertTrue(spy.calls.isEmpty, "PID=0 属于内核事件，不应触发解析")
    }

    func testIdentityForNegativePIDReturnsFrontmostWithoutResolution() {
        let (cache, _, spy) = makeCache()
        cache.updateFrontmost(bundleId: "com.front", name: "Front", pid: 100)

        let result = cache.identity(forPID: -1)

        XCTAssertEqual(result.bundleId, "com.front")
        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testIdentityForUnknownPIDReturnsFrontmostImmediately() {
        let (cache, dispatcher, spy) = makeCache()
        cache.updateFrontmost(bundleId: "com.front", name: "Front", pid: 100)

        let result = cache.identity(forPID: 7777)

        // 返回值必须立刻给出，不能等解析完成，否则会卡住事件 tap 回调线程。
        XCTAssertEqual(result, AppIdentity(bundleId: "com.front", displayName: "Front"))
        XCTAssertTrue(spy.calls.isEmpty, "resolver 应在 dispatcher 驱动后才执行，而非同步")
        XCTAssertEqual(dispatcher.pending.count, 1, "应当排入一次后台解析任务")
    }

    func testIdentityForPreviouslyResolvedPIDReturnsCachedValue() {
        let spy = ResolverSpy()
        spy.response = { _ in (bundleId: "com.app", name: "Resolved") }
        let dispatcher = ManualDispatcher()
        let (cache, _, _) = makeCache(dispatcher: dispatcher, spy: spy)

        _ = cache.identity(forPID: 42)
        dispatcher.drain()

        let result = cache.identity(forPID: 42)
        XCTAssertEqual(result, AppIdentity(bundleId: "com.app", displayName: "Resolved"))
        XCTAssertEqual(spy.calls, [42], "已解析的 PID 再次查询不应重新调用 resolver")
        XCTAssertTrue(dispatcher.pending.isEmpty)
    }

    func testConcurrentQueriesForSamePIDCoalesceIntoSingleResolverCall() {
        let spy = ResolverSpy()
        spy.response = { _ in (bundleId: "com.app", name: "App") }
        let dispatcher = ManualDispatcher()
        let (cache, _, _) = makeCache(dispatcher: dispatcher, spy: spy)

        _ = cache.identity(forPID: 42)
        _ = cache.identity(forPID: 42)
        _ = cache.identity(forPID: 42)

        XCTAssertEqual(dispatcher.pending.count, 1, "同一 PID 的重复查询应被折叠成单次解析")
        dispatcher.drain()
        XCTAssertEqual(spy.calls, [42])
    }

    func testResolverFailureDoesNotCachePIDAndAllowsRetry() {
        let spy = ResolverSpy()
        spy.response = { _ in nil }
        let dispatcher = ManualDispatcher()
        let (cache, _, _) = makeCache(dispatcher: dispatcher, spy: spy)

        _ = cache.identity(forPID: 42)
        dispatcher.drain()

        _ = cache.identity(forPID: 42)
        XCTAssertEqual(dispatcher.pending.count, 1, "resolver 返回 nil 后允许后续查询重试")
        dispatcher.drain()
        XCTAssertEqual(spy.calls, [42, 42])
    }

    // MARK: - updateFrontmost

    func testUpdateFrontmostPreCachesPID() {
        let (cache, _, spy) = makeCache()

        cache.updateFrontmost(bundleId: "com.front", name: "Front", pid: 100)

        let result = cache.identity(forPID: 100)
        XCTAssertEqual(result, AppIdentity(bundleId: "com.front", displayName: "Front"))
        XCTAssertTrue(spy.calls.isEmpty, "前台 App 的 PID 已预填缓存，不应触发 resolver")
    }

    func testUpdateFrontmostWithZeroPIDSkipsPIDCaching() {
        let (cache, dispatcher, spy) = makeCache()

        cache.updateFrontmost(bundleId: "com.front", name: "Front", pid: 0)

        let result = cache.identity(forPID: nil)
        XCTAssertEqual(result.bundleId, "com.front")

        _ = cache.identity(forPID: 500)
        XCTAssertEqual(dispatcher.pending.count, 1)
        XCTAssertTrue(spy.calls.isEmpty, "派发前 resolver 不应被调用")
    }

    func testCurrentFrontmostReflectsLatestUpdate() {
        let (cache, _, _) = makeCache()

        XCTAssertEqual(cache.currentFrontmost, AppIdentity.unknown)

        cache.updateFrontmost(bundleId: "com.a", name: "A", pid: 1)
        XCTAssertEqual(cache.currentFrontmost, AppIdentity(bundleId: "com.a", displayName: "A"))

        cache.updateFrontmost(bundleId: "com.b", name: "B", pid: 2)
        XCTAssertEqual(cache.currentFrontmost, AppIdentity(bundleId: "com.b", displayName: "B"))
    }

    func testResolverResultWithEmptyNameStillCachesBundleId() {
        let spy = ResolverSpy()
        spy.response = { _ in (bundleId: "com.anon", name: "") }
        let dispatcher = ManualDispatcher()
        let (cache, _, _) = makeCache(dispatcher: dispatcher, spy: spy)

        _ = cache.identity(forPID: 9)
        dispatcher.drain()

        let result = cache.identity(forPID: 9)
        XCTAssertEqual(result, AppIdentity(bundleId: "com.anon", displayName: ""))
        XCTAssertEqual(spy.calls, [9])
    }
}
