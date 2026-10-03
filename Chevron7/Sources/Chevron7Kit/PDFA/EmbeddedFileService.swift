// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import PDFKit

public struct EmbeddedFileService: Sendable {
    public init() {}

    public struct Attachment: Sendable {
        public var fileName: String
        public var mimeType: String
        public var data: Data
        public init(fileName: String, mimeType: String, data: Data) {
            self.fileName = fileName
            self.mimeType = mimeType
            self.data = data
        }
    }

    public func embed(_ attachment: Attachment, into pdf: Data) throws -> Data {
        guard let root = PDFObjectScanner.rootObjectNumber(in: pdf) else {
            throw PDFAError.rootNotFound
        }
        guard let catalogDict = PDFObjectScanner.catalogDictionary(number: root.objectNumber, in: pdf) else {
            throw PDFAError.catalogNotFound(root.objectNumber)
        }
        let maxNumber = max(PDFObjectScanner.maxObjectNumber(in: pdf), root.objectNumber)
        let fileNumber = maxNumber + 1
        let specNumber = maxNumber + 2
        let newCatalogNumber = maxNumber + 3
        let escapedMimeType = attachment.mimeType.replacingOccurrences(of: "/", with: "#2F")

        var fileObj = Data("\(fileNumber) 0 obj\n<< /Type /EmbeddedFile /Subtype /\(escapedMimeType) /Length \(attachment.data.count) >>\nstream\n".utf8)
        fileObj.append(attachment.data)
        fileObj.append(Data("\nendstream\nendobj\n".utf8))

        let nameASCII = attachment.fileName.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "").replacingOccurrences(of: "\\", with: "")
        let ufHex = attachment.fileName.utf16.map { String(format: "%04X", $0) }.joined()
        let escapedDesc = attachment.mimeType.replacingOccurrences(of: "(", with: "")
        let specBody = "<< /Type /Filespec /F (\(nameASCII)) /UF <FEFF\(ufHex)>" +
            " /AFRelationship /Data /Desc (\(escapedDesc))" +
            " /EF << /F \(fileNumber) 0 R /UF \(fileNumber) 0 R >> >>"
        let specObj = Data("\(specNumber) 0 obj\n\(specBody)\nendobj\n".utf8)

        var augmented = Self.addAttachmentToCatalog(catalogDict,
                                                    fileName: nameASCII,
                                                    specificationNumber: specNumber)
        augmented = Self.addAssociatedFileToCatalog(augmented,
                                                    specificationNumber: specNumber)
        let catalogObj = Data("\(newCatalogNumber) 0 obj\n\(augmented)\nendobj\n".utf8)

        var out = PDFObjectScanner.endingWithEOL(pdf)
        var offsets: [(Int, Int)] = []
        func append(_ chunk: Data, number: Int) {
            offsets.append((number, out.count))
            out.append(chunk)
        }
        append(fileObj, number: fileNumber)
        append(specObj, number: specNumber)
        append(catalogObj, number: newCatalogNumber)

        let xrefOffset = out.count
        let byNumber = Dictionary(uniqueKeysWithValues: offsets.map { ($0.0, $0.1) })
        let firstNew = fileNumber
        let count = newCatalogNumber - firstNew + 1

        var xref = Data("xref\n\(firstNew) \(count)\n".utf8)
        for n in firstNew...newCatalogNumber {
            xref.append(Data(String(format: "%010d %05d n \n", byNumber[n] ?? 0, 0).utf8))
        }
        let fileID = PDFObjectScanner.updatedFileIdentifier(atXref: root.xrefOffset, in: pdf)
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

    private static func addAttachmentToCatalog(_ catalog: String,
                                               fileName: String,
                                               specificationNumber: Int) -> String {
        let entry = "(\(fileName)) \(specificationNumber) 0 R"
        if let embeddedRange = catalog.range(of: "/EmbeddedFiles"),
           let namesRange = catalog.range(of: "/Names", range: embeddedRange.upperBound..<catalog.endIndex),
           let bracketRange = catalog.range(of: "[", range: namesRange.upperBound..<catalog.endIndex),
           let closingRange = catalog.range(of: "]", range: bracketRange.upperBound..<catalog.endIndex) {
            var updated = catalog
            updated.insert(contentsOf: "\(entry) ", at: closingRange.lowerBound)
            return updated
        }

        let namesSuffix = " /Names << /EmbeddedFiles << /Names [\(entry)] >> >>"
        return PDFObjectScanner.augmentDictionary(catalog, appending: namesSuffix)
    }

    private static func addAssociatedFileToCatalog(_ catalog: String,
                                                   specificationNumber: Int) -> String {
        if let afRange = catalog.range(of: "/AF"),
           let bracketRange = catalog.range(of: "[", range: afRange.upperBound..<catalog.endIndex),
           let closingRange = catalog.range(of: "]", range: bracketRange.upperBound..<catalog.endIndex) {
            var updated = catalog
            updated.insert(contentsOf: "\(specificationNumber) 0 R ", at: closingRange.lowerBound)
            return updated
        }
        return PDFObjectScanner.augmentDictionary(catalog,
                                                  appending: " /AF [\(specificationNumber) 0 R]")
    }
}
