enum ForegroundEditors {
    private static let catalog: [(name: String, bundleIDs: [String])] = [
        ("VS Code", ["com.microsoft.VSCode"]),
        ("VS Code Insiders", ["com.microsoft.VSCodeInsiders"]),
        ("Cursor", ["com.todesktop.230313mzl4w4u92"]),
        ("Xcode", ["com.apple.dt.Xcode"]),
        ("IntelliJ IDEA", ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        ("PyCharm", ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        ("Android Studio", ["com.google.android.studio"]),
        ("CLion", ["com.jetbrains.CLion"]),
        ("DataGrip", ["com.jetbrains.datagrip"]),
        ("GoLand", ["com.jetbrains.goland"]),
        ("PhpStorm", ["com.jetbrains.PhpStorm"]),
        ("Rider", ["com.jetbrains.rider"]),
        ("RubyMine", ["com.jetbrains.rubymine"]),
        ("RustRover", ["com.jetbrains.rustrover"]),
        ("WebStorm", ["com.jetbrains.WebStorm"]),
    ].map { name, bundleIDs in
        (name, bundleIDs.flatMap { id in
            id.hasPrefix("com.jetbrains.") ? [id, id + "-EAP"] : [id]
        })
    }

    private static let labelsByBundleID = Dictionary(uniqueKeysWithValues: catalog.flatMap { editor in
        editor.bundleIDs.map { ($0.lowercased(), editor.name) }
    })

    static func label(for bundleID: String?) -> String? {
        bundleID.flatMap { labelsByBundleID[$0.lowercased()] }
    }

    static func bundleIdentifiers(for name: String) -> [String] {
        catalog.first { $0.name == name }?.bundleIDs ?? []
    }

    static func installedNames(isInstalled: (String) -> Bool) -> [String] {
        catalog.filter { $0.bundleIDs.contains(where: isInstalled) }.map(\.name)
    }
}
