// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Identity
import Foundation

public enum VisibleSignatureRendererError: Error {
    case unreadableArtwork
    case unableToRender
    case unableToEncode
}

public struct VisibleSignatureRenderer {
    /// Band reserved for the signature artwork (stamp, handwritten signature).
    public static let artworkSlot = NSRect(x: 22, y: 120, width: 376, height: 106)

    public let assetStore: SignatureAssetStore
    let cacheRoot: URL
    let fileManager: FileManager

    public init(
        assetStore: SignatureAssetStore = SignatureAssetStore(),
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.assetStore = assetStore
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    public static func aspectFitRect(imageSize: CGSize, inside bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    public func render(
        asset: SignatureAsset,
        content: VisibleSignatureCardContent,
        signingTime: Date,
        rotationDegrees: Double,
        isPreview: Bool = false,
        layout: VisibleSignatureLayout = .detailed
    ) throws -> URL {
        guard let artwork = NSImage(contentsOf: assetStore.fileURL(for: asset)) else {
            throw VisibleSignatureRendererError.unreadableArtwork
        }
        let card = try renderedCard(
            artwork: artwork,
            content: content,
            signingTime: signingTime,
            isPreview: isPreview,
            layout: layout
        )
        let rotated = try rotatedImage(card, degrees: rotationDegrees)
        let directory = cacheRoot.appending(path: "\(ProductIdentity.name)/Visual Signatures", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: UUID().uuidString).appendingPathExtension("png")
        guard let tiff = rotated.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw VisibleSignatureRendererError.unableToEncode
        }
        try png.write(to: output, options: .withoutOverwriting)
        return output
    }
    public func renderPNG(
        artworkPNG: Data,
        content: VisibleSignatureCardContent,
        signingTime: Date,
        layout: VisibleSignatureLayout = .detailed
    ) throws -> Data {
        guard let artwork = NSImage(data: artworkPNG) else {
            throw VisibleSignatureRendererError.unreadableArtwork
        }
        let card = try renderedCard(
            artwork: artwork,
            content: content,
            signingTime: signingTime,
            isPreview: false,
            layout: layout)
        guard let tiff = card.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw VisibleSignatureRendererError.unableToEncode
        }
        return png
    }


    /// Logical card size in points. The bitmap is rendered at `renderScale` so text and
    /// artwork stay crisp when the stamp is stretched across a wide signature field.
    public static let cardSize = NSSize(width: 420, height: 260)
    /// Wide and short: the signature is the stamp, the caption is one line under it.
    public static let compactCardSize = NSSize(width: 420, height: 152)

    public static func cardSize(for layout: VisibleSignatureLayout) -> NSSize {
        layout == .compact ? compactCardSize : cardSize
    }
    static let renderScale: CGFloat = 3

