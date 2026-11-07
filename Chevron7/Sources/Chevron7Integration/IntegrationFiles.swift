import Foundation
import Darwin
import CryptoKit

public struct IntegrationFileSnapshot: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let byteCount: Int
    public let sha256: String

    public var json: JSONValue {
        .object(["name": .string(name), "byteCount": .number(Double(byteCount)), "sha256": .string(sha256)])
    }
}

public struct IntegrationDeliveredFile: Sendable, Equatable {
    public let url: URL
    public let byteCount: Int
    public let sha256: String
    public var path: String { url.path }
    public var json: JSONValue {
        .object(["path": .string(path), "byteCount": .number(Double(byteCount)), "sha256": .string(sha256)])
    }
}

/// nil roots are unrestricted local CLI access; an empty root list authorizes nothing.
public struct IntegrationFileScope: Sendable {
    public let roots: [URL]?

    public init(roots: [URL]? = nil) throws {
        self.roots = try roots.map { values in
            try values.map { value in
                // The helper canonicalizes launch-time roots once. Re-resolving
                // here would let a later symlink substitution change authority.
                let resolved = value.standardizedFileURL
                let descriptor = open(resolved.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard descriptor >= 0 else { throw fileError("Cannot open permitted root directory.") }
                defer { close(descriptor) }
                let actual = try descriptorURL(descriptor)
                guard actual.path == resolved.path else {
                    throw IntegrationError(code: "ACCESS_DENIED", message: "Permitted root changed or is not a canonical directory.")
                }
                return actual
            }
        }
    }

    public func contains(_ url: URL) -> Bool {
        guard let roots else { return true }
        return roots.contains { root in
            url.path == root.path || url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
        }
    }

    public func read(path: String, maxBytes: Int = IntegrationLimits.maximumInputBytes) throws -> Data {
        guard maxBytes >= 0, !path.isEmpty, !path.utf8.contains(0) else {
            throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Invalid local file path or size limit.")
        }
        // O_NONBLOCK prevents a FIFO substituted for the input from hanging open().
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw fileError("Cannot open input as a regular local file.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw fileError("Only regular local files are accepted.")
        }
        guard contains(try descriptorURL(descriptor)) else {
            throw IntegrationError(code: "ACCESS_DENIED", message: "Input lies outside the permitted roots.")
        }
        guard info.st_size >= 0, info.st_size <= maxBytes else { throw tooLarge() }
        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw fileError("Input could not be read.")
            }
            if count == 0 { break }
            guard count <= maxBytes - result.count else { throw tooLarge() }
            result.append(contentsOf: buffer.prefix(count))
        }
        // The bytes belong to the opened inode even if its original path was replaced.
        return result
    }

    public func snapshot(path: String, in directory: URL,
                         maxBytes: Int = IntegrationLimits.maximumInputBytes) throws -> IntegrationFileSnapshot {
        let data = try read(path: path, maxBytes: maxBytes)
        let name = Self.sanitizedName(URL(fileURLWithPath: path).lastPathComponent)
        let url = directory.appendingPathComponent(UUID().uuidString + "-" + name)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw fileError("Cannot create private input snapshot.") }
        var succeeded = false
        defer { close(descriptor); if !succeeded { unlink(url.path) } }
        try writeAll(data, descriptor: descriptor)
        succeeded = true
        return IntegrationFileSnapshot(url: url, name: name, byteCount: data.count, sha256: digest(data))
    }

    public func reserveOutput(path: String) throws -> IntegrationOutputReservation {
        try IntegrationOutputReservation(path: path, scope: self)
    }

    public static func sanitizedName(_ value: String) -> String {
        let basename = (value as NSString).lastPathComponent
        let filtered = basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" && $0 != "/" }
        let name = String(String.UnicodeScalarView(filtered))
        return name.isEmpty || name == "." || name == ".." ? "document" : name
    }
}

/// Holds the destination directory open and publishes with an exclusive atomic rename.
/// A replaced pathname cannot redirect the write and an existing output is never overwritten.
public final class IntegrationOutputReservation: @unchecked Sendable {
    public let url: URL
    private let scope: IntegrationFileScope
    private let parentURL: URL
    private let parentFD: Int32
    private let temporaryName: String
    private let finalName: String
    private var descriptor: Int32
    private var delivered: IntegrationDeliveredFile?
    private var bytes: Int?
    private var hash: String?
    private let lock = NSLock()

