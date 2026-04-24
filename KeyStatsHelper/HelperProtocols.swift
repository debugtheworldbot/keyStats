import Foundation

@objc public protocol KeyStatsHelperProtocol {
    func handshake(clientInterfaceVersion: Int,
                   reply: @escaping (_ helperVersion: Int,
                                     _ accessibilityGranted: Bool) -> Void)

    func startMonitoring(reply: @escaping (_ ok: Bool, _ errorCode: Int) -> Void)

    func stopMonitoring()

    /// 让 helper 调一次 `AXIsProcessTrustedWithOptions(prompt: true)`，目的是把
    /// 自己注册进系统设置 → 隐私与安全性 → 辅助功能 的列表。副作用：首次调用会弹一个系统级
    /// "KeyStatsHelper 希望……"的确认框（含"打开系统设置"按钮）。回调 true 表示已经授权。
    func promptAccessibility(reply: @escaping (_ granted: Bool) -> Void)

    func helperBundleURL(reply: @escaping (_ path: String) -> Void)
}

@objc public protocol KeyStatsEventSinkProtocol {
    func receiveEvent(_ payload: [String: Any])
}
