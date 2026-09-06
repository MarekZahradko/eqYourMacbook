// Wire protocol of the app's local control channel (EQControlChannel.swift): the
// DistributedNotificationCenter names, commands and state-snapshot keys.
//
// Foundation-only ON PURPOSE: the bench tool under scripts/eqym-ctl/ compiles this exact
// file alongside their own sources, so there is one definition of the protocol (SSOT)
// and no hand-copied string literals on either side. Keep it free of app types.
//
// Security model: any local process can drive the channel, exactly as any local
// process can click the menu bar. It exposes nothing the UI does not (enable/disable,
// A/B bypass, read state); personal-use app, not sandboxed (see the entitlements file —
// a sandboxed app could not post userInfo on distributed notifications at all).

import Foundation

enum EQControlProtocol {
    /// Posted BY tools; `userInfo[Keys.command]` names an `EQControlCommand`,
    /// `userInfo[Keys.requestID]` (optional String) is echoed in the reply.
    static let commandNotification = Notification.Name("com.zdenekkops.eqyourmacbook.control")
    /// Posted BY the app: a full `EQControlSnapshot` every time state changes, and once per
    /// received command as the reply (`Keys.event` == "reply", `Keys.requestID` echoed).
    static let stateNotification = Notification.Name("com.zdenekkops.eqyourmacbook.state")

    enum Keys {
        static let command = "command"
        static let requestID = "requestID"
        static let event = "event"                       // "reply" | "changed"
        static let timestamp = "timestamp"               // Double, seconds since 1970, set at post time
        static let enabled = "enabled"                   // Bool — master switch
        static let bypassed = "bypassed"                 // Bool — A/B bypass (path stays up)
        static let gainStaging = "gainStaging"           // Bool
        static let status = "status"                     // "active" | "disabled" | "permissionNeeded" | "error"
        static let statusDetail = "statusDetail"         // String — the menu's status line
        static let engineRunning = "engineRunning"       // Bool — a tap+aggregate is live right now
        static let deviceUID = "deviceUID"               // String, only when engineRunning
        static let deviceName = "deviceName"             // String, only when engineRunning
        static let sampleRate = "sampleRate"             // Double, only when engineRunning
        static let ioBufferFrames = "ioBufferFrames"     // Int, only when engineRunning and the pin read back
        static let excludedProcessObjects = "excludedProcessObjects"  // [Int] HAL process object IDs, only when engineRunning
        static let ownProcessObject = "ownProcessObject" // Int, our own HAL process object, only when engineRunning
    }

    enum Event: String {
        case reply
        case changed
    }
}

enum EQControlCommand: String, CaseIterable {
    case status
    case enable
    case disable
    case bypassOn = "bypass-on"
    case bypassOff = "bypass-off"
}

/// Everything the channel reports, as one value; `userInfo` is its plist-compatible wire
/// form (String/Bool/Int/Double/[Int] only — DistributedNotificationCenter rejects the rest).
struct EQControlSnapshot: Equatable {
    var enabled: Bool
    var bypassed: Bool
    var gainStaging: Bool
    var status: String
    var statusDetail: String
    var engineRunning: Bool
    var deviceUID: String?
    var deviceName: String?
    var sampleRate: Double?
    var ioBufferFrames: Int?
    var excludedProcessObjects: [Int]
    var ownProcessObject: Int?

    func userInfo(event: EQControlProtocol.Event, requestID: String?, timestamp: Date = Date()) -> [String: Any] {
        typealias K = EQControlProtocol.Keys
        var info: [String: Any] = [
            K.event: event.rawValue,
            K.timestamp: timestamp.timeIntervalSince1970,
            K.enabled: enabled,
            K.bypassed: bypassed,
            K.gainStaging: gainStaging,
            K.status: status,
            K.statusDetail: statusDetail,
            K.engineRunning: engineRunning,
            K.excludedProcessObjects: excludedProcessObjects,
        ]
        if let requestID { info[K.requestID] = requestID }
        if let deviceUID { info[K.deviceUID] = deviceUID }
        if let deviceName { info[K.deviceName] = deviceName }
        if let sampleRate { info[K.sampleRate] = sampleRate }
        if let ioBufferFrames { info[K.ioBufferFrames] = ioBufferFrames }
        if let ownProcessObject { info[K.ownProcessObject] = ownProcessObject }
        return info
    }

    /// nil when a required key is missing or mistyped (a foreign or truncated payload).
    init?(userInfo: [AnyHashable: Any]) {
        typealias K = EQControlProtocol.Keys
        guard let enabled = userInfo[K.enabled] as? Bool,
              let bypassed = userInfo[K.bypassed] as? Bool,
              let gainStaging = userInfo[K.gainStaging] as? Bool,
              let status = userInfo[K.status] as? String,
              let statusDetail = userInfo[K.statusDetail] as? String,
              let engineRunning = userInfo[K.engineRunning] as? Bool else { return nil }
        self.enabled = enabled
        self.bypassed = bypassed
        self.gainStaging = gainStaging
        self.status = status
        self.statusDetail = statusDetail
        self.engineRunning = engineRunning
        self.deviceUID = userInfo[K.deviceUID] as? String
        self.deviceName = userInfo[K.deviceName] as? String
        self.sampleRate = userInfo[K.sampleRate] as? Double
        self.ioBufferFrames = userInfo[K.ioBufferFrames] as? Int
        self.excludedProcessObjects = userInfo[K.excludedProcessObjects] as? [Int] ?? []
        self.ownProcessObject = userInfo[K.ownProcessObject] as? Int
    }

    init(enabled: Bool, bypassed: Bool, gainStaging: Bool, status: String, statusDetail: String,
         engineRunning: Bool, deviceUID: String? = nil, deviceName: String? = nil,
         sampleRate: Double? = nil, ioBufferFrames: Int? = nil, excludedProcessObjects: [Int] = [],
         ownProcessObject: Int? = nil) {
        self.enabled = enabled
        self.bypassed = bypassed
        self.gainStaging = gainStaging
        self.status = status
        self.statusDetail = statusDetail
        self.engineRunning = engineRunning
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.sampleRate = sampleRate
        self.ioBufferFrames = ioBufferFrames
        self.excludedProcessObjects = excludedProcessObjects
        self.ownProcessObject = ownProcessObject
    }
}

/// Reads the envelope fields of a state notification (shared by the app's tests and the tools).
extension EQControlProtocol {
    static func event(of userInfo: [AnyHashable: Any]) -> Event? {
        (userInfo[Keys.event] as? String).flatMap(Event.init(rawValue:))
    }
    static func requestID(of userInfo: [AnyHashable: Any]) -> String? {
        userInfo[Keys.requestID] as? String
    }
    static func timestamp(of userInfo: [AnyHashable: Any]) -> Date? {
        (userInfo[Keys.timestamp] as? Double).map { Date(timeIntervalSince1970: $0) }
    }
}