    fileprivate init(path: String, scope: IntegrationFileScope) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw fileError("Invalid output path.") }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let name = target.lastPathComponent
        guard name != ".", name != "..", !name.isEmpty, name != "/" else { throw fileError("Invalid output filename.") }
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw fileError("Output directory is unavailable.") }
        do {
            let actualParent = try descriptorURL(directoryFD)
            guard scope.contains(actualParent) else {
                throw IntegrationError(code: "ACCESS_DENIED", message: "Output lies outside the permitted roots.")
            }
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw IntegrationError(code: "OUTPUT_EXISTS", message: "Output already exists; choose a new file.")
            }
            let temporary = ".chevron7-" + UUID().uuidString + ".tmp"
            let fileFD = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fileFD >= 0 else { throw fileError("Cannot reserve an output file.") }
            self.url = actualParent.appendingPathComponent(name)
            self.scope = scope
            self.parentURL = actualParent
            self.parentFD = directoryFD
            self.temporaryName = temporary
            self.finalName = name
            self.descriptor = fileFD
        } catch { close(directoryFD); throw error }
    }

    deinit { discard(); close(parentFD) }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, delivered == nil, bytes == nil else {
            throw fileError("Output reservation is no longer writable.")
        }
        guard data.count <= IntegrationLimits.maximumOutputBytes else { throw tooLarge() }
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw fileError("Cannot prepare the reserved output.")
        }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw fileError("Cannot flush the signed output.") }
        bytes = data.count
        hash = digest(data)
    }

    public func publish() throws -> IntegrationDeliveredFile {
        lock.lock()
        defer { lock.unlock() }
        if let delivered { return delivered }
        guard descriptor >= 0, let bytes, let hash else { throw fileError("Output has not been written.") }
        let actualParent = try descriptorURL(parentFD)
        guard actualParent == parentURL, scope.contains(actualParent) else {
            throw IntegrationError(code: "OUTPUT_DELIVERY_FAILED", message: "Output directory changed before delivery.")
        }
        // The parent path itself may now refer to a replacement directory.
        var held = stat(), current = stat()
        guard fstat(parentFD, &held) == 0, stat(parentURL.path, &current) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
            throw IntegrationError(code: "OUTPUT_DELIVERY_FAILED", message: "Output directory was replaced before delivery.")
        }
        var openedFile = stat(), namedFile = stat()
        guard fstat(descriptor, &openedFile) == 0,
              fstatat(parentFD, temporaryName, &namedFile, AT_SYMLINK_NOFOLLOW) == 0,
              (namedFile.st_mode & S_IFMT) == S_IFREG,
              openedFile.st_dev == namedFile.st_dev, openedFile.st_ino == namedFile.st_ino else {
            throw IntegrationError(code: "OUTPUT_DELIVERY_FAILED", message: "Reserved output was replaced before delivery.")
        }
        guard renameatx_np(parentFD, temporaryName, parentFD, finalName, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno == EEXIST ? "OUTPUT_EXISTS" : "OUTPUT_DELIVERY_FAILED"
            throw IntegrationError(code: code, message: "Signed output could not be delivered without replacing an existing file.")
        }
        close(descriptor)
        descriptor = -1
        let result = IntegrationDeliveredFile(url: url, byteCount: bytes, sha256: hash)
        delivered = result
        return result
    }

    public func discard() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
        unlinkat(parentFD, temporaryName, 0)
    }
}

private func descriptorURL(_ descriptor: Int32) throws -> URL {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw fileError("Cannot resolve the opened file.") }
    return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).standardizedFileURL
}

private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw fileError("Cannot write the output file.") }
            offset += count
        }
    }
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func fileError(_ message: String) -> IntegrationError { IntegrationError(code: "FILE_ACCESS", message: message) }
private func tooLarge() -> IntegrationError { IntegrationError(code: "FILE_TOO_LARGE", message: "File exceeds the permitted size.") }
