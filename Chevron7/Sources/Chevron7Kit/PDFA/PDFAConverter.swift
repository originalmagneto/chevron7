// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import PDFKit
import CoreGraphics
import AppKit

public enum PDFAConversionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case vectorPreserving = "Vektorová zachovávajúca"
    case rasterGuaranteed = "Rasterizovaná garancia"

    public var id: String { rawValue }
}

public enum PDFAError: LocalizedError, Equatable, Sendable {
    case emptyDocument
    case unsupportedOutputProfile(String)
    case missingSRGBProfile(path: String)
    case rootNotFound
    case catalogNotFound(Int)
    case serializationFailed
    case normalizerUnavailable
    case normalizedOutputInvalid(issues: [String])

    public var errorDescription: String? {
        switch self {
        case .emptyDocument: return "Dokument je prázdny."
        case .unsupportedOutputProfile(let profileID):
            return "Výstupný profil \(profileID) zatiaľ nie je implementovaný alebo overený."
        case .missingSRGBProfile(let path): return "Chýba sRGB ICC profil: \(path)"
        case .rootNotFound: return "PDF nemá čitateľný koreňový katalóg."
        case .catalogNotFound(let num): return "Katalógová objekt #\(num) sa nepodarilo načítať."
        case .serializationFailed: return "Serializácia PDF zlyhala."
        case .normalizerUnavailable:
            return "PDF/A normalizácia nie je dostupná. Skontrolujte inštaláciu aplikácie Chevron7 a skúste znova."
        case .normalizedOutputInvalid(let issues):
            return "Výsledný dokument neprešiel kontrolou PDF/A: \(issues.joined(separator: "; "))"
        }
    }
}

public struct PDFAConverter: Sendable {
    public var producer: String

    public init(producer: String = "Chevron7 ZaKo 1.0") {
        self.producer = producer
    }

    public static let sRGBProfileSystemPath = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"

    public func convert(document: PDFDocument,
                        profile: ConversionOutputProfile,
                        mode: PDFAConversionMode = .vectorPreserving,
                        title: String = "") throws -> Data {
        guard profile.container == .pdf,
              profile.isImplemented,
              profile.id == ConversionOutputProfile.pilotPDFA2b.id else {
            throw PDFAError.unsupportedOutputProfile(profile.id)
        }
        return try convert(document: document, mode: mode, title: title)
    }

    public func convert(document: PDFDocument,
                        mode: PDFAConversionMode = .vectorPreserving,
                        title: String = "") throws -> Data {
        guard document.pageCount > 0 else { throw PDFAError.emptyDocument }
        let baseData: Data
        switch mode {
        case .vectorPreserving:
            guard let data = document.dataRepresentation() else { throw PDFAError.serializationFailed }
            baseData = data
        case .rasterGuaranteed:
            baseData = try Self.rasterize(document: document)
        }
        return try convertData(baseData, mode: mode, title: title)
    }

    /// Konverzia na PDF/A-2B: čistý rewrite cez PDFBox v Java engine (PdfaNormalize).
    /// Fallback: ručný incremental append, keď engine nie je dostupný.
    public func convertData(_ data: Data, mode: PDFAConversionMode, title: String) throws -> Data {
        // Keep this intermediate PDF compatible with PDFKit and the incremental
        // attachment writer. The final deliverable is normalized after the XML
        // attachment, before its fingerprint is persisted.
        var baseData = Self.forceVersionHeader(data)
        return try injectPDFACompliance(into: baseData, title: title)
    }

