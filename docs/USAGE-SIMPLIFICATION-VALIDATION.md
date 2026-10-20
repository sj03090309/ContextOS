# Usage simplification and local rollout — 2026-10-15 UTC

## Kept and removed

- Kept observed tokens, estimated development activity, concurrent AI session states, daily/provider/model/project breakdowns, source health, last aggregation time, missing versus explicit zero, and stale labels.
- Removed daily usage budget entry, persistence access, cache-key input, shared JSON member, threshold arithmetic and sample threshold. Old JSON budget fields are ignored on decode and never re-encoded. No preference file or historical usage was deleted. Context-optimization response-size budgets are unrelated and remain intact.
- Consolidated unsupported tools into an explicit named “수집 미지원” line instead of repeated empty session cards. Partial/unavailable supported providers keep full status sections. Removed an unsupported promise of future collection.
- Small Mungchi is optional; no perpetual widget animation was added. Numbers and source status stay primary. Manual timer and foreground observation remain in existing secondary tools; neither is confused with automatic activity.
- Activity widget uses the same phase label as the app. Missing activity preserves “연결 필요 · 미관측 · 일부 누락”; it cannot appear as zero or merely a generic partial warning.
- Standalone production packaging now registers its already-supported `contextos://usage` detail route. No new App Group was added to production.

## Architecture review

Token accounting is owned by ConcurrentUsageReader, activity by the central host ledger. Widgets and the VS Code status bar display frozen snapshots, without integrating elapsed time themselves. Existing tests cover duplicated token/cache records, bounded reading, day/time-zone boundaries, time union, disconnect/reconnect, idle/resume and restore without filling gaps. Memoized token reads refresh observation time while retaining provider latest-event timestamps; they do not claim new provider activity.

The important unresolved deployment boundary is real: `com.contextos.app` has no App Group entitlement, whereas the installed native widget is `com.contextos.review.widgets`, reading the approved review group. Review is intentionally synthetic for token data. The time candidate has no extension or group. Therefore a functioning native extension and current review snapshot do **not** prove production token/activity sharing. Giving the production host a shared-group entitlement is a security configuration change that must be reported/approved first; this rollout does not silently add one. Both installed hosts retain their existing receiver opt-in defaults (off); the prior time candidate's opt-in is not copied to another bundle ID.

WidgetKit controls refresh cadence. The 90-second activity stale label describes a frozen estimate; it is not a promise of real-time refresh. See [Apple's update guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

## Verification boundaries

Full unsandboxed local macOS regression: 93 XCTest + 253 Swift Testing tests passed after the functional changes. Sandboxed runs failed FSEvents/socket checks; the same tests passed with normal host access. Node bridge unit checks: 10 passed. Final Release app and native arm64/x86_64 extension builds passed; installed production and Review hosts are version 2.1.0, build 2103. Both running paths and installed/backup hashes match the deployment record. Synthetic light/dark render matrix: 84 PNGs, including all three sizes, long names, extreme values, missing, zero, unsupported, stale, disconnected, optional mascot and missing activity. These PNGs are layout evidence, not desktop-widget screenshots.

Existing screen-capture and Accessibility permissions were checked without requesting new permissions. Window-only screenshots of the installed production usage window and Review layout tab verify real macOS app windows, absence of the budget row, and three-size layout. The Review layout screenshot prominently says it is not an installed desktop-widget screenshot. The production window visibly reports Claude partial collection and “위젯: 공유 권한 설정 필요”; the latter matches its absent App Group entitlement. Its source-partial label is retained, not guessed to be a quota/budget warning. Actual desktop-widget warning text and real-profile VS Code status-bar/idle-resume remain separate checks; do not infer their success from test fixtures. No financial project files or workflows were accessed.

## Recovery

The installer validates exact bundle IDs and signatures, terminates only the two approved target apps normally, stages and verifies replacement bundles, and retains each original bundle under `artifacts/install-backups/<UTC timestamp>/`. It changes app bundles only, never a database, preferences, usage history or log. Installed hashes, original hashes and exact backup paths are recorded in `artifacts/budget-install-result*.json`.

Rollback: terminate only the app at the target path, preserve the current bundle as another backup, move the corresponding retained original bundle back to its recorded target, verify its signature, then open that exact app. Do not launch backup bundles in place, since that may register duplicate extension IDs. No push, notarization or public deployment is part of this change.


## Evidence paths

- `artifacts/budget-v2103-final-tests.log`: final 93 XCTest + 253 Swift Testing pass.
- `artifacts/budget-bridge-unit-tests.log`: 10 Node pass.
- `artifacts/budget-release-final-build.log`, `budget-free-final-v2103-widget-build.log`: Release host and both native widget architectures.
- `artifacts/budget-installed-production-usage-v2103.png`: actual production window, opened via `contextos://usage`.
- `artifacts/budget-installed-review-widget-layouts-v2103.png`: actual Review window, layout-only, synthetic token counts.
- `artifacts/budget-postinstall-verification.json`: installed 2103 hashes and retained previous bundle hashes verified, production group absent / review group unchanged.
- `artifacts/install-backups/20261015T154917Z/`: original 2101 production app and Oct13 original review app, preserved before any replacement. Later timestamps retain intermediate 2102 as well.

No normal-profile VS Code setting was enabled or rewritten; prior isolated Extension Host and synthetic IPC tests are documented separately. Real connected status-bar equality, five-minute idle/resume, native desktop-widget rendering and long-duration performance are not claimed complete. No new accessibility/screen-capture grant was requested: both preflight checks returned true before the targeted window capture and tab press.


Follow-up build 2104 adds explicit test headers/gallery naming and defaults production storage to rejecting samples, while keeping App Group rights unchanged. Its 347-test result, deployment record and proposed permission boundary are documented in [Production widget connection plan](PRODUCTION-WIDGET-CONNECTION-PLAN.md). The new group's creation and real production widget connection are still unapproved and unexecuted.
