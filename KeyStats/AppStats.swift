import Foundation

struct AppIdentity: Equatable {
    let bundleId: String
    let displayName: String

    static let unknown = AppIdentity(bundleId: "unknown", displayName: "")
}

/// 允许测试注入同步调度器来驱动 AppIdentityCache 的异步路径。
protocol AppIdentityDispatcher {
    func dispatch(_ work: @escaping () -> Void)
}

struct QueueAppIdentityDispatcher: AppIdentityDispatcher {
    let queue: DispatchQueue
    func dispatch(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }
}

/// 线程安全的 PID → AppIdentity 缓存。未命中时派发后台解析，
/// 同一 PID 的并发查询会被折叠成单次解析，避免在事件 tap 回调
/// 线程上同步调用 NSRunningApplication 进而阻塞 IME 事件。
/// 解析失败会被负缓存，避免对不可解析的系统进程反复堆积后台任务。
final class AppIdentityCache {
    typealias Resolver = (pid_t) -> (bundleId: String, name: String)?

    private let lock = NSLock()
    private var frontmost = AppIdentity.unknown
    private var pidToBundleId: [pid_t: String] = [:]
    private var bundleIdToName: [String: String] = [:]
    private var pendingResolutions: Set<pid_t> = []
    private var unresolvablePIDs: Set<pid_t> = []
    private let resolver: Resolver
    private let dispatcher: AppIdentityDispatcher

    init(resolver: @escaping Resolver, dispatcher: AppIdentityDispatcher) {
        self.resolver = resolver
        self.dispatcher = dispatcher
    }

    func identity(forPID pid: pid_t?) -> AppIdentity {
        let (identity, pidNeedingResolution) = lookupLocked(pid: pid)
        if let pid = pidNeedingResolution {
            dispatchResolution(forPID: pid)
        }
        return identity
    }

    func updateFrontmost(bundleId: String, name: String, pid: pid_t?) {
        lock.lock()
        frontmost = AppIdentity(bundleId: bundleId, displayName: name)
        if !name.isEmpty {
            bundleIdToName[bundleId] = name
        }
        if let pid = pid, pid > 0 {
            pidToBundleId[pid] = bundleId
            unresolvablePIDs.remove(pid)
        }
        lock.unlock()
    }

    var currentFrontmost: AppIdentity {
        lock.lock()
        defer { lock.unlock() }
        return frontmost
    }

    /// 在单次锁块内完成缓存命中判定、待解析 PID 登记和 frontmost 读取，
    /// 减少事件 tap 回调路径上的锁抖动。返回的第二项非 nil 时，调用方
    /// 需在锁外派发后台解析（派发本身不能持锁，避免占锁过久）。
    private func lookupLocked(pid: pid_t?) -> (AppIdentity, pid_t?) {
        lock.lock()
        defer { lock.unlock() }
        guard let pid = pid, pid > 0 else {
            return (frontmost, nil)
        }
        if let bundleId = pidToBundleId[pid] {
            let name = bundleIdToName[bundleId] ?? ""
            return (AppIdentity(bundleId: bundleId, displayName: name), nil)
        }
        if unresolvablePIDs.contains(pid) || pendingResolutions.contains(pid) {
            return (frontmost, nil)
        }
        pendingResolutions.insert(pid)
        return (frontmost, pid)
    }

    private func dispatchResolution(forPID pid: pid_t) {
        dispatcher.dispatch { [weak self] in
            guard let self = self else { return }
            let result = self.resolver(pid)
            self.lock.lock()
            self.pendingResolutions.remove(pid)
            if let result = result {
                self.pidToBundleId[pid] = result.bundleId
                if !result.name.isEmpty {
                    self.bundleIdToName[result.bundleId] = result.name
                }
            } else {
                self.unresolvablePIDs.insert(pid)
            }
            self.lock.unlock()
        }
    }
}

struct AppStats: Codable {
    var bundleId: String
    var displayName: String
    var keyPresses: Int
    var leftClicks: Int
    var rightClicks: Int
    var sideBackClicks: Int
    var sideForwardClicks: Int
    var scrollDistance: Double

    init(bundleId: String, displayName: String) {
        self.bundleId = bundleId
        self.displayName = displayName
        self.keyPresses = 0
        self.leftClicks = 0
        self.rightClicks = 0
        self.sideBackClicks = 0
        self.sideForwardClicks = 0
        self.scrollDistance = 0
    }

    enum CodingKeys: String, CodingKey {
        case bundleId
        case displayName
        case keyPresses
        case leftClicks
        case rightClicks
        case sideBackClicks
        case sideForwardClicks
        // legacy field
        case otherClicks
        case scrollDistance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        keyPresses = try container.decodeIfPresent(Int.self, forKey: .keyPresses) ?? 0
        leftClicks = try container.decodeIfPresent(Int.self, forKey: .leftClicks) ?? 0
        rightClicks = try container.decodeIfPresent(Int.self, forKey: .rightClicks) ?? 0
        sideBackClicks = try container.decodeIfPresent(Int.self, forKey: .sideBackClicks) ?? 0
        sideForwardClicks = try container.decodeIfPresent(Int.self, forKey: .sideForwardClicks) ?? 0
        // Backward compatibility: old builds stored all side clicks in `otherClicks`.
        if !container.contains(.sideBackClicks) && !container.contains(.sideForwardClicks) {
            sideBackClicks = try container.decodeIfPresent(Int.self, forKey: .otherClicks) ?? 0
        }
        scrollDistance = try container.decodeIfPresent(Double.self, forKey: .scrollDistance) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(keyPresses, forKey: .keyPresses)
        try container.encode(leftClicks, forKey: .leftClicks)
        try container.encode(rightClicks, forKey: .rightClicks)
        try container.encode(sideBackClicks, forKey: .sideBackClicks)
        try container.encode(sideForwardClicks, forKey: .sideForwardClicks)
        try container.encode(scrollDistance, forKey: .scrollDistance)
    }

    var totalClicks: Int {
        return leftClicks + rightClicks + sideBackClicks + sideForwardClicks
    }

    var hasActivity: Bool {
        return keyPresses > 0 ||
            leftClicks > 0 ||
            rightClicks > 0 ||
            sideBackClicks > 0 ||
            sideForwardClicks > 0 ||
            scrollDistance > 0
    }

    mutating func updateDisplayName(_ name: String) {
        guard !name.isEmpty else { return }
        displayName = name
    }

    mutating func recordKeyPress() {
        keyPresses += 1
    }

    mutating func recordLeftClick() {
        leftClicks += 1
    }

    mutating func recordRightClick() {
        rightClicks += 1
    }

    mutating func recordSideBackClick() {
        sideBackClicks += 1
    }

    mutating func recordSideForwardClick() {
        sideForwardClicks += 1
    }

    mutating func addScrollDistance(_ distance: Double) {
        scrollDistance += abs(distance)
    }
}
