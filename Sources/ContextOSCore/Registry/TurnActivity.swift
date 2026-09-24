import Foundation

/// Whether an agent is mid-turn, and until when that answer holds.
public struct TurnVerdict: Sendable, Equatable {
    public var working: Bool
    /// The instant the verdict can next change with no new event arriving —
    /// when a quiet window runs out. Nil means only a new event can change it.
    public var recheckAt: Date?
    /// The answer depends on whether the newest session log ends on an
    /// unanswered tool call. The caller has to read the log's tail (see
    /// `AgentActivityMonitor.hasPendingToolCall`) and evaluate again with it.
    public var needsPendingCheck: Bool

    public init(working: Bool, recheckAt: Date? = nil, needsPendingCheck: Bool = false) {
        self.working = working
        self.recheckAt = recheckAt
        self.needsPendingCheck = needsPendingCheck
    }
}

/// Decides "is an agent working right now?" from the signals the menu-bar app
/// receives — hook and heartbeat notifications, and session-log writes — and
/// says when the answer could next flip on its own.
///
/// That second part is what lets the app sleep between events instead of
/// polling. Every signal is a timestamp, and each one keeps the agent "working"
/// for a fixed window after it, so the verdict can only change when an event
/// arrives or when one of those windows closes; the app sets a single timer for
/// the earliest close and is otherwise idle.
public enum TurnActivity {

    /// How long a heartbeat, a turn start or a log write keeps the agent working.
    public static let window: TimeInterval = 20

    /// How long an unanswered tool call keeps a quiet log alive. One long tool —
    /// a build, a test suite, a big install — writes nothing until it returns,
    /// but a call that never returns (the agent died mid-tool) must not pin the
    /// mascot on forever.
    public static let pendingToolCap: TimeInterval = 15 * 60

    /// - Parameters:
    ///   - lastActivity: the latest turn start (UserPromptSubmit hook) or MCP
    ///     tool-call heartbeat.
    ///   - lastStop: the latest turn end (Stop hook).
    ///   - lastLogWrite: when the newest session log was last written, if any.
    ///   - pendingToolCall: whether that log ends on an unanswered tool call, if
    ///     known. Only consulted when the log has been quiet longer than the
    ///     window; when it is needed and nil, the verdict asks for it.
    public static func evaluate(now: Date,
                                lastActivity: Date,
                                lastStop: Date,
                                lastLogWrite: Date?,
                                pendingToolCall: Bool? = nil,
                                window: TimeInterval = window,
                                pendingToolCap: TimeInterval = pendingToolCap) -> TurnVerdict {
        // An explicit Stop that landed after the last sign of activity ends the
        // turn, and nothing reopens it until a new turn start or tool call — both
        // of which arrive as events. In particular the session log's quiet
        // window must not revive it: the agent keeps touching its log for a
        // moment after it finishes.
        guard lastStop <= lastActivity else { return TurnVerdict(working: false) }

        var working = false
        var recheck: Date?
        // Only called for a signal still inside its window, so the deadline is
        // never in the past; one landing exactly on `now` still gets a recheck,
        // or a turn caught on the boundary would stay "working" until the next
        // event.
        func holds(until deadline: Date) {
            working = true
            recheck = min(recheck ?? deadline, deadline)
        }

        if now.timeIntervalSince(lastActivity) <= window {
            holds(until: lastActivity.addingTimeInterval(window))
        }
        if let written = lastLogWrite {
            let quiet = now.timeIntervalSince(written)
            if quiet <= window {
                holds(until: written.addingTimeInterval(window))
            } else if quiet <= pendingToolCap {
                guard let pending = pendingToolCall else {
                    return TurnVerdict(working: working, recheckAt: recheck, needsPendingCheck: true)
                }
                // A pending call can only be answered by a write to the log,
                // which is an event; otherwise it lapses at the cap.
                if pending { holds(until: written.addingTimeInterval(pendingToolCap)) }
            }
        }
        return TurnVerdict(working: working, recheckAt: recheck)
    }
}
