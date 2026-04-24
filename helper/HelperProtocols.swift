import Foundation

@objc public protocol KeyStatsHelperProtocol {
    func handshake(clientInterfaceVersion: Int,
                   reply: @escaping (_ helperVersion: Int,
                                     _ accessibilityGranted: Bool) -> Void)

    func startMonitoring(reply: @escaping (_ ok: Bool, _ errorCode: Int) -> Void)

    func stopMonitoring()

    func helperBundleURL(reply: @escaping (_ path: String) -> Void)
}

@objc public protocol KeyStatsEventSinkProtocol {
    func receiveEvent(_ payload: [String: Any])
}
