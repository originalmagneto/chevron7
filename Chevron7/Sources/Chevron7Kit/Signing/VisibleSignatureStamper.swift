// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import PDFKit
import AppKit

public struct VisibleSignatureStamper: Sendable {
    public init() {}

    public struct StampData: Sendable {
        public var fullName: String
        public var timestamp: Date
        public var pageIndex: Int
        public var normalizedRect: NormalizedRect
        public var imagePNG: Data?
        public var certificateName: String?
        public var certificateQualification: String?
        public var timestampAuthorityName: String?
        public var layout: VisibleSignatureLayout = .detailed

        public init(
            fullName: String,
            timestamp: Date,
            pageIndex: Int,
            normalizedRect: NormalizedRect,
            imagePNG: Data? = nil,
            certificateName: String? = nil,
            certificateQualification: String? = nil,
            timestampAuthorityName: String? = nil,
            layout: VisibleSignatureLayout = .detailed
        ) {
            self.fullName = fullName
            self.timestamp = timestamp
            self.pageIndex = pageIndex
            self.normalizedRect = normalizedRect
            self.imagePNG = imagePNG
            self.certificateName = certificateName
            self.certificateQualification = certificateQualification
            self.timestampAuthorityName = timestampAuthorityName
            self.layout = layout
        }
    }

    public func stamp(document: PDFDocument, stamp: StampData, includeTimestamp: Bool) -> Data? {
        guard let page = document.page(at: stamp.pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)

        let rect = CGRect(x: stamp.normalizedRect.x * bounds.width,
                          y: (1 - stamp.normalizedRect.y - stamp.normalizedRect.height) * bounds.height,
                          width: max(stamp.normalizedRect.width * bounds.width, 120),
                          height: max(stamp.normalizedRect.height * bounds.height, 40))

        let formatter = DateFormatter()
        formatter.dateFormat = "d. M. yyyy HH:mm"

        if let imagePNG = stamp.imagePNG {
            let enrichedPNG = try? VisibleSignatureRenderer().renderPNG(
                artworkPNG: imagePNG,
                content: VisibleSignatureCardContent(
                    signerName: stamp.fullName,
                    certificateName: stamp.certificateName,
                    certificateQualification: stamp.certificateQualification,
                    timestampAuthorityName: includeTimestamp ? stamp.timestampAuthorityName : nil),
                signingTime: stamp.timestamp,
                layout: stamp.layout)
            if let image = NSImage(data: enrichedPNG ?? imagePNG) {
                let annotation = ImageStampAnnotation(bounds: rect, image: image)
                page.addAnnotation(annotation)
            }
        } else {
            let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            annotation.contents = includeTimestamp
                ? "Elektronicky podpísané\n\(stamp.fullName)\n\(formatter.string(from: stamp.timestamp))"
                : "Elektronicky podpísané\n\(stamp.fullName)"
            annotation.font = NSFont.systemFont(ofSize: 8.5)
            annotation.fontColor = NSColor(cgColor: CGColor(gray: 0.15, alpha: 1)) ?? .black
            annotation.color = NSColor(cgColor: CGColor(red: 0.995, green: 0.99, blue: 0.975, alpha: 1)) ?? .white
            let border = PDFBorder()
            border.lineWidth = 1
            border.style = .solid
            annotation.border = border
            page.addAnnotation(annotation)
        }

        return document.dataRepresentation()
    }
    public func flattenedStamp(
        document: PDFDocument,
        stamp: StampData,
        includeTimestamp: Bool
    ) -> Data? {
        guard document.page(at: stamp.pageIndex) != nil else { return nil }

        let image: NSImage
        if let imagePNG = stamp.imagePNG {
            let enrichedPNG = try? VisibleSignatureRenderer().renderPNG(
                artworkPNG: imagePNG,
                content: VisibleSignatureCardContent(
                    signerName: stamp.fullName,
                    certificateName: stamp.certificateName,
                    certificateQualification: stamp.certificateQualification,
                    timestampAuthorityName: includeTimestamp ? stamp.timestampAuthorityName : nil),
                signingTime: stamp.timestamp,
                layout: stamp.layout)
            guard let renderedImage = NSImage(data: enrichedPNG ?? imagePNG) else {
                return self.stamp(document: document, stamp: stamp, includeTimestamp: includeTimestamp)
            }
            image = renderedImage
        } else {
            let fallback = NSImage(size: NSSize(width: 720, height: 220))
            fallback.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: fallback.size)).fill()
            let text = includeTimestamp
                ? "Elektronicky podpísané\n\(stamp.fullName)\n\(stamp.timestamp.formatted(date: .numeric, time: .shortened))"
                : "Elektronicky podpísané\n\(stamp.fullName)"
            (text as NSString).draw(
                in: NSRect(x: 24, y: 24, width: 672, height: 172),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 30),
                    .foregroundColor: NSColor.black
                ])
            fallback.unlockFocus()
            image = fallback
        }
        guard let imageRef = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self.stamp(document: document, stamp: stamp, includeTimestamp: includeTimestamp)
        }

        let firstPage = document.page(at: 0)
        let firstBox = firstPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let firstRotation = ((firstPage?.pageRef?.rotationAngle ?? 0) % 360 + 360) % 360
        let firstSize = firstRotation % 180 == 0
            ? firstBox.size
            : CGSize(width: firstBox.height, height: firstBox.width)
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }
        var initialBox = CGRect(origin: .zero, size: firstSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &initialBox, nil) else { return nil }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let pageRef = page.pageRef else { continue }
            let box = page.bounds(for: .mediaBox)
            let rotation = ((pageRef.rotationAngle % 360) + 360) % 360
            let effectiveSize = rotation % 180 == 0
                ? box.size
                : CGSize(width: box.height, height: box.width)
            let effectiveBox = CGRect(origin: .zero, size: effectiveSize)
            let boxData = withUnsafeBytes(of: effectiveBox) { bytes in
                CFDataCreate(nil, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            let options: CFDictionary? = boxData.map {
                [kCGPDFContextMediaBox as String: $0] as CFDictionary
            }
            context.beginPDFPage(options)
            context.saveGState()
            context.concatenate(pageRef.getDrawingTransform(
                .mediaBox,
                rect: effectiveBox,
                rotate: 0,
                preserveAspectRatio: true))
            context.drawPDFPage(pageRef)
            context.restoreGState()
            if index == stamp.pageIndex {
                let stampRect = CGRect(
                    x: stamp.normalizedRect.x * effectiveBox.width,
                    y: (1 - stamp.normalizedRect.y - stamp.normalizedRect.height) * effectiveBox.height,
                    width: max(stamp.normalizedRect.width * effectiveBox.width, 120),
                    height: max(stamp.normalizedRect.height * effectiveBox.height, 40))
                context.draw(imageRef, in: stampRect)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return pdfData as Data
    }
}

final class ImageStampAnnotation: PDFAnnotation {
    private let image: NSImage
    var renderedSize: NSSize { image.size }

    init(bounds: CGRect, image: NSImage) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}