    // Fixed colours: the card ends up on white paper, so it must not follow the
    // app appearance (labelColor turns white in dark mode and the text vanishes).
    static let inkColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let mutedInkColor = NSColor(calibratedWhite: 0.35, alpha: 1)
    static let accentColor = NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.27, alpha: 1)

    private func renderedCard(
        artwork: NSImage,
        content: VisibleSignatureCardContent,
        signingTime: Date,
        isPreview: Bool,
        layout: VisibleSignatureLayout
    ) throws -> NSImage {
        let size = Self.cardSize(for: layout)
        let scale = Self.renderScale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
            throw VisibleSignatureRendererError.unableToRender
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        if layout == .compact {
            drawCompactCard(artwork: artwork, content: content, signingTime: signingTime,
                            isPreview: isPreview, size: size)
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return image
        }


        // Card frame (transparent background).
        let cardRect = NSRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12)
        let cardShape = NSBezierPath(roundedRect: cardRect, xRadius: 12, yRadius: 12)
        Self.inkColor.withAlphaComponent(0.45).setStroke()
        cardShape.lineWidth = 1.5
        cardShape.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Self.mutedInkColor,
            .paragraphStyle: paragraph
        ]
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: Self.inkColor,
            .paragraphStyle: paragraph
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: Self.inkColor,
            .paragraphStyle: paragraph
        ]

        // Heading.
        ("Elektronicky podpísal" as NSString).draw(
            in: NSRect(x: 22, y: 232, width: size.width - 44, height: 16),
            withAttributes: headingAttributes)

        // Artwork gets the widest band of the card.
        let artworkRect = Self.aspectFitRect(imageSize: artwork.size, inside: Self.artworkSlot)
        artwork.draw(in: artworkRect, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])

        Self.inkColor.withAlphaComponent(0.25).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: 22, y: 112))
        divider.line(to: CGPoint(x: size.width - 22, y: 112))
        divider.lineWidth = 1
        divider.stroke()

        // Signer and certificate details.
        (content.signerName as NSString).draw(
            in: NSRect(x: 22, y: 88, width: size.width - 44, height: 20),
            withAttributes: nameAttributes)
        var details: [String] = []
        if let certificateName = content.certificateName, !certificateName.isEmpty,
           certificateName != content.signerName {
            details.append("Certifikát: \(certificateName)")
        }
        if let qualification = content.certificateQualification, !qualification.isEmpty {
            details.append(qualification)
        }
        if let timestampAuthorityName = content.timestampAuthorityName,
           !timestampAuthorityName.isEmpty {
            details.append("Časová pečiatka: \(timestampAuthorityName)")
        }
        var y: CGFloat = 70
        for line in details.prefix(3) {
            (line as NSString).draw(
                in: NSRect(x: 22, y: y, width: size.width - 44, height: 15),
                withAttributes: detailAttributes)
            y -= 16
        }

        // Bottom row: time and status.
        let footerY: CGFloat = 14
        drawSymbol("clock.fill", in: NSRect(x: 22, y: footerY + 1, width: 13, height: 13), color: Self.mutedInkColor)
        let timestampAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Self.mutedInkColor,
            .paragraphStyle: paragraph
        ]
        let timeText = isPreview
            ? "Čas podpisu sa doplní"
            : Self.signingTimeFormatter.string(from: signingTime)
        (timeText as NSString).draw(
            in: NSRect(x: 40, y: footerY, width: 160, height: 15),
            withAttributes: timestampAttributes)
        drawSymbol("checkmark.seal.fill", in: NSRect(x: 206, y: footerY, width: 15, height: 15), color: Self.accentColor)
        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Self.accentColor,
            .paragraphStyle: paragraph
        ]
        let hasTimestamp = !(content.timestampAuthorityName ?? "").isEmpty
        let statusText: String
        if isPreview {
            statusText = "Náhľad kvalifikovaného podpisu"
        } else {
            statusText = hasTimestamp ? "Kvalifikovaný podpis s pečiatkou" : "Kvalifikovaný elektronický podpis"
        }
        (statusText as NSString).draw(
            in: NSRect(x: 226, y: footerY, width: size.width - 226 - 20, height: 15),
            withAttributes: statusAttributes)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Signature on a line, name on the left, time on the right. Certificate and
    /// qualification stay in the signature panel; they are not printed on the page.
    private func drawCompactCard(
        artwork: NSImage,
        content: VisibleSignatureCardContent,
        signingTime: Date,
        isPreview: Bool,
        size: NSSize
    ) {
        let inset: CGFloat = 14
        let captionY: CGFloat = 8
        let captionHeight: CGFloat = 16
        let lineY = captionY + captionHeight + 6
        let artworkSlot = NSRect(x: inset,
                                 y: lineY + 8,
                                 width: size.width - inset * 2,
                                 height: size.height - (lineY + 8) - 6)
        let artworkRect = Self.aspectFitRect(imageSize: artwork.size, inside: artworkSlot)
        artwork.draw(in: artworkRect, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])

        Self.mutedInkColor.setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: inset, y: lineY))
        line.line(to: CGPoint(x: size.width - inset, y: lineY))
        line.lineWidth = 1
        line.stroke()

        let nameStyle = NSMutableParagraphStyle()
        nameStyle.alignment = .left
        nameStyle.lineBreakMode = .byTruncatingTail
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: Self.inkColor,
            .paragraphStyle: nameStyle
        ]
        let timeStyle = NSMutableParagraphStyle()
        timeStyle.alignment = .right
        timeStyle.lineBreakMode = .byClipping
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: Self.mutedInkColor,
            .paragraphStyle: timeStyle
        ]
        let timeText = isPreview ? "Čas sa doplní" : Self.signingTimeFormatter.string(from: signingTime)
        let timeWidth = min((timeText as NSString).size(withAttributes: timeAttributes).width + 2,
                            size.width * 0.42)
        let gap: CGFloat = 12
        let name = content.signerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            (name as NSString).draw(
                in: NSRect(x: inset, y: captionY,
                           width: size.width - inset * 2 - timeWidth - gap,
                           height: captionHeight),
                withAttributes: nameAttributes)
        }
        (timeText as NSString).draw(
            in: NSRect(x: size.width - inset - timeWidth, y: captionY,
                       width: timeWidth, height: captionHeight),
            withAttributes: timeAttributes)
    }


    static let signingTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = "d. M. yyyy HH:mm"
        return formatter
    }()

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return
        }
        color.set()
        symbol.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func rotatedImage(_ image: NSImage, degrees: Double) throws -> NSImage {
        // Unrotated cards keep their high-resolution bitmap; lockFocus would resample them.
        if degrees.truncatingRemainder(dividingBy: 360) == 0 { return image }
        let radians = degrees * .pi / 180
        let sine = abs(sin(radians))
        let cosine = abs(cos(radians))
        let size = image.size
        let canvas = NSSize(
            width: ceil(size.width * cosine + size.height * sine) + 2,
            height: ceil(size.width * sine + size.height * cosine) + 2
        )
        let rotated = NSImage(size: canvas)
        rotated.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            rotated.unlockFocus()
            throw VisibleSignatureRendererError.unableToRender
        }
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(origin: .zero, size: canvas))
        context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        context.rotate(by: CGFloat(radians))
        image.draw(
            in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        rotated.unlockFocus()
        return rotated
    }
}
