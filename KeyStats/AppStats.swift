import Foundation

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
