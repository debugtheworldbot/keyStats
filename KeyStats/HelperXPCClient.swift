import Foundation

final class HelperXPCClient {
    static let shared = HelperXPCClient()

    enum State: Equatable {
        case idle
        case connecting
        case connected(helperVersion: Int, accessibilityGranted: Bool)
        case disconnected(reason: String)
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var _state: State = .idle
    private var eventSink: KeyStatsEventSinkProtocol?
    private var stateObservers: [(State) -> Void] = []

    private init() {}

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    func setEventSink(_ sink: KeyStatsEventSinkProtocol) {
        lock.lock()
        self.eventSink = sink
        connection?.exportedObject = sink
        lock.unlock()
    }

    func addStateObserver(_ cb: @escaping (State) -> Void) {
        lock.lock(); stateObservers.append(cb); lock.unlock()
        cb(state)
    }

    func connect(completion: ((State) -> Void)? = nil) {
        lock.lock()
        if connection != nil {
            let s = _state
            lock.unlock()
            completion?(s)
            return
        }

        let c = NSXPCConnection(machServiceName: HelperLocations.machServiceName)
        c.remoteObjectInterface = NSXPCInterface(with: KeyStatsHelperProtocol.self)

        let exported = NSXPCInterface(with: KeyStatsEventSinkProtocol.self)
        let classes = NSSet(array: [NSDictionary.self, NSString.self, NSNumber.self]) as! Set<AnyHashable>
        exported.setClasses(
            classes,
            for: #selector(KeyStatsEventSinkProtocol.receiveEvent(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        c.exportedInterface = exported
        if let sink = eventSink {
            c.exportedObject = sink
        }

        // One-shot guard: 错误回调和 reply 在 NSXPCConnection 上是互斥的，但
        // invalidation/interruption handler 也会同路径触发；统一走 finish() 保证 completion
        // 只触发一次，避免任一失败路径让 AppDelegate 的 5s 重连闭环 silently 断掉。
        let completionLock = NSLock()
        var didFinish = false
        let finish: (State) -> Void = { state in
            completionLock.lock()
            let already = didFinish
            didFinish = true
            completionLock.unlock()
            guard !already else { return }
            completion?(state)
        }

        c.invalidationHandler = { [weak self] in
            let reason = "invalidated"
            self?.transition(to: .disconnected(reason: reason))
            finish(.disconnected(reason: reason))
        }
        c.interruptionHandler = { [weak self] in
            let reason = "interrupted"
            self?.transition(to: .disconnected(reason: reason))
            finish(.disconnected(reason: reason))
        }
        c.resume()
        connection = c
        _state = .connecting
        lock.unlock()

        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            let reason = "\(err)"
            self?.transition(to: .disconnected(reason: reason))
            finish(.disconnected(reason: reason))
        } as? KeyStatsHelperProtocol

        guard let proxy = proxy else {
            transition(to: .disconnected(reason: "no proxy"))
            finish(.disconnected(reason: "no proxy"))
            return
        }

        proxy.handshake(clientInterfaceVersion: HelperLocations.interfaceVersion) { [weak self] helperVersion, granted in
            if helperVersion != HelperLocations.interfaceVersion {
                NSLog("[HelperXPCClient] interface version mismatch: client=\(HelperLocations.interfaceVersion) helper=\(helperVersion)")
            }
            let newState: State = .connected(helperVersion: helperVersion, accessibilityGranted: granted)
            self?.transition(to: newState)
            finish(newState)
        }
    }

    func startMonitoring(completion: @escaping (Bool, Int) -> Void) {
        withProxy({ proxy in proxy.startMonitoring(reply: completion) },
                  fallback: { completion(false, HelperErrorCode.accessibilityDenied) })
    }

    /// 重发握手，获取 helper 最新的 accessibility 授权状态。
    /// 用于用户完成 System Settings 授权后刷新 UI。
    func refreshState(completion: @escaping (State) -> Void) {
        lock.lock()
        let c = connection
        lock.unlock()
        guard let c = c else {
            connect(completion: completion)
            return
        }
        let completionLock = NSLock()
        var didFinish = false
        let finish: (State) -> Void = { state in
            completionLock.lock()
            let already = didFinish
            didFinish = true
            completionLock.unlock()
            guard !already else { return }
            completion(state)
        }
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            let reason = "\(err)"
            self?.transition(to: .disconnected(reason: reason))
            finish(.disconnected(reason: reason))
        } as? KeyStatsHelperProtocol
        guard let proxy = proxy else {
            connect(completion: completion)
            return
        }
        proxy.handshake(clientInterfaceVersion: HelperLocations.interfaceVersion) { [weak self] v, g in
            if v != HelperLocations.interfaceVersion {
                NSLog("[HelperXPCClient] interface version mismatch: client=\(HelperLocations.interfaceVersion) helper=\(v)")
            }
            let newState: State = .connected(helperVersion: v, accessibilityGranted: g)
            self?.transition(to: newState)
            finish(newState)
        }
    }

    func stopMonitoring() {
        withProxy({ $0.stopMonitoring() }, fallback: {})
    }

    /// 让 helper 主动调一次 `AXIsProcessTrustedWithOptions(prompt: true)`，把自己注册进
    /// 系统设置的辅助功能列表。completion 回调发生在 XPC 队列，调用方自行切主队列。
    func promptAccessibility(completion: @escaping (Bool) -> Void) {
        lock.lock()
        let hasConnection = connection != nil
        lock.unlock()

        let sendPrompt: () -> Void = { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            self.sendPromptAccessibility(completion: completion)
        }

        guard !hasConnection else {
            sendPrompt()
            return
        }

        connect { state in
            guard case .connected = state else {
                completion(false)
                return
            }
            sendPrompt()
        }
    }

    func disconnect() {
        lock.lock()
        let c = connection
        connection = nil
        _state = .idle
        lock.unlock()
        c?.invalidate()
    }

    // MARK: - Private

    private func sendPromptAccessibility(completion: @escaping (Bool) -> Void) {
        lock.lock()
        let c = connection
        lock.unlock()

        guard let c = c else {
            completion(false)
            return
        }

        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            self?.transition(to: .disconnected(reason: "\(err)"))
            completion(false)
        } as? KeyStatsHelperProtocol

        guard let proxy = proxy else {
            completion(false)
            return
        }

        proxy.promptAccessibility(reply: completion)
    }

    private func withProxy<T>(_ fn: (KeyStatsHelperProtocol) -> T,
                              fallback: () -> T) -> T {
        lock.lock()
        let c = connection
        lock.unlock()
        guard let c = c else { return fallback() }
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            self?.transition(to: .disconnected(reason: "\(err)"))
        } as? KeyStatsHelperProtocol
        return proxy.map(fn) ?? fallback()
    }

    private func transition(to state: State) {
        var observers: [(State) -> Void] = []
        lock.lock()
        _state = state
        observers = stateObservers
        if case .disconnected = state {
            connection?.invalidate()
            connection = nil
        }
        lock.unlock()
        observers.forEach { $0(state) }
    }
}
