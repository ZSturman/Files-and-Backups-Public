import Foundation

/// A daily wall-clock time in the Mac's local time zone (default 02:00).
public struct DailySchedule: Codable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public static let `default` = DailySchedule(hour: 2, minute: 0)

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// The slot for the calendar day containing `date`. On a spring-forward
    /// day where the time does not exist, the slot moves to the next valid
    /// time (02:00 → 03:00); on a fall-back day the first occurrence is used.
    public func slot(onDayOf date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        return calendar.nextDate(after: start.addingTimeInterval(-1), matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? start
    }

    /// Most recent slot at or before `now`.
    public func mostRecentSlot(atOrBefore now: Date, calendar: Calendar) -> Date {
        let today = slot(onDayOf: now, calendar: calendar)
        if today <= now { return today }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        return slot(onDayOf: yesterday, calendar: calendar)
    }

    public func nextSlot(after now: Date, calendar: Calendar) -> Date {
        let today = slot(onDayOf: now, calendar: calendar)
        if today > now { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return slot(onDayOf: tomorrow, calendar: calendar)
    }
}

/// Scheduler bookkeeping persisted per job.
public struct SchedulerState: Codable, Hashable, Sendable {
    /// The scheduled slot most recently started (successful or not).
    public var lastHandledSlot: Date?
    public var lastAttemptAt: Date?
    /// Last successful snapshot created by any trigger.
    public var lastSuccessAt: Date?
    public var lastSuccessSnapshotID: String?
    /// Last successful snapshot started by the daily schedule or catch-up.
    public var lastScheduledSuccessAt: Date?
    /// The startup/wake/reconnect event that the last catch-up consumed.
    public var lastCatchUpTrigger: Date?
    /// Failed scheduled/catch-up runs since the last success (bounded retry).
    public var consecutiveFailures: Int = 0
    public var lastFailureAt: Date?
    /// Destination availability at the previous tick (reconnect detection).
    public var destinationWasAvailable: Bool?
    public var lastReconnectAt: Date?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case lastHandledSlot, lastAttemptAt, lastSuccessAt, lastSuccessSnapshotID, lastScheduledSuccessAt
        case lastCatchUpTrigger, consecutiveFailures, lastFailureAt, destinationWasAvailable, lastReconnectAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastHandledSlot = try c.decodeIfPresent(Date.self, forKey: .lastHandledSlot)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastSuccessSnapshotID = try c.decodeIfPresent(String.self, forKey: .lastSuccessSnapshotID)
        lastScheduledSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastScheduledSuccessAt)
        lastCatchUpTrigger = try c.decodeIfPresent(Date.self, forKey: .lastCatchUpTrigger)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        lastFailureAt = try c.decodeIfPresent(Date.self, forKey: .lastFailureAt)
        destinationWasAvailable = try c.decodeIfPresent(Bool.self, forKey: .destinationWasAvailable)
        lastReconnectAt = try c.decodeIfPresent(Date.self, forKey: .lastReconnectAt)
    }
}

public enum RunReason: String, Codable, Sendable {
    case scheduled
    case catchUp
    /// Automatic retry after a failed scheduled or catch-up run.
    case retry
    case manual
}

public enum ScheduleDecision: Equatable, Sendable {
    case run(RunReason, slot: Date?)
    case wait(until: Date)
    case waitForDestination
}

public enum ProtectionStatus: Equatable, Sendable {
    /// No successful snapshot has been recorded for this source.
    case unprotected
    case current(lastSuccess: Date)
    /// More than 26 hours since the last successful snapshot.
    case overdue(lastSuccess: Date, hours: Int)

    public static let warningInterval: TimeInterval = 26 * 3600

    public static func evaluate(lastSuccess: Date?, now: Date) -> ProtectionStatus {
        guard let lastSuccess else { return .unprotected }
        let age = now.timeIntervalSince(lastSuccess)
        if age > warningInterval { return .overdue(lastSuccess: lastSuccess, hours: Int(age / 3600)) }
        return .current(lastSuccess: lastSuccess)
    }
}

public enum Scheduler {
    /// A scheduled slot still runs if noticed within this window; later than
    /// that it is a missed slot, handled by catch-up instead.
    public static let slotGrace: TimeInterval = 3600
    public static let catchUpInterval: TimeInterval = 24 * 3600

    /// Decides what a periodic tick should do.
    ///
    /// - Parameters:
    ///   - systemEvent: Most recent startup or wake time.
    ///   - destinationAvailable: Whether the backup destination validated.
    public static func decide(
        now: Date, schedule: DailySchedule, state: SchedulerState, systemEvent: Date?,
        destinationAvailable: Bool, calendar: Calendar
    ) -> (ScheduleDecision, SchedulerState) {
        var state = state
        let wasAvailable = state.destinationWasAvailable
        state.destinationWasAvailable = destinationAvailable
        guard destinationAvailable else { return (.waitForDestination, state) }
        if wasAvailable == false { state.lastReconnectAt = now }

        let slot = schedule.mostRecentSlot(atOrBefore: now, calendar: calendar)
        if state.lastHandledSlot.map({ $0 < slot }) ?? true, now.timeIntervalSince(slot) <= slotGrace {
            state.lastHandledSlot = slot
            state.lastAttemptAt = now
            return (.run(.scheduled, slot: slot), state)
        }

        let needsCatchUp = state.lastScheduledSuccessAt.map { now.timeIntervalSince($0) >= catchUpInterval } ?? true
        let trigger = [systemEvent, state.lastReconnectAt].compactMap { $0 }.max()
        if needsCatchUp, let trigger, trigger <= now, state.lastCatchUpTrigger.map({ $0 < trigger }) ?? true {
            state.lastCatchUpTrigger = trigger
            state.lastAttemptAt = now
            // A catch-up also covers the slot it replaces.
            if state.lastHandledSlot.map({ $0 < slot }) ?? true { state.lastHandledSlot = slot }
            return (.run(.catchUp, slot: nil), state)
        }

        // Bounded retry after a transient failure (network blip, Pi reboot):
        // up to `retryDelays.count` attempts, spaced 15/30/60 minutes.
        if needsCatchUp, state.consecutiveFailures > 0, state.consecutiveFailures <= retryDelays.count,
           let failedAt = state.lastFailureAt,
           now.timeIntervalSince(failedAt) >= retryDelays[state.consecutiveFailures - 1] {
            state.lastAttemptAt = now
            return (.run(.retry, slot: nil), state)
        }

        return (.wait(until: schedule.nextSlot(after: now, calendar: calendar)), state)
    }

    public static let retryDelays: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]

    /// Records a finished run.
    public static func record(success: Bool, reason: RunReason, snapshotID: String?, finishedAt: Date, state: SchedulerState) -> SchedulerState {
        var state = state
        guard success else {
            // Manual runs never trigger automatic retries.
            if reason != .manual {
                state.consecutiveFailures += 1
                state.lastFailureAt = finishedAt
            }
            return state
        }
        state.consecutiveFailures = 0
        state.lastFailureAt = nil
        state.lastSuccessAt = finishedAt
        state.lastSuccessSnapshotID = snapshotID
        if reason != .manual { state.lastScheduledSuccessAt = finishedAt }
        return state
    }
}
