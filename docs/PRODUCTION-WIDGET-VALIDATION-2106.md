# Production widget connection — installed build 2106

Current status: build **2107 is installed**, with real non-sample group delivery verified. See [final installed status and locked-session limitations](PRODUCTION-WIDGET-FINAL-STATUS.md). Version-specific and blocked-stage descriptions below are historical.


## Actual deployment

After direct approval of normal termination, backup, replacement, widget registration and launch, the previously rejected operation succeeded. The operating app at `~/Desktop/ContextOS.app` is now version 2.1.0, build **2106**, with embedded WidgetKit extension `com.contextos.app.widgets`. Both use only approved group `Y56BH9PULD.com.contextos.usage` and existing Apple Development signing team `Y56BH9PULD`. Review remains unchanged on its separate review group. No new certificate/profile, wider collection or public deployment occurred.

`artifacts/production-widget-install-result-2105.json` records the first replacement and retained build 2104. `artifacts/production-widget-install-result.json` records the follow-up replacement and retained build 2105 at `artifacts/production-install-backups/20261016T001120Z/ContextOS.app`. Installed and rollback hashes were checked. Current executable SHA256: `27a84345c046ca84a5c0dbbfb70816f12e9949c74d49ffdfc5cda0e570191fff`. Original pre-widget app backups remain retained as well.

The real production group was created by the app and contains non-sample `usage-v1.json`. The first 2105 payload was 1,162 bytes; the corrected 2106 payload was 891 bytes, below the unchanged 256KiB cap. It contains seven daily slots, aggregate ranks/source freshness and time state only. The real app window showed **“위젯: 집계 공유됨”**; see `artifacts/production-v2105-actual-usage.png`. This screenshot predates the accounting fix below and must not be used as a current-token-value or desktop-widget screenshot.

## Accounting defect found on the real Mac

The actual app displayed Claude records with model `<synthetic>` and zero usage. Such placeholder records do not establish a real model's observed zero. Build 2106 excludes that exact reserved-model record from accounting/model assignment/work-signal interpretation and marks the source partial. It does not edit or delete the original log.

Regression tests establish that placeholder-only records produce missing usage, a real model's explicit zero remains zero, and a placeholder does not overwrite a real model or its token total. The installed 2106 runtime payload now has **no confirmed today count (`nil` / UI `—`)**, rather than the earlier zero. No current model ranks are fabricated; one older observed day remains in the week. Claude partial status remains visible. The currently supported/bounded records do not establish the user's complete current AI usage, and the absence of current accounting must not be described as no AI activity or zero consumption.

## Verification completed

- Full Swift regression after the source fix: **93 XCTest + 259 Swift Testing = 352 passed**, `artifacts/production-real-source-tests.log`.
- Earlier bridge/ownership changes: Node unit + real temporary IPC **11 passed** (`production-widget-bridge-tests.log`). Earlier official Extension Host test passed with bridge disabled and synthetic document events. None of these assert real-profile connectivity or human coding activity.
- Release build and WidgetKit arm64/x86_64 builds/signing passed (`production-real-source-release.log`, `production-real-source-package-sign.log`). The signed candidate's Mach-O instruction-section hash matches the latest Release binary (`production-v2106-provenance.json`). Both installed and previous-backup executable hashes match their records.
- 84 synthetic size/light/dark/state renders remain under `artifacts/production-widget-renders`; inspected long model labels and large counts fit. These are layout checks, not desktop-widget screenshots.
- Real production host-to-group delivery is confirmed. Extension registration is confirmed. Actual non-preview extension consumption and desktop pixels are separate checks, still pending.

## Current native-screen and activity boundary

A targeted ContextOS host-window capture succeeded for build 2105. Before adding production widgets or connecting the real editor, the Mac session became locked: `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"] == true`, foreground `com.apple.loginwindow`. No unlock, credentials, whole-desktop capture or other-app document inspection was attempted.

Because the new production extension has a different identity, existing **Review widgets remain test widgets**. Production widgets still need to be added while the session is unlocked. Registering the extension does not silently convert Review tiles. The production-only OSLog snapshot category is available to distinguish preview from non-preview timeline reads after addition; no such read has been claimed yet.

The real-profile VS Code bridge and operating receiver were not enabled or rewritten during locked-screen verification. Current activity is unobserved/missing, never zero. Activity uses the documented focus/interaction window with five-minute idle classification, heartbeat/connection leases, overlap union and no filling of sleep/restart gaps; it is an estimate, not exact human coding/thinking or AI execution time.

## Bounded runtime observation

A read-only monitor observes only the production process and aggregate file, without forcing foreground refresh, to check one normal ten-minute closed-panel refresh interval. It records CPU/RSS and aggregate generation times under `artifacts/production-bounded-runtime*`. This is a bounded operating observation, not a long-duration stability, leak, unattended-operation or profitability certification. Consult its result file for whether the refresh advanced within the bounded window.

## Remaining actions

After unlocking the Mac, add the production **ContextOS · AI 사용량** widget in all three sizes (not **ContextOS 테스트 · 샘플**), confirm actual non-preview timeline reads, values/freshness and screenshots. Connect the previously approved local metadata bridge and verify real-profile idle/resume/reconnect and equality of the host/status-bar/small-widget last snapshot. Stop if an additional OS permission outside the approved group/previous collection is requested.

Rollback: normally quit the exact operating app, retain the current bundle, restore its recorded prior bundle and verify hash/signature. Keep the production group, new private activity store and legacy records for preservation; do not delete history or reset unrelated widgets. The 2104 fallback lacks production group access, so restoring it also restores that known limitation.
