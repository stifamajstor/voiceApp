import Foundation

/// Where one note's reminder stands for its current due time. There is one value per note, saved with
/// the note, and every alert decision follows from it. Nothing is inferred at check time from what
/// Notification Center holds, from the authorization at that moment, or from comparing clocks.
///
/// ```
/// set ─▶ scheduled ──request added──▶ handedToMacOS ──due time reached──▶ alerted
///            │                              │  ▲                              ▲
///            │                  withdrawn ──┘  └── (cap: back to scheduled)   │
///            └──due time reached──▶ missed ──catch-up posted─────────────────┘
/// ```
///
/// `alerted(dueAt)` is final for that due time. Only a new `set` leaves it.
public enum ReminderState: Equatable, Sendable {
    /// The note has no reminder.
    case idle
    /// Set for `dueAt`. No request for it is with macOS (yet), for example because notifications
    /// are off, permission was never asked, or 60 earlier reminders already fill macOS's window.
    case scheduled(dueAt: Date)
    /// A request for `dueAt` was added to macOS. macOS shows it at the due time.
    case handedToMacOS(dueAt: Date)
    /// `dueAt` passed and no request for it was with macOS. One catch-up alert is owed.
    case missed(dueAt: Date)
    /// The alert for `dueAt` is done, by macOS or by a catch-up. It is never scheduled or alerted
    /// again for this due time, whatever the clock or the notification settings do later.
    case alerted(dueAt: Date)

    public var dueAt: Date? {
        switch self {
        case .idle: return nil
        case .scheduled(let due), .handedToMacOS(let due), .missed(let due), .alerted(let due): return due
        }
    }

    /// The saved form of the state next to `dueAt`. `nil` while there is no reminder.
    public var phase: String? {
        switch self {
        case .idle: return nil
        case .scheduled: return "scheduled"
        case .handedToMacOS: return "handed"
        case .missed: return "missed"
        case .alerted: return "alerted"
        }
    }

    /// Reads the saved form. A due time without a recognisable phase is treated as scheduled, which
    /// at worst hands the request over again and never skips an alert.
    public init(dueAt: Date?, phase: String?) {
        guard let dueAt else { self = .idle; return }
        switch phase {
        case "handed": self = .handedToMacOS(dueAt: dueAt)
        case "missed": self = .missed(dueAt: dueAt)
        case "alerted": self = .alerted(dueAt: dueAt)
        default: self = .scheduled(dueAt: dueAt)
        }
    }

    /// Due times are the same due time when they agree to the millisecond, the precision of
    /// notification identifiers.
    public static func isSameDueTime(_ lhs: Date, _ rhs: Date) -> Bool { key(lhs) == key(rhs) }

