import Foundation
import Darwin

public enum SettingsSafetyError: Error, LocalizedError, Equatable {
    case invalid(String), conflict(String), unowned, noBackup, busy, rollbackConflict

    public var errorDescription: String? {
        switch self {
        case .invalid(let file): return "\(file)의 설정 형식이 올바르지 않거나 안전하게 수정할 수 없습니다. 원본은 그대로 두었습니다."
        case .conflict(let file): return "\(file)이 미리보기 이후 변경되었습니다. 적용을 중단했습니다. 새 미리보기를 확인해 주세요."
        case .unowned: return "이 연결의 관리 기록이 없습니다. ‘연결 설정’에서 미리보기를 확인한 뒤 관리 기록을 만들 수 있습니다. 기존 등록은 지우지 않았습니다."
        case .noBackup: return "복구할 ContextOS 설정 백업이 없습니다."
        case .busy: return "다른 ContextOS 설정 변경이 진행 중입니다. 잠시 후 다시 시도해 주세요."
        case .rollbackConflict: return "변경 중 다른 프로그램이 설정을 수정했습니다. 그 내용을 덮어쓰지 않았습니다. 로컬 백업을 보존했으니 설정을 확인해 주세요."
        }
    }
}

struct SettingsChange: Codable, Sendable {
    var relativePath: String
    var before: Data?
    var after: Data?
    var permissions: Int
}

struct SettingsBackup: Codable, Sendable {
    var id: UUID
    var agent: String
    var action: String
    var date: Date
    var committed: Bool
    var changes: [SettingsChange]
}

/// Byte snapshots, a local advisory lock, private backups and optimistic conflict
/// checks. Rollback only replaces bytes still equal to what this operation wrote.
struct SettingsTransaction {
    let home: URL
    var backupRoot: URL { home.appendingPathComponent(".contextos-backups") }

    func url(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw SettingsSafetyError.invalid("설정 경로")
        }
        let target = home.appendingPathComponent(relative).standardizedFileURL
        let root = home.standardizedFileURL.path
        guard target.path.hasPrefix(root + "/") else { throw SettingsSafetyError.invalid("설정 경로") }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: home.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            throw SettingsSafetyError.invalid(target.lastPathComponent)
        }
        var current = target
        while current.path != root {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: current.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw SettingsSafetyError.invalid(target.lastPathComponent)
            }
            current.deleteLastPathComponent()
        }
        return target
    }

    func read(_ relative: String) throws -> Data? {
        let file = try url(relative)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 10_000_000 else {
            throw SettingsSafetyError.invalid(file.lastPathComponent)
        }
        return try Data(contentsOf: file)
    }

    func change(_ relative: String, after: Data?) throws -> SettingsChange {
        let target = try url(relative)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) ?? 0o600
        return SettingsChange(relativePath: relative, before: try read(relative), after: after, permissions: permissions)
    }

    static func text(_ data: Data?, file: String, missing: String = "") throws -> String {
        guard let data else { return missing }
        guard let text = String(data: data, encoding: .utf8) else { throw SettingsSafetyError.invalid(file) }
        return text
    }

    @discardableResult
    func apply(_ changes: [SettingsChange], agent: String, action: String,
               beforeWrite: ((Int) throws -> Void)? = nil) throws -> URL? {
        let changes = changes.filter { $0.before != $0.after }
        guard !changes.isEmpty else { return nil }
        try secureDirectory(backupRoot)
        let lockURL = backupRoot.appendingPathComponent("operation.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SettingsSafetyError.busy }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SettingsSafetyError.busy }
        defer { flock(fd, LOCK_UN) }
        for change in changes { try check(change, expected: change.before) }
        var backup = SettingsBackup(id: UUID(), agent: agent, action: action,
                                    date: Date(), committed: false, changes: changes)
        let history = backupRoot.appendingPathComponent("history")
        try secureDirectory(history)
        let backupURL = history.appendingPathComponent(backup.id.uuidString + ".json")
        try privateWrite(try JSONEncoder().encode(backup), at: backupURL)
        var written: [SettingsChange] = []
        do {
            for (index, change) in changes.enumerated() {
                try beforeWrite?(index)
                try check(change, expected: change.before)
                try write(change.after, relative: change.relativePath, permissions: change.permissions)
                written.append(change)
            }
            // Also notice edits to an earlier file while later files were written.
            for change in written { try check(change, expected: change.after) }
            backup.committed = true
            try privateWrite(try JSONEncoder().encode(backup), at: backupURL)
            return backupURL
        } catch {
            var conflict = false
            for change in written.reversed() {
                do {
                    try check(change, expected: change.after)
                    try write(change.before, relative: change.relativePath, permissions: change.permissions)
                } catch { conflict = true }
            }
            if conflict { throw SettingsSafetyError.rollbackConflict }
            throw error
        }
    }

    func latestBackup(agent: String) throws -> SettingsBackup {
        let history = try url(".contextos-backups/history")
        let files = (try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? []
        let records = try files.filter { $0.pathExtension == "json" }.compactMap { file -> SettingsBackup? in
            let relative = ".contextos-backups/history/" + file.lastPathComponent
            guard let data = try read(relative), let backup = try? JSONDecoder().decode(SettingsBackup.self, from: data),
                  backup.agent == agent, backup.committed, backup.action != "restore" else { return nil }
            return backup
        }
        guard let latest = records.max(by: { $0.date < $1.date }) else { throw SettingsSafetyError.noBackup }
        return latest
    }

    private func check(_ change: SettingsChange, expected: Data?) throws {
        guard try read(change.relativePath) == expected else {
            throw SettingsSafetyError.conflict((change.relativePath as NSString).lastPathComponent)
        }
    }

    private func write(_ data: Data?, relative: String, permissions: Int) throws {
        let file = try url(relative)
        if let data {
            let parent = file.deletingLastPathComponent()
            if relative.hasPrefix(".contextos-backups/") { try secureDirectory(parent) }
            else { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
            // Set the mode before the atomic rename, never exposing a backup or
            // new credential-bearing configuration through a world-readable temp.
            let temp = parent.appendingPathComponent(".contextos-write-" + UUID().uuidString)
            let handle = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions))
            guard handle >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            Darwin.close(handle)
            defer { try? FileManager.default.removeItem(at: temp) }
            try data.write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            guard Darwin.rename(temp.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func secureDirectory(_ directory: URL) throws {
        let relative = String(directory.path.dropFirst(home.standardizedFileURL.path.count + 1))
        _ = try url(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func privateWrite(_ data: Data, at file: URL) throws {
        let relative = String(file.path.dropFirst(home.standardizedFileURL.path.count + 1))
        try write(data, relative: relative, permissions: 0o600)
    }
}
