import Foundation

/// Shared by ranking and delivery so an import cannot name different files in
/// the plan and the actual body. Only indexed project-relative paths resolve.
struct ProjectModuleResolver {
    let paths: Set<String>
    let stems: [String: [String]]
    init(paths: [String]) {
        self.paths = Set(paths)
        var byStem: [String: [String]] = [:]
        for path in paths { byStem[PathResolution.stem(of: path).lowercased(), default: []].append(path) }
        stems = byStem
    }

    func resolve(_ module: String, from path: String, language: Language) -> String? {
        if language != .python && language != .typescript && language != .javascript {
            let matches = stems[PathResolution.moduleStem(module)] ?? []
            return matches.count == 1 ? matches.first : nil
        }
        let directory = path.split(separator: "/").dropLast().map(String.init)
        func normalize(_ parts: [String]) -> String? {
            var result: [String] = []
            for part in parts where !part.isEmpty && part != "." {
                if part == ".." { guard !result.isEmpty else { return nil }; result.removeLast() }
                else { result.append(part) }
            }
            return result.joined(separator: "/")
        }
        var bases: [String] = []
        if language == .python {
            let dots = module.prefix(while: { $0 == "." }).count
            let suffix = module.dropFirst(dots).replacingOccurrences(of: ".", with: "/")
            if dots > 0 {
                guard dots - 1 <= directory.count else { return nil }
                bases = [(Array(directory.dropLast(dots - 1)) + [suffix]).filter { !$0.isEmpty }.joined(separator: "/")]
            } else { bases = [suffix, (directory + [suffix]).joined(separator: "/")] }
        } else if module.hasPrefix(".") {
            guard let base = normalize(directory + module.split(separator: "/").map(String.init)) else { return nil }
            bases = [base]
        } else { bases = [module] }
        for base in bases {
            var candidates = [base]
            if language == .python { candidates += [base + ".py", base + "/__init__.py"] }
            else {
                candidates += ["ts", "tsx", "js", "jsx"].map { base + "." + $0 }
                candidates += ["ts", "tsx", "js", "jsx"].map { base + "/index." + $0 }
                if base.hasSuffix(".js") { candidates += [String(base.dropLast(3)) + ".ts", String(base.dropLast(3)) + ".tsx"] }
            }
            if let match = candidates.first(where: { paths.contains($0) && !SensitiveFilePolicy.isSensitivePath($0) }) { return match }
        }
        guard !module.hasPrefix(".") && !module.contains("/") else { return nil }
        let stem = module.split(separator: ".").last.map(String.init) ?? module
        let matches = stems[stem.lowercased()] ?? []
        return matches.count == 1 ? matches.first : nil
    }

}
