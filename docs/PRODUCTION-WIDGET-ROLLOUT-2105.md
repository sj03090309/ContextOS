# Build 2105: prepared, operating installation blocked

Latest status: direct approval resolved the earlier execution-policy block. Production build 2106 is installed and writes real non-sample aggregates to the approved group. See [current verification and remaining locked-screen checks](PRODUCTION-WIDGET-VALIDATION-2106.md). Earlier blocked/proposal descriptions below are historical.


The user approved production group `Y56BH9PULD.com.contextos.usage` for `com.contextos.app` and embedded `com.contextos.app.widgets`, signed with the existing development identity. No new certificate, account operation or profile was created. Review remains separate.

Prepared candidate: `artifacts/production-widgets-v2105/ContextOS.app`. Existing team `Y56BH9PULD`, exact approved group entitlements and signatures passed verification. Full Swift regression: 93 XCTest + 257 Swift Testing = 350 pass (`artifacts/production-widget-tests.log`). Node unit/real temporary IPC: 11 pass. Release host and native arm64/x86_64 widget builds passed. 84 synthetic layout PNGs were regenerated; they are not desktop-widget screenshots.

Production activity persistence is gated on successful receiver socket readiness and a current generation lease. A competing receiver cannot remove the owner's socket. Production has a separate private 16KiB activity store, with same-user/private-directory validation. Same-day validated legacy activity is imported only if the destination is absent, restored paused/partial, and the original is retained. Review/candidate code cannot enable the production receiver. Existing endpoint compatibility is preserved. Widget JSON retains its 256KiB bound and excludes raw prompts, content and credentials.

Automatic approval review rejected operating-app replacement, widget registration and launch twice. It did not accept delegated approval evidence as a clear direct user-authored revocation of the initial no-replacement restriction. No workaround deployment was attempted. Read-only verification confirmed the operating app remains build 2104 and the production group does not exist. Original backups remain retained.

Candidate executable SHA256: `35da84703d99c72d7bffa3c14ac282d8485b6c1cbb78bcb83cec707db1857702`. Operating 2104 SHA256: `fb2f1ffcae71bca4deb9155c4d9475ab9723f4c15d770d66f41465ee333a4423`.

The prepared single-target installer has an old-hash guard, signature validation, normal termination of the exact app, retained backup and atomic replacement with rollback. It has not executed. Direct execution-policy approval of quitting/backing up/replacing the operating app, registering its embedded widget and launching it is still required; the group itself was already approved by the user.

Actual production container writes, real-profile bridge connection, idle/resume, non-preview WidgetKit reads, desktop screenshots and operating soak remain unverified. No claim of long-duration stability, complete unattended operation or financial profitability follows from these tests. After future installation, preserve all old/new aggregates when rolling back the app; do not delete user history or reset unrelated widgets.
