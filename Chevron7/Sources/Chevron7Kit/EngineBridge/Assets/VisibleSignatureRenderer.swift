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
    public static let artworkSlot = NSRect(x: 22, y: 108, width: 376, height: 136)

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
    /// Facts on the left, the mark on the right. Wide, because that is the layout.
    public static let compactCardSize = NSSize(width: 380, height: 132)



    public static func cardSize(for layout: VisibleSignatureLayout) -> NSSize {
        layout == .compact ? compactCardSize : cardSize
    }
    static let renderScale: CGFloat = 3

    // Fixed colours: the card ends up on white paper, so it must not follow the
    // app appearance (labelColor turns white in dark mode and the text vanishes).
    static let inkColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let mutedInkColor = NSColor(calibratedWhite: 0.35, alpha: 1)
    static let accentColor = NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.27, alpha: 1)
    /// Quieter than the detailed card's seal, so the mark stays the signature.
    static let compactSealColor = NSColor(calibratedRed: 0.36, green: 0.50, blue: 0.40, alpha: 1)
    static let compactTimeColor = NSColor(calibratedRed: 0.55, green: 0.44, blue: 0.28, alpha: 1)
    static let sealFill = NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.40, alpha: 1)
    static let timeFill = NSColor(calibratedRed: 0.62, green: 0.48, blue: 0.30, alpha: 1)


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


        drawDetailedCard(artwork: artwork, content: content, signingTime: signingTime,
                         isPreview: isPreview, size: size)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
    /// White rounded card. The chevron in the mockup is the inspector control, not the stamp.
    private func drawCompactCard(
        artwork: NSImage,
        content: VisibleSignatureCardContent,
        signingTime: Date,
        isPreview: Bool,
        size: NSSize
    ) {
        drawCardBody(size: size, accent: nil)
        let columnX: CGFloat = 16
        let columnW: CGFloat = 146
        let dividerX = columnX + columnW + 6
        var rowY = size.height - 16 - 34
        if let code = Self.compactSignatureCode(content.certificateQualification) {
            drawFactRow(symbol: "checkmark", fill: Self.sealFill, title: code,
                        subtitle: Self.qualificationTitle(content.certificateQualification),
                        x: columnX, y: rowY, width: columnW)
            rowY -= 38
        }
        if let stamp = Self.compactTimestampCode(content.timestampAuthorityName) {
            let subtitle = stamp == "QTS" ? "Kvalifikovaná časová pečiatka" : "Časová pečiatka"
            drawFactRow(symbol: "clock.fill", fill: Self.timeFill, title: stamp,
                        subtitle: subtitle, x: columnX, y: rowY, width: columnW)
        }
        let name = content.signerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let plate = NSRect(x: columnX, y: 12, width: 22, height: 22)
            NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
            drawSymbol("creditcard", in: plate.insetBy(dx: 4, dy: 5), color: Self.mutedInkColor)
            drawWrapped(name, in: NSRect(x: columnX + 28, y: 8, width: columnW - 28, height: 30),
                        font: NSFont.systemFont(ofSize: 9, weight: .semibold), color: Self.inkColor)
        }
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: dividerX, y: 12))
        divider.line(to: CGPoint(x: dividerX, y: size.height - 12))
        divider.lineWidth = 1
        divider.stroke()
        let art = NSRect(x: dividerX + 8, y: 8, width: size.width - dividerX - 16, height: size.height - 16)
        artwork.draw(in: Self.aspectFitRect(imageSize: artwork.size, inside: art), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: false,
                     hints: [.interpolation: NSImageInterpolation.high])
    }

    /// Mark on top, two fact columns under it. The details button stays out of the stamp.
    private func drawDetailedCard(
        artwork: NSImage,
        content: VisibleSignatureCardContent,
        signingTime: Date,
        isPreview: Bool,
        size: NSSize
    ) {
        drawCardBody(size: size, accent: NSColor(calibratedRed: 0.24, green: 0.50, blue: 0.95, alpha: 1))
        let art = NSRect(x: 24, y: 112, width: size.width - 48, height: 132)
        artwork.draw(in: Self.aspectFitRect(imageSize: artwork.size, inside: art), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: false,
                     hints: [.interpolation: NSImageInterpolation.high])
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let rule = NSBezierPath()
        rule.move(to: CGPoint(x: 20, y: 104))
        rule.line(to: CGPoint(x: size.width - 20, y: 104))
        rule.lineWidth = 1
        rule.stroke()

        let badge: CGFloat = 26
        let textX: CGFloat = 22 + badge + 8
        let columnW = (size.width - 44) / 2 - badge
        drawBadge("checkmark", in: NSRect(x: 22, y: 52, width: badge, height: badge), fill: Self.sealFill)
        drawWrapped(Self.qualificationTitle(content.certificateQualification),
                    in: NSRect(x: textX, y: 56, width: columnW, height: 32),
                    font: NSFont.systemFont(ofSize: 11, weight: .bold), color: Self.inkColor)
        let name = content.signerName.trimmingCharacters(in: .whitespacesAndNewlines)
        drawWrapped(name, in: NSRect(x: textX, y: 34, width: columnW, height: 22),
                    font: NSFont.systemFont(ofSize: 10), color: Self.inkColor)
        if let certificate = content.certificateName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !certificate.isEmpty, certificate != name {
            drawWrapped(certificate, in: NSRect(x: textX, y: 16, width: columnW, height: 18),
                        font: NSFont.systemFont(ofSize: 9), color: Self.mutedInkColor)
        }

        let rightX = size.width / 2 + 8
        let rightText = rightX + badge + 8
        drawBadge("clock.fill", in: NSRect(x: rightX, y: 52, width: badge, height: badge), fill: Self.timeFill)
        drawWrapped(Self.timestampTitle(content.timestampAuthorityName) ?? "Čas podpisu",
                    in: NSRect(x: rightText, y: 56, width: columnW, height: 32),
                    font: NSFont.systemFont(ofSize: 11, weight: .bold), color: Self.inkColor)
        if let authority = content.timestampAuthorityName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authority.isEmpty {
            drawWrapped(authority, in: NSRect(x: rightText, y: 34, width: columnW, height: 22),
                        font: NSFont.systemFont(ofSize: 10), color: Self.inkColor)
        }
        let timeText = isPreview ? "Čas podpisu sa doplní" : Self.signingTimeFormatter.string(from: signingTime)
        drawWrapped(timeText, in: NSRect(x: rightText, y: 16, width: columnW, height: 16),
                    font: NSFont.systemFont(ofSize: 9), color: Self.mutedInkColor)
    }

    private func drawCardBody(size: NSSize, accent: NSColor?) {
        let rect = NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        guard let accent else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        accent.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height)).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawFactRow(symbol: String, fill: NSColor, title: String, subtitle: String,
                             x: CGFloat, y: CGFloat, width: CGFloat) {
        let badge: CGFloat = 22
        drawBadge(symbol, in: NSRect(x: x, y: y + 6, width: badge, height: badge), fill: fill)
        drawWrapped(title, in: NSRect(x: x + badge + 8, y: y + 16, width: width - badge - 8, height: 16),
                    font: NSFont.systemFont(ofSize: 12, weight: .bold), color: Self.inkColor)
        drawWrapped(subtitle, in: NSRect(x: x + badge + 8, y: y, width: width - badge - 8, height: 20),
                    font: NSFont.systemFont(ofSize: 8.5), color: Self.mutedInkColor)
    }

    private func drawBadge(_ symbol: String, in rect: NSRect, fill: NSColor) {
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()
        drawSymbol(symbol, in: rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.26), color: .white)
    }

    private func drawWrapped(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }


    /// eIDAS short name. Unknown or non-qualified text stays unlabeled rather than reading as QES.
    static func compactSignatureCode(_ qualification: String?) -> String? {
        switch qualification?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "QESIG", "Kvalifikovaný elektronický podpis": "QES"
        case "QESEAL": "QESeal"
        case "ADESIG", "ADESIG_QC": "AdES"
        case "ADESEAL", "ADESEAL_QC": "AdESeal"
        default: nil
        }
    }

    /// QTS only for an authority this app knows is qualified. A custom name is not claimed.
    static func compactTimestampCode(_ authorityName: String?) -> String? {
        guard let name = authorityName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        if TimestampAuthority.builtIn.contains(where: { $0.name == name })
            || name == "služba podpisu mobilom" {
            return "QTS"
        }
        if TimestampAuthority.retiredUnqualified.contains(where: { $0.name == name }) {
            return "TS"
        }
        return nil
    }

    static func qualificationTitle(_ qualification: String?) -> String {
        switch compactSignatureCode(qualification) {
        case "QES": return "Kvalifikovaný elektronický podpis"
        case "QESeal": return "Kvalifikovaná elektronická pečať"
        case "AdES": return "Zaručený elektronický podpis"
        case "AdESeal": return "Zaručená elektronická pečať"
        default:
            let text = qualification?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "Elektronický podpis" : text
        }
    }

    static func timestampTitle(_ authorityName: String?) -> String? {
        switch compactTimestampCode(authorityName) {
        case "QTS": return "Kvalifikovaná časová pečiatka"
        case "TS": return "Časová pečiatka"
        case nil:
            let name = authorityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : "Časová pečiatka"
        default: return nil
        }
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
            .withSymbolConfiguration(configuration),
              symbol.size.width > 0, symbol.size.height > 0 else { return }
        // alignmentRect is an optical inset, not a crop. Drawing from it clips the glyph.
        let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
        let fitted = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let alignment = symbol.alignmentRect
        var dest = NSRect(
            x: rect.midX - (alignment.midX / symbol.size.width) * fitted.width,
            y: rect.midY - (alignment.midY / symbol.size.height) * fitted.height,
            width: fitted.width,
            height: fitted.height)
        dest.origin.x = min(max(dest.minX, rect.minX), rect.maxX - dest.width)
        dest.origin.y = min(max(dest.minY, rect.minY), rect.maxY - dest.height)
        let tinted = NSImage(size: dest.size, flipped: false) { bounds in
            color.setFill()
            NSBezierPath(rect: bounds).fill()
            symbol.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
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
