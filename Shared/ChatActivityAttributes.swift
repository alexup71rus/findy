import ActivityKit

struct ChatActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
    }

    var sessionID: String
}
