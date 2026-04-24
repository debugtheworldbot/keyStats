import Foundation
import Security
import AppKit

final class HelperXPCListener: NSObject, NSXPCListenerDelegate, KeyStatsHelperProtocol, EventPayloadSink {
    private let listener: NSXPCListener
    private let idle = HelperIdleSupervisor()
    private let tap = EventTapController()
    private let stateLock = NSLock()
    private weak var activeConnection: NSXPCConnection?
    private weak var activeSink: KeyStatsEventSinkProtocol?

    override init() {
        self.listener = NSXPCListener(machServiceName: HelperLocations.machServiceName)
        super.init()
        self.listener.delegate = self

        // macOS 13+ only (deployment target is 13.0).
        let req = "identifier \"\(HelperLocations.mainBundleId)\""
        self.listener.setConnectionCodeSigningRequirement(req)
    }

    func resume() { listener.resume() }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard validatePeer(newConnection) else {
            NSLog("[KeyStatsHelper] peer validation failed, rejecting pid=\(newConnection.processIdentifier)")
            return false
        }

        stateLock.lock()
        if activeConnection != nil {
            stateLock.unlock()
            NSLog("[KeyStatsHelper] active connection exists, rejecting new")
            return false
        }
        stateLock.unlock()

        newConnection.exportedInterface = NSXPCInterface(with: KeyStatsHelperProtocol.self)
        newConnection.exportedObject = self

        let remote = NSXPCInterface(with: KeyStatsEventSinkProtocol.self)
        let classes = NSSet(array: [NSDictionary.self, NSString.self, NSNumber.self]) as! Set<AnyHashable>
        remote.setClasses(
            classes,
            for: #selector(KeyStatsEventSinkProtocol.receiveEvent(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.remoteObjectInterface = remote

        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            self?.handleConnectionClosed(newConnection)
        }
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            self?.handleConnectionClosed(newConnection)
        }

        stateLock.lock()
        activeConnection = newConnection
        activeSink = newConnection.remoteObjectProxy as? KeyStatsEventSinkProtocol
        stateLock.unlock()

        idle.noteActivity()
        newConnection.resume()
        NSLog("[KeyStatsHelper] accepted connection from pid=\(newConnection.processIdentifier)")
        return true
    }

    private func validatePeer(_ conn: NSXPCConnection) -> Bool {
        let pid = conn.processIdentifier
        guard pid > 0 else { return false }

        var code: SecCode?
        let attrs: [String: Any] = [kSecGuestAttributePid as String: Int(pid)]
        var status = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code)
        guard status == errSecSuccess, let code = code else { return false }

        status = SecCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else { return false }

        var info: CFDictionary?
        status = SecCodeCopySigningInformation(
            code as! SecStaticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &info
        )
        guard status == errSecSuccess, let d = info as? [String: Any] else { return false }

        guard let identifier = d[kSecCodeInfoIdentifier as String] as? String,
              identifier == HelperLocations.mainBundleId else {
            return false
        }

        let uid = conn.effectiveUserIdentifier
        guard uid == getuid() else { return false }

        return true
    }

    private func handleConnectionClosed(_ conn: NSXPCConnection?) {
        stateLock.lock()
        if activeConnection === conn {
            activeConnection = nil
            activeSink = nil
            tap.stop()
        }
        stateLock.unlock()
        idle.connectionDidClose()
    }

    func handshake(clientInterfaceVersion: Int,
                   reply: @escaping (Int, Bool) -> Void) {
        idle.noteActivity()
        reply(HelperLocations.interfaceVersion, tap.isAccessibilityGranted())
    }

    func startMonitoring(reply: @escaping (Bool, Int) -> Void) {
        idle.noteActivity()
        let code = tap.start(sink: self)
        reply(code == HelperErrorCode.none, code)
    }

    func stopMonitoring() {
        idle.noteActivity()
        tap.stop()
    }

    func helperBundleURL(reply: @escaping (String) -> Void) {
        reply(Bundle.main.bundleURL.path)
    }

    func forward(payload: [String: Any]) {
        stateLock.lock()
        let sink = activeSink
        stateLock.unlock()
        sink?.receiveEvent(payload)
    }
}
