import Foundation

enum HelperPayloadFields {
    static let type = "type"
    static let keyCode = "keyCode"
    static let keyboardType = "keyboardType"
    static let flags = "flags"
    static let isAutoRepeat = "isAutoRepeat"
    static let buttonRole = "buttonRole"
    static let buttonNumber = "buttonNumber"
    static let locationX = "locationX"
    static let locationY = "locationY"
    static let scrollDX = "scrollDX"
    static let scrollDY = "scrollDY"
    static let sourcePID = "sourcePID"
    static let monotonicTime = "monotonicTime"
}

enum ButtonRole {
    static let primary = "primary"
    static let secondary = "secondary"
    static let back = "back"
    static let forward = "forward"
}

enum HelperErrorCode {
    static let none = 0
    static let accessibilityDenied = 1
    static let tapCreateFailed = 2
    static let alreadyMonitoring = 3
}
