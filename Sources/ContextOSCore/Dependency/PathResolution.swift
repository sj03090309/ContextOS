import Foundation

/// Shared heuristics for resolving import modules to indexed files.
///
/// Used by both the optimizer (graph expansion) and the dependency explorer, so
/// the resolution rules stay in exactly one place.
public enum PathResolution {

    /// File name without extension, e.g. "src/auth/login.py" → "login".
    public static func stem(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return String(name[name.startIndex..<dot])
        }
        return name
    }

    /// Last meaningful component of an import module, e.g. "./auth/login" → "login".
    public static func moduleStem(_ module: String) -> String {
        let parts = module.split { $0 == "/" || $0 == "." || $0 == ":" }
        return (parts.last.map(String.init) ?? module).lowercased()
    }
}
