# ContextOS production widgets — current status (2026-10-16 UTC)

## Installed and verified

Production `~/Desktop/ContextOS.app` is **2.1.0 / build 2107**, containing actual WidgetKit extension `com.contextos.app.widgets`. The operating host and extension use only approved group `Y56BH9PULD.com.contextos.usage`, signed by the existing development team. Exact signatures/entitlement sets and extension registration passed. Review stays separate and explicitly labeled as test/sample. No new certificate/profile, public deployment or extra collection permission was introduced.

Current deployment and rollback hashes match `artifacts/production-v2107-postinstall.json` and `production-widget-install-result.json`. The immediate prior 2106 bundle is retained at `artifacts/production-install-backups/20261016T003115Z/ContextOS.app`; earlier 2104/2105 and original pre-widget bundles remain retained too. Original source logs, preferences and the legacy private activity file were not deleted. Restore the recorded previous bundle after normally quitting the exact app; preserve current/new group and activity files rather than deleting data.

The operating app creates real **non-sample** aggregate JSON in the production group. Latest verified size: **890 bytes**, under the unchanged 256KiB limit. The exact shared Swift decoder accepts the real JSON in production mode (`production-v2107-shared-swift-reader.json`), with seven daily slots, `isSample=false`, missing today usage and a non-stale aggregation timestamp. This decoder probe is not a WidgetKit process/sandbox/render test. The earlier actual host-window screenshot `production-v2105-actual-usage.png` showed “위젯: 집계 공유됨”; its old zero value predates the placeholder fix and is not current evidence of consumption.

## Accounting corrections

1. Claude `<synthetic>` model records no longer turn missing accounting into observed zero or replace a real model. A real model's explicit zero remains zero. Actual installed output changed from zero to missing (`nil`, shown as `—`). Supported/bounded local records currently do not establish today's complete usage; do not describe this as no AI activity or no consumption. Partial-source status is retained.
2. A fixture reproduced incorrect same-time cumulative ordering: lexical order of `999` and `1000` created an artificial reset. Metrics now retain known accounting order; duplicate copies prefer the record with more preceding accounting context, not the larger file-local delta from a truncated copy. Known real resets preserve their order. Independent equal-time fragments without ordering retain their observed high-water counter and explicitly mark the source partial instead of inventing a reset. The fixture failed before and passed after this change; an effect on the current user's aggregate is not asserted. The current week aggregate was unchanged across this correction.

These operations do not edit raw logs, infer costs, estimate subscription remaining, or restore the removed daily budget feature. Internal order metadata does not enter the shared JSON. Existing file/metric/read bounds remain unchanged.

## Tests and build evidence

- Final full regression: **93 XCTest + 261 Swift Testing = 354 passed**, `artifacts/production-counter-order-tests.log`.
- Reproduction before fix: `equal-timestamp-counter-repro.log` (intentional failing fixture).
- Bridge unit + actual temporary Unix IPC: **11 passed**, `production-widget-bridge-tests.log`; events and clock are synthetic, not real user coding.
- Release host and native WidgetKit arm64/x86_64 builds/signing passed: `production-counter-order-final-release.log`, `production-counter-order-package-sign.log`. Intel compilation is not an Intel runtime or new remote-CI result.
- 84 synthetic light/dark/size/state PNGs under `production-widget-renders`; long model labels and extreme counts visually checked. These are layout renders, not desktop-widget screenshots.

## Bounded real operating observation

On installed **2106**, before the final order-only correction, a read-only monitor sampled the same real process 16 times over **450.9 seconds**. Without forcing foreground refresh, the aggregate generation advanced by **601.4 seconds**, matching one normal ten-minute closed-panel refresh cycle. Sampled CPU was 0.0%; sampled RSS ranged 9,616–15,296 KiB. These are idle locked-session samples, not peak/visible-UI memory, leak or long-duration guarantees. The monitor exited; no recurring automation or sleep-prevention process was left running. Evidence: `production-bounded-runtime-result.json`, `production-bounded-runtime-summary.json`, `production-bounded-runtime.jsonl`.

## Remaining external boundary

The Mac session is **locked**, confirmed with the session lock flag and foreground `com.apple.loginwindow`. No unlock, credentials, whole-desktop capture or other-app document inspection was attempted. Consequently:

- The new production widgets have not been added to the desktop or physically inspected. Registration and successful host-to-group delivery do not prove extension consumption or rendered pixels. Existing Review tiles remain test widgets; choose **ContextOS · AI 사용량**, not **ContextOS 테스트 · 샘플**, after unlocking.
- Real non-preview WidgetKit read logs and all three actual desktop screenshots remain pending. The production extension logs only request/family/preview/channel/generation metadata, never counts or project names, to support this check.
- The real-profile VS Code connection/operating receiver were not enabled or rewritten while locked. Production receiver preference is still unset/off, and activity is unobserved/missing, not zero. After connecting the previously approved metadata bridge, real-profile idle/resume/reconnect and host/status-bar/widget-snapshot consistency still need verification. Activity is the documented five-minute interaction-window estimate, not exact human coding/thinking or AI execution time.

Automatic installation review's earlier block was resolved by direct user approval; **there is no remaining installation approval request**. Unlocking the session is the remaining prerequisite for the GUI/real-editor checks. No complete unattended-operation, long-duration stability or financial profitability claim is supported by this ContextOS work.
