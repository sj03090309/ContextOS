# Third-party notices

ContextOS's CLI links Apple's **swift-argument-parser**, licensed under the Apache License 2.0 with Runtime Library Exception. Its full license and copyright notice are in `ThirdPartyLicenses/swift-argument-parser.txt` and included in the packaged app. `Package.swift` pins the tested dependency to version 1.8.2 for reproducible builds.

Foundation, SwiftUI, AppKit, CoreServices, CryptoKit, ServiceManagement and SQLite3 are supplied by the macOS/Swift SDK; their respective platform licenses apply. No provider logos are bundled by this change: existing UI code reads installed app icons locally. App icon, mascot and existing assets still require the owner's rights review before external distribution.

This notice does not choose or grant a license for ContextOS itself. The repository owner must decide and publish ContextOS's license or commercial terms before a public binary release or sale; see `docs/RELEASE.md`.
