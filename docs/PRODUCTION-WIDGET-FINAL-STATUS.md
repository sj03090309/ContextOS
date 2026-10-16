# ContextOS production widgets — current status (2026-10-16 UTC)

Production and isolated Review are installed as **2.1.0 / build 2109**. The transparent SwiftUI lifecycle scene that reproduced an extra blank window has been removed. AppKit owns one populated usage detail window. Actual operating small-widget cold/warm/repeat clicks, fully closed-window re-entry, and separate URL flows were confirmed with window identity, content and screenshots. Review remains synthetic-only and was not deleted.

Full regression: **356 Swift tests + 11 bridge/temporary IPC tests passed**, including fresh post-reconnect runs. Release/native WidgetKit packaging, installed hashes/backups and normal-environment signatures passed. Existing identities/groups and user history are preserved; no push, new permission, credential or public deployment occurred. The current correction is documented in [2109 validation](PRODUCTION-WIDGET-VALIDATION-2109.md).

The operating UI identifies observed CLI/desktop/editor/SDK metadata and explicitly limits its token claim to available local records. Explicit subagent sources cannot double count the parent scope. **Full current dot/cloud usage remains unobserved**: stale lifetime local counters were not reassigned to today or added to the weekly graph. Missing is shown as `—`, not fabricated zero. See the validation record for source evidence and the difference between missing sources and excluded duplicate/inherited counters.

Actual screenshots include `artifacts/usage-window-widget-cold2109.png`, `usage-window-widget-after-close2109.png` and `usage-window-review2109.png`. Six native light/dark loading/empty/error fixtures are clearly synthetic and separate from production. The gallery distinguishes app names, but cached Review previews do not prove updated sample captions everywhere. Original attachment pixels/initial clicked target, complete dot coverage, VS Code status-bar letters, desktop arrangement and long-duration guarantees remain unverified.

Earlier disconnected PID27834 was confirmed absent. This pass's finite keepalive PID52825 was released at **08:46:25 UTC (17:46:25 Korea)** and its assertions were verified absent. Permanent sleep/lock/security settings were not changed.

Detailed retained deployment records: `artifacts/production-widget-install-result.json`, `production-v2109-postinstall.json`, `usage-window-2109-summary.json`, `codex-observable-coverage.json`, `contextos-qa-awake.json`. The former 2108 status remains in Git history at commit `41f43b5`; historical accounting and rollout reports remain in this directory.
