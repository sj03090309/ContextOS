import Foundation

/// Edits one JSON value without serializing the rest of the document. Strict
/// JSON and unique keys are required; malformed or JSONC input is left intact.
struct JSONSettingsEditor {
    private(set) var data: Data
    let file: String

    init(_ data: Data?, file: String) throws {
        self.data = data ?? Data("{}\n".utf8)
        self.file = file
        try validate()
    }

    func value(_ path: [String]) throws -> Data? {
        var node = try tree()
        for key in path {
            guard let members = node.members else { throw SettingsSafetyError.invalid(file) }
            guard let member = members.first(where: { $0.key == key }) else { return nil }
            node = member.value
        }
        return data.subdata(in: node.range)
    }

    mutating func set(_ path: [String], to value: Data?) throws {
        guard let key = path.last else { throw SettingsSafetyError.invalid(file) }
        let parents = Array(path.dropLast())
        for index in parents.indices {
            let prefix = Array(parents.prefix(index + 1))
            if try self.value(prefix) == nil { try set(prefix, to: Data("{}".utf8)) }
        }
        var object = try tree()
        for parent in parents {
            guard let member = object.members?.first(where: { $0.key == parent }) else { throw SettingsSafetyError.invalid(file) }
            object = member.value
        }
        guard let members = object.members else { throw SettingsSafetyError.invalid(file) }
        if let index = members.firstIndex(where: { $0.key == key }) {
            let member = members[index]
            if let value { data.replaceSubrange(member.value.range, with: value) }
            else {
                let start = index == 0 ? member.keyStart : members[index - 1].value.range.upperBound
                let end = index == 0 && members.count > 1 ? members[1].keyStart : member.value.range.upperBound
                data.removeSubrange(start..<end)
            }
        } else if let value {
            let keyData = try Self.encode(key)
            var insertion = Data((members.isEmpty ? "\n  " : ",\n  ").utf8)
            insertion.append(keyData); insertion.append(Data(": ".utf8)); insertion.append(value)
            insertion.append(Data("\n".utf8))
            data.insert(contentsOf: insertion, at: object.range.upperBound - 1)
        }
        try validate()
    }

    static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    }

    static func equal(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b else { return a == b }
        guard let x = try? JSONSerialization.jsonObject(with: a, options: .fragmentsAllowed) as? NSObject,
              let y = try? JSONSerialization.jsonObject(with: b, options: .fragmentsAllowed) as? NSObject else { return false }
        return x.isEqual(y)
    }

    private func validate() throws {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw SettingsSafetyError.invalid(file) }
        _ = try tree()
    }

    private func tree() throws -> Node {
        var parser = Parser(bytes: Array(data), file: file)
        let result = try parser.node()
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw SettingsSafetyError.invalid(file) }
        return result
    }

    private struct Member { var key: String; var keyStart: Int; var value: Node }
    private struct Node { var range: Range<Int>; var members: [Member]? }
    private struct Parser {
        let bytes: [UInt8]
        let file: String
        var index = 0
        mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func node() throws -> Node {
            whitespace(); let start = index
            guard index < bytes.count else { throw SettingsSafetyError.invalid(file) }
            var members: [Member]?
            if bytes[index] == 123 {
                index += 1; whitespace(); members = []
                var keys = Set<String>()
                while index < bytes.count, bytes[index] != 125 {
                    whitespace(); let keyStart = index
                    let keyRange = try string()
                    guard let key = try JSONSerialization.jsonObject(with: Data(bytes[keyRange]), options: .fragmentsAllowed) as? String,
                          keys.insert(key).inserted else { throw SettingsSafetyError.invalid(file) }
                    whitespace(); guard index < bytes.count, bytes[index] == 58 else { throw SettingsSafetyError.invalid(file) }
                    index += 1
                    members?.append(Member(key: key, keyStart: keyStart, value: try node()))
                    whitespace()
                    if index < bytes.count, bytes[index] == 44 { index += 1 } else { break }
                }
                guard index < bytes.count, bytes[index] == 125 else { throw SettingsSafetyError.invalid(file) }
                index += 1
            } else if bytes[index] == 91 {
                index += 1; whitespace()
                while index < bytes.count, bytes[index] != 93 {
                    _ = try node(); whitespace()
                    if index < bytes.count, bytes[index] == 44 { index += 1 } else { break }
                }
                guard index < bytes.count, bytes[index] == 93 else { throw SettingsSafetyError.invalid(file) }
                index += 1
            } else if bytes[index] == 34 { _ = try string() }
            else { while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 } }
            return Node(range: start..<index, members: members)
        }
        mutating func string() throws -> Range<Int> {
            let start = index
            guard index < bytes.count, bytes[index] == 34 else { throw SettingsSafetyError.invalid(file) }
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { index += 1; return start..<index }
                index += 1
            }
            throw SettingsSafetyError.invalid(file)
        }
    }
}
