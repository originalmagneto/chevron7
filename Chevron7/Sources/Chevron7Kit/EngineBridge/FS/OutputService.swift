// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Darwin
import Foundation

public struct OutputReservation: Sendable {
    public let temporaryURL: URL
    public let finalURL: URL

}

public enum OutputServiceError: Error {
    case unsafeSource
    case unsafeTarget
    case sourceAndTargetAreIdentical
    case unableToReserveTemporaryFile
    case finalOutputAlreadyExists
    case unableToFinalize
}

public struct OutputService {
    private let validator = PDFArtifactValidator()

    public init() {}

    public func reserve(
        for sourceURL: URL,
        finalURL requestedFinalURL: URL? = nil,
        outputExtension: String? = nil
    ) throws -> OutputReservation {
        guard !isSymbolicLink(sourceURL) else { throw OutputServiceError.unsafeSource }
        let source = canonicalURL(sourceURL)
        let destination = try resolvedDestination(
            for: source,
            requestedFinalURL: requestedFinalURL,
            outputExtension: outputExtension
        )
        guard source != destination else { throw OutputServiceError.sourceAndTargetAreIdentical }

        let temporary = try reserveTemporarySibling(of: destination)
        return OutputReservation(temporaryURL: temporary, finalURL: destination)
    }

    /// Reserves a unique sibling output using the supplied suffix.
    ///
    /// The returned temporary file must be finalized with `finalize(_:)` or
    /// removed with `discard(_:)`.
    /// Finalization uses an exclusive move, so an output created concurrently
    /// cannot be replaced. `stem` replaces the source's own name when given.
    public func reserveUniqueSibling(
        for sourceURL: URL,
        in directoryURL: URL? = nil,
        stem requestedStem: String? = nil,
        stemSuffix: String = "_podpisane",
        outputExtension: String? = nil
    ) throws -> OutputReservation {
        guard !isSymbolicLink(sourceURL) else { throw OutputServiceError.unsafeSource }
        let source = canonicalURL(sourceURL)
        let rawDirectory = directoryURL ?? sourceURL.deletingLastPathComponent()
        guard !isSymbolicLink(rawDirectory) else { throw OutputServiceError.unsafeTarget }
        let directory = canonicalURL(rawDirectory)
        let stem = requestedStem ?? source.deletingPathExtension().lastPathComponent
        let destinationExtension = outputExtension ?? source.pathExtension
        var number = 1
        while true {
            let suffix = number == 1 ? stemSuffix : "\(stemSuffix) (\(number))"
            let candidate = directory
                .appending(path: stem + suffix)
                .appendingPathExtension(destinationExtension)
            if !pathExists(candidate) {
                let temporary = try reserveTemporarySibling(of: candidate)
                return OutputReservation(temporaryURL: temporary, finalURL: candidate)
            }
            number += 1
        }
    }

    /// Resolves the next collision-safe sibling for review without reserving it.
    ///
    /// This is a display preview only. Call `reserveUniqueSibling` at execution
    /// time because another process may create the previewed path meanwhile.
    public func previewUniqueSibling(
        for sourceURL: URL,
        in directoryURL: URL? = nil,
        stem requestedStem: String? = nil,
        stemSuffix: String = "_podpisane",
        outputExtension: String? = nil,
        occupiedURLs: Set<URL> = []
    ) throws -> URL {
        guard !isSymbolicLink(sourceURL) else { throw OutputServiceError.unsafeSource }
        let source = canonicalURL(sourceURL)
        let rawDirectory = directoryURL ?? sourceURL.deletingLastPathComponent()
        guard !isSymbolicLink(rawDirectory) else { throw OutputServiceError.unsafeTarget }
        let directory = canonicalURL(rawDirectory)
        let stem = requestedStem ?? source.deletingPathExtension().lastPathComponent
        let destinationExtension = outputExtension ?? source.pathExtension
        let occupied = Set(occupiedURLs.map(canonicalURL))
        var number = 1
        while true {
            let suffix = number == 1 ? stemSuffix : "\(stemSuffix) (\(number))"
            let candidate = directory
                .appending(path: stem + suffix)
                .appendingPathExtension(destinationExtension)
            if !pathExists(candidate) && !occupied.contains(canonicalURL(candidate)) {
                return candidate
            }
            number += 1
        }
    }

    public func finalize(_ reservation: OutputReservation) throws {
        guard !pathExists(reservation.finalURL) else { throw OutputServiceError.finalOutputAlreadyExists }
        try validator.validate(at: reservation.temporaryURL, fileExtension: reservation.finalURL.pathExtension)
        guard moveWithoutReplacing(reservation.temporaryURL, to: reservation.finalURL) else {
            if pathExists(reservation.finalURL) { throw OutputServiceError.finalOutputAlreadyExists }
            throw OutputServiceError.unableToFinalize
        }
    }

    /// Removes the temporary file of a reservation that will not be finalized.
    ///
    /// Every reservation must end in either `finalize(_:)` or this call, on
    /// success, failure and cancellation alike, or a hidden `.<name>.<UUID>.XXXXXX`
    /// file stays next to the user's document. Only the exact reserved temporary
    /// URL is touched, and only while it is a regular file: a missing file (the
    /// engine never wrote it) is fine, and anything else at that path, such as a
    /// symbolic link, is not something this app created. The final URL is never
    /// touched. Calling it twice is harmless.
    public func discard(_ reservation: OutputReservation) {
        var status = stat()
        reservation.temporaryURL.withUnsafeFileSystemRepresentation { path in
            guard let path, lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return }
            unlink(path)
        }
    }

    private func resolvedDestination(
        for source: URL,
        requestedFinalURL: URL?,
        outputExtension: String?
    ) throws -> URL {
        if let requestedFinalURL {
            guard !isSymbolicLink(requestedFinalURL) else { throw OutputServiceError.unsafeTarget }
            return canonicalURL(requestedFinalURL)
        }

        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let destinationExtension = outputExtension ?? source.pathExtension
        var number = 1
        while true {
            let suffix = number == 1 ? "_signed" : "_signed (\(number))"
            let candidate = directory.appending(path: stem + suffix).appendingPathExtension(destinationExtension)
            if !pathExists(candidate) { return candidate }
            number += 1
        }
    }

    private func reserveTemporarySibling(of finalURL: URL) throws -> URL {
        let directory = finalURL.deletingLastPathComponent()
        var template = directory
            .appending(path: ".\(finalURL.lastPathComponent).\(UUID().uuidString).XXXXXX")
            .path
            .utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress) }
        guard descriptor >= 0 else { throw OutputServiceError.unableToReserveTemporaryFile }
        defer { close(descriptor) }
        return URL(fileURLWithPath: String(cString: Array(template)))
    }

    private func moveWithoutReplacing(_ source: URL, to destination: URL) -> Bool {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0
            }
        }
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func pathExists(_ url: URL) -> Bool {
        var status = stat()
        return url.withUnsafeFileSystemRepresentation { lstat($0, &status) == 0 }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        return url.withUnsafeFileSystemRepresentation {
            lstat($0, &status) == 0 && (status.st_mode & S_IFMT) == S_IFLNK
        }
    }
}