    /// Zavolá PdfaNormalize z Autogram macOS 2 enginu (PDFBox 3, čistý rewrite s /ID a XMP).
    public static func normalizeWithEngine(_ data: Data, title: String) -> Data? {
        guard let installation = JavaEngineLocator().locate(),
              FileManager.default.isExecutableFile(atPath: installation.javaExecutableURL.path),
              FileManager.default.fileExists(atPath: Self.sRGBProfileSystemPath) else {
            return nil
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfa-normalize-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let input = work.appendingPathComponent("in.pdf")
            let output = work.appendingPathComponent("out.pdf")
            try data.write(to: input, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: work) }

            let process = Process()
            process.executableURL = installation.javaExecutableURL
            // The locator points to Contents/app/autogram.jar. Keep the JAR and
            // its sibling dependency-jars directory on the same classpath.
            let appDirectory = installation.jarFileURL.deletingLastPathComponent()
            let classpath = "\(installation.jarFileURL.path):\(appDirectory.appendingPathComponent("dependency-jars").path)/*"
            process.arguments = [
                "-cp", classpath,
                "digital.slovensko.autogram.core.PdfaNormalize",
                input.path, output.path, Self.sRGBProfileSystemPath,
                title.isEmpty ? "Dokument" : title
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: output.path) else {
                return nil
            }
            return try Data(contentsOf: output)
        } catch {
            return nil
        }
    }

    /// Rewrites an already assembled deliverable with the PDF/A normalizer when
    /// the bundled Java engine is available. This is especially important after
    /// attaching the XML clause, because an incremental PDF update must also be
    /// accepted by external PDF/A validators such as Acrobat Preflight.
    public func normalizeForDelivery(_ data: Data, title: String) throws -> Data {
        guard let normalized = Self.normalizeWithEngine(data, title: title) else {
            let fallbackCheck = PDFAValidator().validate(data)
            guard fallbackCheck.isValid else {
                throw PDFAError.normalizerUnavailable
            }
            return data
        }
        let check = PDFAValidator().validate(normalized)
        guard check.isValid else {
            throw PDFAError.normalizedOutputInvalid(issues: check.issues)
        }
        return normalized
    }

    static func forceVersionHeader(_ data: Data) -> Data {
        var out = data
        let headerPrefix = Data("%PDF-1.".utf8)
        if out.count > 8 && out.prefix(headerPrefix.count) == headerPrefix {
            out.replaceSubrange(7..<8, with: Data("7".utf8))
        }
        return out
    }

    static func rasterize(document: PDFDocument, dpi: CGFloat = 200) throws -> Data {
        let scale = dpi / 72.0
        var pageImages: [(image: CGImage, widthPt: CGFloat, heightPt: CGFloat)] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let image = Self.renderPageImage(page: page, scale: scale) else { continue }
            let width = ceil(CGFloat(image.width) / scale)
            let height = ceil(CGFloat(image.height) / scale)
            pageImages.append((image, width, height))
        }

        return Self.buildJPEGPDF(pages: pageImages, quality: 0.82)
    }
    public static func rasterizedPDFData(document: PDFDocument) throws -> Data {
        try rasterize(document: document)
    }


    /// PDF s JPEG (DCTDecode) stránkami — raster PDF/A má tak desiatky KB, nie desiatky MB.
    static func buildJPEGPDF(pages: [(image: CGImage, widthPt: CGFloat, heightPt: CGFloat)],
                             quality: CGFloat) -> Data {
        precondition(!pages.isEmpty, "Žiadne stránky na rasterizáciu")
        var out = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A,
                        0x25, 0xF6, 0xE4, 0xFC, 0xDF, 0x0A])
        var offsets: [Int] = []
        func append(_ objectNumber: Int, _ body: String, stream: Data? = nil) {
            offsets.append(out.count)
            out.append(Data("\(objectNumber) 0 obj\n".utf8))
            out.append(Data(body.utf8))
            if let stream {
                out.append(Data("\nstream\n".utf8))
                out.append(stream)
                out.append(Data("\nendstream\n".utf8))
            }
            out.append(Data("\nendobj\n".utf8))
        }

        let firstPageObject = 3
        let objectsPerPage = 3
        let kids = (0..<pages.count).map { "\(firstPageObject + $0 * objectsPerPage) 0 R" }

        append(1, "<< /Type /Catalog /Pages 2 0 R >>")
        append(2, "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>")

        for (index, page) in pages.enumerated() {
            let pageObject = firstPageObject + index * objectsPerPage
            let contentObject = pageObject + 1
            let imageObject = pageObject + 2

            let jpeg = Self.jpegData(from: page.image, quality: quality) ?? Data()
            let content = "q\n\(page.widthPt) 0 0 \(page.heightPt) 0 0 cm\n/Im0 Do\nQ"
            let pageBody = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(page.widthPt) \(page.heightPt)]"
                + " /Resources << /XObject << /Im0 \(imageObject) 0 R >> >>"
                + " /Contents \(contentObject) 0 R >>"
            append(pageObject, pageBody)
            append(contentObject, "<< /Length \(content.utf8.count) >>", stream: Data(content.utf8))
            let imageBody = "<< /Type /XObject /Subtype /Image /Width \(page.image.width)"
                + " /Height \(page.image.height) /ColorSpace /DeviceRGB /BitsPerComponent 8"
                + " /Filter /DCTDecode /Length \(jpeg.count) >>"
            append(imageObject, imageBody, stream: jpeg)
        }

        let xrefOffset = out.count
        let objectCount = firstPageObject + pages.count * objectsPerPage - 1
        out.append(Data("xref\n0 \(objectCount + 1)\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        // A newly written file starts with both identifiers equal (ISO 32000-1, 14.4),
        // and incremental updates keep the first, so each document needs its own.
        let identifier = PDFObjectScanner.randomIdentifier()
        let trailer = "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R"
            + " /ID [<\(identifier)> <\(identifier)>] >>\n"
            + "startxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(trailer.utf8))
        return out
    }

    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: quality])
    }

    static func mergePageDatas(_ datas: [Data]) -> Data {
        guard !datas.isEmpty else { return Data() }
        let output = PDFDocument()
        var insertionIndex = 0
        for data in datas {
            guard let document = PDFDocument(data: data) else { continue }
            for pageIndex in 0..<document.pageCount {
                if let page = document.page(at: pageIndex) {
                    output.insert(page, at: insertionIndex)
                    insertionIndex += 1
                }
            }
        }
        return output.dataRepresentation() ?? Data()
    }

    static func renderPageImage(page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let rotation = ((page.pageRef?.rotationAngle ?? 0) % 360 + 360) % 360
        let outputSize = rotation % 180 == 0
            ? bounds.size
            : CGSize(width: bounds.height, height: bounds.width)
        let width = max(Int(outputSize.width * scale), 8)
        let height = max(Int(outputSize.height * scale), 8)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    func injectPDFACompliance(into base: Data, title: String) throws -> Data {
        let iccPath = Self.sRGBProfileSystemPath
        guard let icc = FileManager.default.contents(atPath: iccPath), !icc.isEmpty else {
            throw PDFAError.missingSRGBProfile(path: iccPath)
        }

        guard let root = PDFObjectScanner.rootObjectNumber(in: base) else {
            throw PDFAError.rootNotFound
        }
        guard let catalogDict = PDFObjectScanner.catalogDictionary(number: root.objectNumber, in: base) else {
            throw PDFAError.catalogNotFound(root.objectNumber)
        }

        let maxNumber = max(PDFObjectScanner.maxObjectNumber(in: base), root.objectNumber)
        let metaNumber = maxNumber + 1
        let iccNumber = maxNumber + 2
        let oiNumber = maxNumber + 3
        let newCatalogNumber = maxNumber + 4

        let xmp = Self.buildXMPPacket(title: title, producer: producer)
        let xmpBytes = Data(xmp.utf8)

        var metaObj = Data("\(metaNumber) 0 obj\n<< /Type /Metadata /Subtype /XML /Length \(xmpBytes.count) >>\nstream\n".utf8)
        metaObj.append(xmpBytes)
        metaObj.append(Data("\nendstream\nendobj\n".utf8))

        var iccObj = Data("\(iccNumber) 0 obj\n<< /N 3 /Length \(icc.count) >>\nstream\n".utf8)
        iccObj.append(icc)
        iccObj.append(Data("\nendstream\nendobj\n".utf8))

        let oiBody = "<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1)" +
            " /Info (sRGB IEC61966-2.1) /RegistryName (http://www.color.org)" +
            " /DestOutputProfile \(iccNumber) 0 R >>"
        let oiObj = Data("\(oiNumber) 0 obj\n\(oiBody)\nendobj\n".utf8)

        var augmented = catalogDict
        if !augmented.contains("/OutputIntents") {
            augmented = PDFObjectScanner.augmentDictionary(
                augmented,
                appending: " /Metadata \(metaNumber) 0 R /OutputIntents [\(oiNumber) 0 R]")
        }
        let catalogObj = Data("\(newCatalogNumber) 0 obj\n\(augmented)\nendobj\n".utf8)

        var out = PDFObjectScanner.endingWithEOL(base)
        var offsets: [(number: Int, offset: Int)] = []

        func trackAndAppend(_ chunk: Data, number: Int) {
            offsets.append((number, out.count))
            out.append(chunk)
        }

        trackAndAppend(metaObj, number: metaNumber)
        trackAndAppend(iccObj, number: iccNumber)
        trackAndAppend(oiObj, number: oiNumber)
        trackAndAppend(catalogObj, number: newCatalogNumber)

        let xrefOffset = out.count
        let firstNew = metaNumber
        let count = newCatalogNumber - firstNew + 1
        let byNumber = Dictionary(uniqueKeysWithValues: offsets.map { ($0.number, $0.offset) })

        var xref = Data("xref\n\(firstNew) \(count)\n".utf8)
        for n in firstNew...newCatalogNumber {
            let off = byNumber[n] ?? 0
            xref.append(Data(String(format: "%010d %05d n \n", off, 0).utf8))
        }
        let fileID = PDFObjectScanner.updatedFileIdentifier(atXref: root.xrefOffset, in: base)
        let trailer = """
        trailer
        << /Size \(newCatalogNumber + 1) /Root \(newCatalogNumber) 0 R /Prev \(root.xrefOffset) \(fileID) >>
        startxref
        \(xrefOffset)
        %%EOF

        """
        xref.append(Data(trailer.utf8))
        out.append(xref)

        return out
    }

    static func buildXMPPacket(title: String, producer: String) -> String {
        let iso = ISO8601DateFormatter().string(from: Date())
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
            xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"
            pdfaid:part="2"
            pdfaid:conformance="B">
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(xmlEscape(title))</rdf:li></rdf:Alt></dc:title>
           <pdf:Producer>\(xmlEscape(producer))</pdf:Producer>
           <xmp:CreateDate>\(iso)</xmp:CreateDate>
           <xmp:ModifyDate>\(iso)</xmp:ModifyDate>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

public enum PDFObjectScanner {
    public struct RootRef: Equatable, Sendable {
        public var objectNumber: Int
        public var xrefOffset: Int
    }

    public static func rootObjectNumber(in data: Data) -> RootRef? {
        let tailText = String(decoding: data.suffix(min(data.count, 16_384)), as: UTF8.self)
        // The last startxref names the newest revision; an earlier one can still
        // sit inside the tail after a short incremental update.
        guard let xrefRange = tailText.range(of: "startxref", options: .backwards) else { return nil }
        let afterStart = tailText[xrefRange.upperBound...]
        let tokens = afterStart.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
        guard let rawOffset = tokens.first,
              let xrefOffset = Int(rawOffset.trimmingCharacters(in: CharacterSet.whitespaces)),
              xrefOffset >= 0, xrefOffset < data.count else { return nil }

        let regionEnd = min(xrefOffset + 4096, data.count)
        let region = String(decoding: data.subdata(in: xrefOffset..<regionEnd), as: UTF8.self)

        guard let rootRange = region.range(of: "/Root") else { return nil }
        let rest = region[rootRange.upperBound...]
        let nums = rest.split { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == ">" }
        guard nums.count >= 2, let num = Int(nums[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return RootRef(objectNumber: num, xrefOffset: xrefOffset)
    }

    public static func catalogDictionary(number: Int, in data: Data) -> String? {
        guard let found = lastObjectHeader(number: number, in: data) else { return nil }

        let headEnd = min(found.lowerBound + 128, data.count)
        let head = String(decoding: data.subdata(in: found.lowerBound..<headEnd), as: UTF8.self)
        guard let openRange = head.range(of: "<<") else { return nil }
        let dictStartDataOffset = found.lowerBound + head.distance(from: head.startIndex, to: openRange.lowerBound)

        var depth = 0
        var i = dictStartDataOffset
        var inString = false
        var escape = false

        while i < data.count {
            let b = data[data.startIndex + i]

            if inString {
                if escape { escape = false }
                else if b == 0x5C { escape = true }
                else if b == 0x29 { inString = false }
                i += 1
                continue
            }
            if b == 0x28 { inString = true; i += 1; continue }
            if b == 0x3C && i + 1 < data.count && data[data.startIndex + i + 1] == 0x3C {
                depth += 1; i += 2; continue
            }
            if b == 0x3E && i + 1 < data.count && data[data.startIndex + i + 1] == 0x3E {
                depth -= 1
                if depth == 0 {
                    let slice = data.subdata(in: dictStartDataOffset..<i + 2)
                    return String(decoding: slice, as: UTF8.self)
                }
                i += 2; continue
            }
            i += 1
        }
        return nil
    }

    public static func integerReference(named name: String, in dictionary: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "/\(name)\\s+(\\d+)\\s+0\\s+R"),
              let match = regex.firstMatch(in: dictionary, range: NSRange(dictionary.startIndex..., in: dictionary)),
              let range = Range(match.range(at: 1), in: dictionary) else { return nil }
        return Int(dictionary[range])
    }

    public static func lastObjectHeader(number: Int, in data: Data) -> Range<Data.Index>? {
        let pattern = Data("\(number) 0 obj".utf8)
        var searchEnd = data.endIndex
        while searchEnd > data.startIndex,
              let found = data.range(of: pattern, options: .backwards, in: data.startIndex..<searchEnd) {
            let before = found.lowerBound
            if before == data.startIndex || !isDigit(data[before - 1]) {
                return found
            }
            searchEnd = found.lowerBound
        }
        return nil
    }

    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// The data with an end-of-line marker after it, so an object appended as an
    /// incremental update starts on its own line and its cross-reference offset
    /// is the first byte of `N 0 obj`, as ISO 32000 requires.
    public static func endingWithEOL(_ data: Data) -> Data {
        guard let last = data.last, last != 0x0A, last != 0x0D else { return data }
        var out = data
        out.append(0x0A)
        return out
    }

    /// The `/ID` entry for the trailer of an incremental update to the revision
    /// whose cross-reference section starts at `xrefOffset`. PDF/A requires `/ID`
    /// in the trailer. The first identifier is permanent and is kept; the second
    /// changes with every revision. A source without one gets a fresh pair.
    public static func updatedFileIdentifier(atXref xrefOffset: Int, in data: Data) -> String {
        let fresh = randomIdentifier()
        let permanent = fileIdentifier(atXref: xrefOffset, in: data)?.permanent ?? fresh
        return "/ID [<\(permanent)> <\(fresh)>]"
    }

    /// The `/ID` pair in the trailer that follows the cross-reference section at
    /// `xrefOffset`, as hexadecimal strings.
    public static func fileIdentifier(atXref xrefOffset: Int,
                                      in data: Data) -> (permanent: String, changing: String)? {
        guard xrefOffset >= 0, xrefOffset < data.count else { return nil }
        let tail = data[(data.startIndex + xrefOffset)...]
        let end = tail.range(of: Data("startxref".utf8))?.lowerBound ?? tail.endIndex
        let section = String(decoding: tail[..<end], as: UTF8.self)
        guard let regex = try? NSRegularExpression(
                pattern: "/ID\\s*\\[\\s*<([0-9A-Fa-f]+)>\\s*<([0-9A-Fa-f]+)>\\s*\\]"),
              let match = regex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
              let first = Range(match.range(at: 1), in: section),
              let second = Range(match.range(at: 2), in: section) else { return nil }
        return (String(section[first]), String(section[second]))
    }

    static func randomIdentifier() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    public static func firstPageObjectNumber(catalog: String, in data: Data) -> Int? {
        if let pagesNumber = integerReference(named: "Pages", in: catalog),
           let pagesDict = catalogDictionary(number: pagesNumber, in: data),
           let page = firstKidPage(in: pagesDict, data: data) {
            return page
        }
        return firstUncompressedPageObject(in: data)
    }

    static func firstUncompressedPageObject(in data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "(?m)^(\\d+)\\s+0\\s+obj\\s*<<[^>]* /Type /Page(?:\\s|/)") else {
            return nil
        }
        let ns = text as NSString
        let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        guard let match, let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    static func firstKidPage(in pagesDict: String, data: Data) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "/Kids\\s*\\[\\s*(\\d+)\\s+0\\s+R"),
              let match = regex.firstMatch(in: pagesDict, range: NSRange(pagesDict.startIndex..., in: pagesDict)),
              let range = Range(match.range(at: 1), in: pagesDict),
              let number = Int(pagesDict[range]),
              let child = catalogDictionary(number: number, in: data) else { return nil }
        if child.contains("/Kids") { return firstKidPage(in: child, data: data) }
        return number
    }

    public static func pageWithAnnotation(pageDict: String, widgetNumber: Int) -> String {
        if let annots = pageDict.range(of: "/Annots"),
           let bracket = pageDict.range(of: "[", range: annots.upperBound..<pageDict.endIndex) {
            var updated = pageDict
            updated.insert(contentsOf: "\(widgetNumber) 0 R ", at: bracket.upperBound)
            return updated
        }
        return augmentDictionary(pageDict, appending: "/Annots [\(widgetNumber) 0 R]")
    }

    public static func augmentDictionary(_ dict: String, appending suffix: String) -> String {
        guard let range = dict.range(of: ">>", options: .backwards) else { return dict }
        return dict[dict.startIndex..<range.lowerBound] + suffix + " " + dict[range.lowerBound...]
    }

    public static func maxObjectNumber(in data: Data) -> Int {
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "(\\d+)\\s+0\\s+obj") else { return 1 }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var maxNum = 0
        for m in matches {
            let group = nsText.substring(with: m.range(at: 1))
            if let n = Int(group), n > maxNum { maxNum = n }
        }
        return max(maxNum, 1)
    }
}
