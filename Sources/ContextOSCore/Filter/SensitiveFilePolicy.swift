import Foundation

/// Conservative filename protection, independent of a project's ignore rules.
/// This is not a detector for secrets embedded inside otherwise allowed source.
public enum SensitiveFilePolicy {
    private static let names: Set<String> = [
        ".env", ".envrc", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_dsa",
        "id_ecdsa", "id_ed25519", "credentials", "credentials.json", "credentials.yml",
        "credentials.yaml", "auth.json", "token.json", "tokens.json", "secrets.json",
        "secrets.yml", "secrets.yaml", "secrets.toml", "secrets.ini",
        "application_default_credentials.json"
    ]
    private static let suffixes = [".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".mobileprovision", ".env"]
    private static let directories: Set<String> = [".ssh", ".aws", ".gnupg", ".contextos-backups"]

    public static func isSensitivePath(_ path: String) -> Bool {
        let parts = path.replacingOccurrences(of: "\\", with: "/").lowercased().split(separator: "/").map(String.init)
        if parts.contains(where: { directories.contains($0) }) { return true }
        guard let name = parts.last else { return false }
        if names.contains(name) || name.hasPrefix(".env.") || suffixes.contains(where: { name.hasSuffix($0) }) { return true }
        if ["json", "yaml", "yml", "toml", "ini", "conf", "txt"].contains((name as NSString).pathExtension) {
            return name.hasPrefix("service-account") || name.hasPrefix("service_account")
                || name.hasSuffix("-credentials.json") || name.hasSuffix("_credentials.json")
                || name.hasPrefix("secrets.")
        }
        return false
    }

    static func isSensitiveRoot(_ root: URL) -> Bool { isSensitivePath(root.path) }

    /// Do not echo excluded filenames from a request into MCP diagnostics or
    /// persist them in the local usage log. No original contents are logged.
    public static func redactingReferences(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[^\s\"'<>`,;()\[\]{}=]+"#) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            let candidate = token.split(separator: ":", maxSplits: 1).first.map(String.init) ?? token
            if isSensitivePath(candidate) { result.replaceSubrange(range, with: "[민감 파일]") }
        }
        return result
    }
}
