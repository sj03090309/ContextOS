# Native widgets and concurrent AI usage

This candidate adds a real WidgetKit app extension, `NativeWidgets/ContextOSWidgets.xcodeproj`, targeting macOS 14 (the existing app minimum). It is embedded under `Contents/PlugIns` by `scripts/package_widgets.sh`. The three families share a single widget kind:

- Small: today's observed tokens, comparison against the full previous day, budget threshold, source health, last aggregation time.
- Medium: today's total, seven-day spark bars, and tool usage bars (Codex/Claude Code).
- Large: seven-day bars and observed sum, today's model ranking, seven-day project ranking.

The menu-bar dashboard also has an **AI 동시 세션** entry opening a larger live dashboard. This is independent of the widgets. It lists every discovered supported main session, its last lifecycle evidence, today's tokens and its retained-log total. App presence is a separate desktop-app observation and never establishes work or tokens. CLI process presence is not observed; the UI says so. Unsupported sources have no invented zero or workload.

## Data scope and accounting

`ConcurrentUsageReader` reads the already-supported local Codex `~/.codex/sessions/**/rollout-*.jsonl` and Claude Code `~/.claude/projects/*/*.jsonl` formats. No API keys, account APIs, network calls or private application databases are involved. Its typed decoder has no prompt/text/tool-input/output fields. JSONL bytes containing these fields must pass through a line buffer, but those fields are never materialized as strings, retained, displayed or serialized by this collector. Symlink files/directories are skipped; read errors are surfaced as partial/unavailable without bypassing permissions. Tests and the review launch use generated fixtures only.

- Codex uses deltas of `total_token_usage.total_tokens`. Cached input and reasoning output are **not added again**. An observed lower cumulative counter starts a new segment. Identical timestamp/counter events are idempotent. Model attribution comes only from `turn_context.model`; missing models are explicit. Forks with `forked_from_id` are excluded and flagged partial because their cumulative history may include a parent session.
- Claude counts `input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens`. These cache counters are disjoint from uncached input. Repeated/streamed `message.id` usages replace the earlier message total with the larger observed total. Top-level main sessions only; sidechains and subagent directories are excluded.
- Session identity uses tool + provider session ID, never PID. Inode/replacement/truncation invalidates a file's incremental state. Logs without stable session IDs are excluded and flagged partial because copied logs cannot then be safely deduplicated; do not interpret these as complete account usage.
- Dates are re-bucketed from event timestamps with a Gregorian calendar in the selected local time zone, including DST. A day without an accounting event is `nil`/`—`, not a fabricated zero. The previous-day comparison is explicitly against that **whole** day. Unknown dates, malformed/future/negative counters and unreadable logs are not zero.
- Combined tokens are an observed-count total, not comparable compute units, money, or subscription remaining. No costs or subscription estimates are shown. The daily token budget is a user-entered local threshold only.
- Work uses lifecycle metadata. Quiet unfinished work becomes waiting, then unknown after one hour; silence never invents completion. A desktop application can remain open while all observed turns are idle.

Widget JSON contains only version, aggregation date/time zone, seven daily totals, top-three tool/model/project display labels and counts, provider source states/timestamps, an optional user budget and an explicit preview marker. It excludes session IDs, full paths and raw events. Project labels use only basename plus a short disambiguator. A missing/invalid/version-mismatched shared snapshot displays a connection-needed state. Atomic writes retain the old valid snapshot after failure; stale/midnight timeline entries label it as old data.

## Build and review

```sh
swift test
swift build -c release
scripts/package_widgets.sh --review --binary-dir "$(swift build -c release --show-bin-path)" --output dist/widget-review
```

The review candidate uses `com.contextos.review`, a distinct `contextos-review://usage` URL scheme and `com.contextos.review.widgets`. It never replaces the operational app. Launch the generated review bundle with `--usage-review` to inspect synthetic dashboards and all widget render bodies without starting any live collectors, project scans or usage databases. This harness is **not** proof of WidgetKit installation.

Omit `--review` when later preparing an approved production candidate. `contextos://usage` routes to the AI usage dashboard. The route accepts only the exact host and no query/path, so a widget cannot request arbitrary project paths or operations.

## Signing / shared-container gate

No Apple account, certificate, App Group registration, provisioning profile or entitlement is created by this change. The local packaging script signs ad hoc and intentionally leaves `ContextOSAppGroup` empty. This verifies code, bundle structure and local renderability; it does **not** enable app-to-extension data access.

Before live widget installation, obtain approval for the concrete team/group choice. Both app and extension need an existing authorized matching `com.apple.security.application-groups` entitlement and `ContextOSAppGroup` Info.plist entry. The extension also needs its sandbox entitlement and appropriate signing/provisioning for the chosen distribution route. Set both targets to the same approved team, sign nested code before the host, then verify a write/read of `usage-v1.json` through `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. Never substitute a guessed `~/Library/Group Containers` path or bypass this gate.

After an approved installation, launch the containing app once, add each size through macOS Edit Widgets, confirm current/empty/partial/stale states and click through to the exact candidate's usage dashboard. These installed-widget checks require the real signed environment and remain separate from view screenshots and unsigned compilation.

The app requests reloads at most once per 15 minutes after successful aggregate writes. The provider requests a new timeline after 30 minutes and schedules stale/midnight display transitions. macOS chooses actual reload timing; this is not a real-time display. No notification or WidgetKit push entitlement is needed.

## Sources checked

- [Apple: Creating a widget extension](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)
- [Apple: Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Apple: Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [OpenAI Codex protocol TokenUsage](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)
- [Anthropic: Prompt caching usage counters](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#tracking-cache-performance)

These local log adapters are format-specific. A newly unsupported format is incomplete collection, not permission to invent measurements.

## Review evidence and limits

The 2026-10-12 candidate is isolated from the original checkout's uncommitted Windows preparation work. Tests use disposable generated logs, including parallel Codex/Claude sessions. The review app uses fixtures and is labelled accordingly. Validation does not inspect the user's real prompts or unrelated project logs; therefore simultaneous live-provider operation is not claimed as exercised on this Mac. The Mac review window and exported render matrix verify the UI, while installed WidgetKit delivery and App Group sharing require the approved signing step above.

The visual revision uses a small ContextOS character, a mint surface in light appearance and a forest surface in dark appearance. Small prioritizes today's count, medium shows tool shares, and large gives the week more space. Source problems, stale data, last aggregation time and budget warnings remain visible. Extremely large counts switch to short scientific notation rather than truncating the number.
# Approved local review signing

The isolated review app can be packaged with `scripts/sign_review_widgets.sh
<existing-signing-identity-SHA1> <new-output-directory>`. This explicit path
uses the reviewed Personal Team `Y56BH9PULD` and the macOS team-prefixed group
`Y56BH9PULD.com.contextos.review.usage`. It signs only the review bundle IDs,
verifies the resulting team, and never installs, creates a certificate, logs
into an account, or uploads a build. Keep the default unsigned packaging path
for portable builds. The review entitlements must be reviewed again before
changing the team or group.

The review app writes **synthetic fixtures only** to the configured shared
container and labels them as sample data. Opening the normal host continues
to use the existing real collectors. A successful review-app write does not
verify live personal usage or the WidgetKit host's rendering and refresh.
