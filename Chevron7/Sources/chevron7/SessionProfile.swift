// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Darwin
import Chevron7Integration

enum SessionProfile {
    static func validName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count) && name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func capability(name: String, directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Chevron7CLI")) throws -> String {
        guard validName(name) else { throw CLIOptions.invalid("Invalid session profile name.") }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw failure() }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              flock(parent, LOCK_EX) == 0 else { throw failure() }
        defer { flock(parent, LOCK_UN) }
        let file = openat(parent, name + ".session", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw failure() }
        defer { close(file) }
        guard fstat(file, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size <= 37 else { throw failure() }
        if info.st_size == 0 {
            let bytes = Array((UUID().uuidString + "\n").utf8)
            guard bytes.withUnsafeBytes({ write(file, $0.baseAddress, $0.count) }) == bytes.count, fsync(file) == 0 else { throw failure() }
        }
        var buffer = [UInt8](repeating: 0, count: 38)
        let count = pread(file, &buffer, buffer.count, 0)
        guard count == 37, let text = String(bytes: buffer.prefix(count), encoding: .utf8), UUID(uuidString: String(text.dropLast())) != nil else { throw failure() }
        return String(text.dropLast())
    }

    private static func failure() -> IntegrationError { IntegrationError(code: "FILE_ACCESS", message: "Cannot securely open the CLI session profile. It must be owned by this user, private, and contain no symlinks or hard links.") }
}
