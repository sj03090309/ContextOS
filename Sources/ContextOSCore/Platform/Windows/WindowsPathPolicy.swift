import Foundation

/// A conservative namespace policy, followed by native handle checks. Passing
/// this policy alone never authorizes opening a file or enabling the runtime.
enum WindowsPathPolicy {
    static func relative(_ path: String) throws -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.utf16.count < 32_700 else { throw WindowsNativeError.invalidPath }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ validComponent(String($0)) }) else { throw WindowsNativeError.invalidPath }
        return parts.joined(separator: "/")
    }

    static func localRoot(_ path: String) throws -> String {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        // Foundation URL paths may contain the leading slash before C:.
        if normalized.hasPrefix("/") && normalized.dropFirst().prefix(3).last == "/" {
            normalized.removeFirst()
        }
        let characters = Array(normalized.prefix(3).utf8)
        guard characters.count == 3, (65...90).contains(characters[0]) || (97...122).contains(characters[0]),
              characters[1] == 58, characters[2] == 47 else { throw WindowsNativeError.invalidPath }
        let suffix = try relative(String(normalized.dropFirst(3)))
        return String(normalized.prefix(3)) + suffix
    }

    static func singleName(_ path: String) throws -> String {
        let normalized = try relative(path)
        guard !normalized.contains("/") else { throw WindowsNativeError.invalidPath }
        return normalized
    }

    private static func validComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component.utf16.count <= 255, component != ".", component != "..",
              !component.hasSuffix("."), !component.hasSuffix(" "),
              !component.unicodeScalars.contains(where: { $0.value < 32 || "<>:\"/\\|?*".unicodeScalars.contains($0) }) else { return false }
        let stem = String(component.split(separator: ".", omittingEmptySubsequences: false)[0])
            .trimmingCharacters(in: .init(charactersIn: " ")).uppercased()
        if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(stem) { return false }
        let reservedDigits = "123456789¹²³"
        if stem.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT")),
           let digit = stem.last, reservedDigits.contains(digit) { return false }
        return true
    }
}
