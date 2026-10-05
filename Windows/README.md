# ContextOS Windows preparation shell

WPF on .NET 10, initial Windows 11 x64 target. The Mac SwiftUI app stays intact.
This is a developer validation output, not an installer or a working Windows
ContextOS release. Projects, activity, and AI connection share the Mac information
structure. Missing metrics are unknown; project/connection actions stay disabled.

Use `scripts/check_windows.ps1` on a prepared Windows developer/CI host. It builds
the shared Swift peers, creates disposable native security fixtures, generates
the GUI identity from the verified Swift contract, compiles WPF, and runs the
headless contract/layout self-test. The resulting shell expects owned binaries
under `runtime/` beside its executable. Runtime DLLs are supplied by the existing
developer toolchain; redistribution and signing remain future work.

No third-party UI package is used. .NET's WPF framework/reference packs come from
Microsoft. The protected native primitives are internal candidates; Windows
index storage, settings transactions/rollback, watching, dashboard data, agent
adapters, shared updater and customer packaging remain inactive or unimplemented.
Native fixture success cannot enable production commands by itself.
