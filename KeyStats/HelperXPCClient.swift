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

        c.invalidationHandler = { [weak self] in
            self?.transition(to: .disconnected(reason: "invalidated"))
        }
        c.interruptionHandler = { [weak self] in
            self?.transition(to: .disconnected(reason: "interrupted"))
        }
        c.resume()
        connection = c
        _state = .connecting
        lock.unlock()

        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            self?.transition(to: .disconnected(reason: "\(err)"))
        } as? KeyStatsHelperProtocol

        guard let proxy = proxy else {
            transition(to: .disconnected(reason: "no proxy"))
            completion?(.disconnected(reason: "no proxy"))
            return
        }

        proxy.handshake(clientInterfaceVersion: HelperLocations.interfaceVersion) { [weak self] helperVersion, granted in
            let newState: State = .connected(helperVersion: helperVersion, accessibilityGranted: granted)
            self?.transition(to: newState)
            completion?(newState)
        }
    }

    func startMonitoring(completion: @escaping (Bool, Int) -> Void) {
        withProxy({ proxy in proxy.startMonitoring(reply: completion) },
                  fallback: { completion(false, HelperErrorCode.accessibilityDenied) })
    }

    func stopMonitoring() {
        withProxy({ $0.stopMonitoring() }, fallback: {})
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
