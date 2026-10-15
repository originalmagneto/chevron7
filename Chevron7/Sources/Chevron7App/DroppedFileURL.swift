// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Resolves the file a drop came from.
///
/// SwiftUI's `onDrop(of:)` hands over a provider that registers only the first
/// declared type the drag matches (`com.adobe.pdf` for a PDF from Finder), never
/// `public.file-url`, even with `.fileURL` in the list, so asking for the file URL
/// fails and reading the drop as bytes loses both the location and the name: the
/// signed output then went to a temporary directory under a generated name.
/// Asking for the document's own type in place returns the original file.
enum DroppedFileURL {
    /// Calls `completion` with the original file when the source opens it in place,
    /// with a copy under the document's own name when the source hands over a file
    /// that disappears once the callback returns (a file promise, another app's
    /// copy), or with nil when the provider carries no file of that type.
    static func load(from provider: NSItemProvider,
                     typeIdentifier: String,
                     temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                     completion: @escaping @Sendable (URL?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            completion(nil)
            return
        }
        _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { url, isInPlace, _ in
            guard let url, url.isFileURL else {
                completion(nil)
                return
            }
            completion(isInPlace ? url : keepCopy(of: url, in: temporaryDirectory))
        }
    }

    /// A unique temporary file that carries `name`, for a drop that has no file of
    /// its own to point at.
    static func temporaryFile(named name: String,
                              in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL? {
        let folder = temporaryDirectory
            .appendingPathComponent("dropped-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder.appendingPathComponent(name)
    }

    /// The PDF name for a drop that carries only bytes: the source's suggested
    /// name when it gives one, else "dokument".
    static func pdfName(suggested: String?) -> String {
        let stem = suggested
            .map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return "\(stem ?? "dokument").pdf"
    }

    private static func keepCopy(of url: URL, in temporaryDirectory: URL) -> URL? {
        guard let destination = temporaryFile(named: url.lastPathComponent, in: temporaryDirectory) else {
            return nil
        }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
