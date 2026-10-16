// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Runs the engine's `PdfaFromSigned` (E→E): a PDF that may not stay byte for byte becomes a
/// new PDF/A-2b with signatures, form fields and visible stamps flattened, checked by veraPDF.
public struct PdfaFromSignedRunner: Sendable {
    public enum Failure: LocalizedError, Equatable {
        /// Written, but veraPDF found it is not PDF/A (usually fonts the source does not embed).
        case notCompliant([String])
        case unreadable
        case engineUnavailable
        case failed

        public var errorDescription: String? {
            switch self {
            case .notCompliant:
                return "Výsledok nie je platné PDF/A (zvyčajne pre písma, ktoré pôvodný dokument nevkladá)."
            case .unreadable: return "Pôvodný PDF sa nepodarilo prečítať."
            case .engineUnavailable:
                return "Prevod do PDF/A nie je dostupný. Skontrolujte inštaláciu aplikácie Chevron7 a skúste znova."
            case .failed: return "Prevod do PDF/A sa nepodaril."
            }
        }
    }

    /// Runs the engine with these arguments after `-cp <classpath>`; returns exit status and stderr.
    public typealias Launch = @Sendable (_ arguments: [String]) throws -> (status: Int32, stderr: String)

    private let launch: Launch?

    public init(launch: Launch? = nil) {
        self.launch = launch
    }

    public func convert(_ pdf: Data, title: String, raster: Bool) throws -> Data {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfa-from-signed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let input = work.appendingPathComponent("in.pdf")
        let output = work.appendingPathComponent("out.pdf")
        try pdf.write(to: input, options: [.atomic])
        var arguments = ["digital.slovensko.autogram.core.PdfaFromSigned", input.path, output.path,
                         PDFAConverter.sRGBProfileSystemPath, title.isEmpty ? "Dokument" : title]
        if raster { arguments.append("--raster") }
        let result = try (launch ?? Self.engineLaunch())(arguments)
        switch result.status {
        case 0:
            guard let data = try? Data(contentsOf: output) else { throw Failure.failed }
            return data
        case 3:
            throw Failure.notCompliant(result.stderr.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
        case 2:
            throw Failure.unreadable
        default:
            throw Failure.failed
        }
    }

    /// The bundled engine, as `PDFAConverter.normalizeWithEngine` runs it.
    static func engineLaunch() throws -> Launch {
        guard let installation = JavaEngineLocator().locate(),
              FileManager.default.isExecutableFile(atPath: installation.javaExecutableURL.path),
              FileManager.default.fileExists(atPath: PDFAConverter.sRGBProfileSystemPath) else {
            throw Failure.engineUnavailable
        }
        let appDirectory = installation.jarFileURL.deletingLastPathComponent()
        let classpath = "\(installation.jarFileURL.path):\(appDirectory.appendingPathComponent("dependency-jars").path)/*"
        let java = installation.javaExecutableURL
        return { arguments in
            let process = Process()
            process.executableURL = java
            process.arguments = ["-cp", classpath] + arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, stderr)
        }
    }
}