    public static func key(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

/// Something that happened. The state changes only on these, each on its own.
public enum ReminderEvent: Equatable, Sendable {
    /// The user set or re-set the reminder, to any time, including the time it already has.
    case set(Date)
    case remove
    case done
    case delete
    /// The note text was edited. The reminder keeps its state.
    case edit
    /// The clock reached `Date`: a timer fired, VoiceApp launched, the Mac woke, the clock changed.
    case timeReached(Date)
    /// macOS accepted a request for this due time.
    case requestAdded(Date)
    /// VoiceApp took its request for this due time back from macOS to stay within the 60-request window.
    case requestWithdrawn(Date)
    /// macOS presented the request for this due time, or the user clicked it.
    case delivered(Date)
    /// VoiceApp posted the catch-up alert for this due time.
    case catchUpPosted(Date)
}

public enum ReminderStateMachine {
    /// The whole transition table. Events that name a due time apply only to that due time, so a late
    /// callback for a time the reminder was moved away from changes nothing.
    ///
    /// | event \ state      | idle | scheduled(d)   | handedToMacOS(d) | missed(d)      | alerted(d) |
    /// |--------------------|------|----------------|------------------|----------------|------------|
    /// | set(n)             | sch n| sch n          | sch n            | sch n          | sch n      |
    /// | remove/done/delete | idle | idle           | idle             | idle           | idle       |
    /// | edit               | idle | same           | same             | same           | same       |
    /// | timeReached(t)     | idle | t≥d: missed    | t≥d: alerted     | same           | same       |
    /// | requestAdded(x)    | idle | x=d: handed    | same             | same           | same       |
    /// | requestWithdrawn(x)| idle | same           | x=d: scheduled   | same           | same       |
    /// | delivered(x)       | idle | x=d: alerted   | x=d: alerted     | x=d: alerted   | same       |
    /// | catchUpPosted(x)   | idle | same           | same             | x=d: alerted   | same       |
    public static func next(_ state: ReminderState, _ event: ReminderEvent) -> ReminderState {
        switch event {
        case .set(let due):
            return .scheduled(dueAt: due)
        case .remove, .done, .delete:
            return .idle
        case .edit:
            return state
        case .timeReached(let now):
            switch state {
            case .scheduled(let due) where due <= now: return .missed(dueAt: due)
            case .handedToMacOS(let due) where due <= now: return .alerted(dueAt: due)
            default: return state
            }
        case .requestAdded(let due):
            if case .scheduled(let current) = state, ReminderState.isSameDueTime(current, due) {
                return .handedToMacOS(dueAt: current)
            }
            return state
        case .requestWithdrawn(let due):
            if case .handedToMacOS(let current) = state, ReminderState.isSameDueTime(current, due) {
                return .scheduled(dueAt: current)
            }
            return state
        case .delivered(let due):
            switch state {
            case .scheduled(let current), .handedToMacOS(let current), .missed(let current):
                return ReminderState.isSameDueTime(current, due) ? .alerted(dueAt: current) : state
            case .idle, .alerted:
                return state
            }
        case .catchUpPosted(let due):
            if case .missed(let current) = state, ReminderState.isSameDueTime(current, due) {
                return .alerted(dueAt: current)
            }
            return state
        }
    }
}

/// Which reminders to hand to macOS again even if a matching request is already pending.
public enum ReminderResubmit: Sendable {
    case none
    case notes(Set<UUID>)
    case all

    func includes(_ id: UUID) -> Bool {
        switch self {
        case .none: return false
        case .notes(let ids): return ids.contains(id)
        case .all: return true
        }
    }
}

/// What to do with the notification center for the current states. Pure: no I/O, no clock.
public struct ReminderPlan: Equatable, Sendable {
    /// Missed reminders that may alert now.
    public var catchUp: [UUID] = []
    /// Reminders inside the window that need a request added or replaced.
    public var hand: [UUID] = []
    /// Reminders that macOS holds but that fall outside the window.
    public var withdraw: [UUID] = []
    /// The next time something can happen without any outside event: the earliest due time of a reminder
    /// that is not yet alerted. Whether notifications are on does not matter here.
    public var nextWake: Date?

    /// `reminders` are the states after `timeReached(now)` was applied to each.
    ///
    /// - Parameters:
    ///   - authorized: Whether a request can be added right now. This is the only thing it decides.
    ///   - limit: How many requests macOS may hold at once.
    ///   - pending: Identifiers of the requests macOS holds, used only to repair a request that went missing.
    public static func make(_ reminders: [UUID: ReminderState], now: Date, authorized: Bool, limit: Int,
                            pending: Set<String>, resubmit: ReminderResubmit) -> ReminderPlan {
        func order(_ lhs: (id: UUID, due: Date), _ rhs: (id: UUID, due: Date)) -> Bool {
            lhs.due == rhs.due ? lhs.id.uuidString < rhs.id.uuidString : lhs.due < rhs.due
        }
        var plan = ReminderPlan()
        var upcoming: [(id: UUID, due: Date, handed: Bool)] = []
        var missed: [(id: UUID, due: Date)] = []
        for (id, state) in reminders {
            switch state {
            case .scheduled(let due) where due > now: upcoming.append((id, due, false))
            case .handedToMacOS(let due) where due > now: upcoming.append((id, due, true))
            case .missed(let due): missed.append((id, due))
            default: break
            }
        }
        upcoming.sort { order(($0.id, $0.due), ($1.id, $1.due)) }
        for (index, reminder) in upcoming.enumerated() {
            if index < limit {
                let lost = reminder.handed && !pending.contains(NoteNotification.identifier(for: reminder.id, due: reminder.due))
                if authorized, !reminder.handed || lost || resubmit.includes(reminder.id) { plan.hand.append(reminder.id) }
            } else if reminder.handed {
                plan.withdraw.append(reminder.id)
            }
        }
        if authorized { plan.catchUp = missed.sorted { order($0, $1) }.map(\.id) }
        plan.nextWake = upcoming.first?.due
        return plan
    }
}
