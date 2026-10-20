// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import PDFKit
import AppKit
import Chevron7TestSupport
@testable import Chevron7Kit

final class EngineBridgeGeometryTests: XCTestCase {
    func testDSSFieldConvertsCropBoxLocalPlacementForPageRotations() {
        let placement = VisibleSignaturePlacement(
            pageIndex: 1,
            pageRect: CGRect(x: 72, y: 144, width: 216, height: 108),
            rotationDegrees: 31
        )
        let cropBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let converter = PDFCoordinateConverter()
        let cases: [(rotation: Int, originX: CGFloat, originY: CGFloat, width: CGFloat, height: CGFloat)] = [
            (0, 72, 540, 216, 108),
            (90, 540, 324, 108, 216),
            (180, 324, 144, 216, 108),
            (270, 144, 72, 108, 216)
        ]

        for testCase in cases {
            let field = converter.dssField(placement,
                                           cropBox: cropBox,
                                           pageRotation: testCase.rotation)
            XCTAssertEqual(field.page, 2)
            XCTAssertEqual(field.originX, testCase.originX)
            XCTAssertEqual(field.originY, testCase.originY)
            XCTAssertEqual(field.width, testCase.width)
            XCTAssertEqual(field.height, testCase.height)
        }
    }

    func testProviderVisibleAppearanceUsesCropBoxAndTopLeftOrigin() throws {
        let pdfData = TestPDFBuilder.singlePageWhitePDF()
        guard let document = PDFDocument(data: pdfData), let page = document.page(at: 0) else {
            return XCTFail("Testovacie PDF sa nepodarilo otvoriť.")
        }
        let cropBox = page.bounds(for: .cropBox)
        let workDirectory = try EngineBridgeSigningProvider.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let provider = EngineBridgeSigningProvider(renderer: VisibleSignatureRenderer(cacheRoot: workDirectory))

        // normalized y rastie zhora nadol; y=0.25 → cropBox-lokálne minY = 0.65 * height
        let stamp = VisualStampSpec(fullName: "Test Testovsky",
                                    timestamp: Date(),
                                    pageIndex: 0,
                                    normalizedRect: NormalizedRect(x: 0.1, y: 0.25, width: 0.3, height: 0.1),
                                    imagePNG: Data())
        let appearance = try provider.visibleAppearance(for: stamp,
                                                        certificateDisplayName: "Test",
                                                        qualification: nil,
                                                        pdfData: pdfData,
                                                        directory: workDirectory)

        XCTAssertEqual(appearance.page, 1)
        XCTAssertEqual(appearance.originX, cropBox.width * 0.1, accuracy: 0.5)
        // normalizovaná aj DSS os y rastie zhora nadol → originY = 0.25 * výška
        XCTAssertEqual(appearance.originY, cropBox.height * 0.25, accuracy: 0.5)
        XCTAssertEqual(appearance.width, cropBox.width * 0.3, accuracy: 0.5)
        XCTAssertEqual(appearance.height, cropBox.height * 0.1, accuracy: 0.5)

        let pngData = try Data(contentsOf: appearance.renderedPNGURL)
        XCTAssertEqual(Array(pngData.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "appearance musí byť PNG")
    }

    func testTextArtworkRendersPNG() {
        let png = EngineBridgeSigningProvider.textArtworkPNG(fullName: "Advokát Test", timestamp: Date())
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertGreaterThan(png.count, 200)
    }

    func testRenderedCardKeepsTransparentBackground() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let store = SignatureAssetStore(applicationSupportRoot: work)
        try FileManager.default.createDirectory(at: store.assetsDirectory, withIntermediateDirectories: true)
        let asset = SignatureAsset(id: UUID(), kind: .png, managedFilename: "art.png")
        try EngineBridgeSigningProvider.textArtworkPNG(fullName: "Test", timestamp: Date())
            .write(to: store.fileURL(for: asset))
        let url = try VisibleSignatureRenderer(assetStore: store, cacheRoot: work).render(
            asset: asset,
            content: VisibleSignatureCardContent(signerName: "Mgr. Test",
                                                 certificateQualification: "Kvalifikovaný elektronický podpis"),
            signingTime: Date(),
            rotationDegrees: 0)
        let png = try Data(contentsOf: url)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertGreaterThan(png.count, 4000, "Karta musí byť plná grafika, nie prázdne PNG")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        // Sample the empty inner margin, inside the former white card fill.
        let margin = Int(12 * VisibleSignatureRenderer.renderScale)
        let background = try XCTUnwrap(bitmap.colorAt(x: margin, y: bitmap.pixelsHigh / 2))
        XCTAssertLessThan(background.alphaComponent, 0.01, "Pozadie karty nesmie prekryť obsah dokumentu")
    }

    func testCompactSignatureLayoutIsShorterAndTransparent() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let store = SignatureAssetStore(applicationSupportRoot: work)
        try FileManager.default.createDirectory(at: store.assetsDirectory, withIntermediateDirectories: true)
        let asset = SignatureAsset(id: UUID(), kind: .png, managedFilename: "art.png")
        try signatureSquigglePNG().write(to: store.fileURL(for: asset))
        let renderer = VisibleSignatureRenderer(assetStore: store, cacheRoot: work)
        let content = VisibleSignatureCardContent(signerName: "JUDr. Jana Nováková",
                                                 certificateQualification: "Kvalifikovaný elektronický podpis",
                                                 timestampAuthorityName: nil)
        let detailedURL = try renderer.render(asset: asset, content: content, signingTime: Date(),
                                              rotationDegrees: 0, layout: .detailed)
        let compactURL = try renderer.render(asset: asset, content: content, signingTime: Date(),
                                             rotationDegrees: 0, isPreview: true, layout: .compact)
        let detailed = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: detailedURL)))
        let compact = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: compactURL)))
        XCTAssertLessThan(compact.pixelsHigh, detailed.pixelsHigh)
        XCTAssertEqual(compact.pixelsWide, Int(VisibleSignatureRenderer.compactCardSize.width * VisibleSignatureRenderer.renderScale))
        XCTAssertEqual(compact.pixelsHigh, Int(VisibleSignatureRenderer.compactCardSize.height * VisibleSignatureRenderer.renderScale))
        let corner = try XCTUnwrap(compact.colorAt(x: 2, y: 2))
        XCTAssertLessThan(corner.alphaComponent, 0.01, "Kompaktná pečiatka nesmie mať výplň karty")
        // Seal icon is x=8..<21 pt. QES text starts at 25 pt, so this band is the icon only.
        let scale = Int(VisibleSignatureRenderer.renderScale)
        let sealIcon = (9 * scale)..<(20 * scale)
        XCTAssertGreaterThan(Self.opaquePixels(in: compact, x: sealIcon, where: Self.isSealGreen), 4,
                             "Pečať v ikone má byť zafarbená, nie čierna šablóna")
        let timeWidth = ("Čas podpisu sa doplní" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11)
        ]).width
        let clockX = VisibleSignatureRenderer.compactCardSize.width - 8 - (timeWidth + 13 + 4 + 2)
        let clock = Int(clockX * CGFloat(scale))..<Int((clockX + 13) * CGFloat(scale))
        XCTAssertGreaterThan(Self.opaquePixels(in: compact, x: clock, where: Self.isTimeAmber), 4,
                             "Hodiny v ikone majú byť zafarbené")
        XCTAssertEqual(
            Self.opaquePixels(in: compact, x: 0..<clock.lowerBound, where: Self.isTimeAmber)
            + Self.opaquePixels(in: compact, x: clock.upperBound..<compact.pixelsWide, where: Self.isTimeAmber),
            0, "Jantárová farba smie byť len v ikone hodín")

        XCTAssertEqual(VisibleSignatureRenderer.compactSignatureCode("QESIG"), "QES")
        XCTAssertEqual(VisibleSignatureRenderer.compactSignatureCode("Kvalifikovaný elektronický podpis"), "QES")
        XCTAssertEqual(VisibleSignatureRenderer.compactSignatureCode("QESEAL"), "QESeal")
        XCTAssertEqual(VisibleSignatureRenderer.compactSignatureCode("ADESIG"), "AdES")
        XCTAssertNil(VisibleSignatureRenderer.compactSignatureCode("Nekvalifikovaný certifikát"))
        XCTAssertEqual(VisibleSignatureRenderer.compactTimestampCode("Belgium BOSA (kvalifikovaná)"), "QTS")
        XCTAssertEqual(VisibleSignatureRenderer.compactTimestampCode("DigiCert (nekvalifikovaná)"), "TS")
        XCTAssertNil(VisibleSignatureRenderer.compactTimestampCode("https://tsa.kancelaria.test/tsp"))
    }

    private static func opaquePixels(in bitmap: NSBitmapImageRep, x range: Range<Int>,
                                     where matches: (CGFloat, CGFloat, CGFloat) -> Bool) -> Int {
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5,
                      matches(color.redComponent, color.greenComponent, color.blueComponent) else { continue }
                count += 1
            }
        }
        return count
    }

    private static func isSealGreen(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Bool {
        green > 0.42 && green > red && green > blue
    }

    private static func isTimeAmber(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Bool {
        red > 0.35 && red > green && red > blue && green > 0.15
    }
    private func signatureSquigglePNG() throws -> Data {
        let size = NSSize(width: 360, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 16, y: 42))
        path.curve(to: NSPoint(x: 130, y: 78),
                   controlPoint1: NSPoint(x: 40, y: 112),
                   controlPoint2: NSPoint(x: 90, y: 8))
        path.curve(to: NSPoint(x: 230, y: 48),
                   controlPoint1: NSPoint(x: 168, y: 140),
                   controlPoint2: NSPoint(x: 190, y: 18))
        path.curve(to: NSPoint(x: 340, y: 70),
                   controlPoint1: NSPoint(x: 270, y: 92),
                   controlPoint2: NSPoint(x: 310, y: 28))
        NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.45, alpha: 1).setStroke()
        path.lineWidth = 3.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw VisibleSignatureRendererError.unableToEncode
        }
        return png
    }
}

@MainActor
final class VisibleSignatureLayoutTests: XCTestCase {
    func testLayoutChoicePersistsAndRefitsThePlacedBaseline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = SignatureAssetStore(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: assets.assetsDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let asset = SignatureAsset(id: id, kind: .png, managedFilename: "\(id.uuidString).png")
        try EngineBridgeSigningProvider.textArtworkPNG(fullName: "Test", timestamp: Date())
            .write(to: assets.fileURL(for: asset))
        let document = try XCTUnwrap(PDFDocument(data: TestPDFBuilder.singlePageWhitePDF()))
        let defaults = MemoryUserDefaults()
        let state = SignaturePlacementState(assetStore: assets, document: document,
                                            defaults: defaults, cacheRoot: cache)
        state.select(asset)
        let placed = try XCTUnwrap(state.placement)
        state.setLayout(.compact)
        let refitted = try XCTUnwrap(state.placement)
        let aspect = VisibleSignatureRenderer.compactCardSize.width
            / VisibleSignatureRenderer.compactCardSize.height
        XCTAssertEqual(state.layout, .compact)
        XCTAssertEqual(refitted.pageRect.minY, placed.pageRect.minY, accuracy: 0.5)
        XCTAssertEqual(refitted.pageRect.height, refitted.pageRect.width / aspect, accuracy: 1)
        XCTAssertLessThan(refitted.pageRect.height, placed.pageRect.height)
        XCTAssertEqual(state.cardPreview?.size, VisibleSignatureRenderer.compactCardSize)

        let restored = SignaturePlacementState(assetStore: assets, document: document,
                                               defaults: defaults, cacheRoot: cache)
        XCTAssertEqual(restored.layout, .compact)
        XCTAssertEqual(restored.selectedAsset?.id, asset.id)
    }

    func testSavedChoiceWithoutLayoutStaysDetailed() throws {
        let defaults = MemoryUserDefaults()
        let payload = try JSONSerialization.data(withJSONObject: ["assetID": UUID().uuidString])
        defaults.set(payload, forKey: SignaturePlacementState.preferencesKey)
        let state = SignaturePlacementState(assetStore: SignatureAssetStore(
            applicationSupportRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("layout-old-\(UUID().uuidString)", isDirectory: true)),
                                            defaults: defaults,
                                            cacheRoot: FileManager.default.temporaryDirectory)
        XCTAssertEqual(state.layout, .detailed)
        XCTAssertNil(state.selectedAsset)
    }

    func testCompactLayoutReachesStamperAndEngineAppearance() throws {
        let artwork = EngineBridgeSigningProvider.textArtworkPNG(fullName: "Test", timestamp: Date())
        let document = try XCTUnwrap(PDFDocument(data: TestPDFBuilder.singlePageWhitePDF()))
        let compactStamp = VisibleSignatureStamper.StampData(
            fullName: "JUDr. Test",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            pageIndex: 0,
            normalizedRect: NormalizedRect(x: 0.5, y: 0.7, width: 0.3, height: 0.08),
            imagePNG: artwork,
            layout: .compact)
        _ = VisibleSignatureStamper().stamp(
            document: document, stamp: compactStamp, includeTimestamp: true)
        let annotation = try XCTUnwrap(
            document.page(at: 0)?.annotations
                .compactMap { $0 as? ImageStampAnnotation }.first)
        XCTAssertEqual(annotation.renderedSize, VisibleSignatureRenderer.compactCardSize)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let provider = EngineBridgeSigningProvider(renderer: VisibleSignatureRenderer(cacheRoot: work))
        let spec = VisualStampSpec(fullName: "JUDr. Test",
                                   timestamp: Date(),
                                   pageIndex: 0,
                                   normalizedRect: NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
                                   imagePNG: artwork,
                                   layout: .compact)
        let appearance = try provider.visibleAppearance(for: spec,
                                                        certificateDisplayName: "JUDr. Test",
                                                        qualification: nil,
                                                        pdfData: TestPDFBuilder.singlePageWhitePDF(),
                                                        directory: work)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: appearance.renderedPNGURL)))
        XCTAssertEqual(bitmap.pixelsHigh,
                       Int(VisibleSignatureRenderer.compactCardSize.height * VisibleSignatureRenderer.renderScale))
    }
}


final class EngineBridgeSelectionTests: XCTestCase {
    private func certificate(serial: String, qualification: String?) -> SigningCertificate {
        SigningCertificate(serialNumber: serial,
                           displayName: "Cert \(serial)",
                           issuer: "eID SR",
                           validFrom: .distantPast,
                           validUntil: .distantFuture,
                           certificateKey: "v1:key-\(serial)",
                           holderKey: "holder-\(serial)",
                           certificateQualification: qualification)
    }

    func testPrefersQualifiedSignatureCertificate() {
        let selected = EngineBridgeSigningProvider.selectCertificate(
            from: [certificate(serial: "111", qualification: nil),
                   certificate(serial: "222", qualification: "QESIG")],
            preferredSerialNumber: nil)
        XCTAssertEqual(selected?.serialNumber, "222")
    }

    func testPreferredSerialWinsOverQualification() {
        let selected = EngineBridgeSigningProvider.selectCertificate(
            from: [certificate(serial: "111", qualification: nil),
                   certificate(serial: "222", qualification: "QESIG")],
            preferredSerialNumber: "111")
        XCTAssertEqual(selected?.serialNumber, "111")
    }

    func testSyntheticIdentityIsQualifiedButNotMandate() {
        let identity = EngineBridgeSigningProvider.syntheticIdentity()
        XCTAssertEqual(identity.id, "engine:eid")
        XCTAssertTrue(identity.isQualified)
        XCTAssertFalse(identity.isMandateCertificate,
                       "eID je QES – mandátny flag patrí len advokátskemu/notárskemu preukazu.")
        XCTAssertTrue(identity.requiresPIN)
        let named = EngineBridgeSigningProvider.syntheticIdentity(driverNames: ["I.CA SecureStore"])
        XCTAssertTrue(named.label.contains("I.CA SecureStore"))
    }

    /// eID tokens report CKF_PROTECTED_AUTHENTICATION_PATH (checked on a real card:
    /// slots Sig_ZEP and Sig_EP), so the BOK is typed in the eID client's own
    /// window and the app collects no PIN for it (`requiresPIN` false); every other
    /// card takes its PIN from the app.
    func testOnlyEIDIdentitiesUseTheProtectedAuthenticationPath() {
        let eid = EngineBridgeSigningProvider.syntheticIdentity(driverNames: ["eID"], driverID: "eid")
        XCTAssertTrue(eid.usesProtectedAuthenticationPath)
        XCTAssertFalse(eid.requiresPIN)
        XCTAssertEqual(eid.issuerSummary, EngineBridgeSigningProvider.eidLoadCertificatesHint)
        let ica = EngineBridgeSigningProvider.syntheticIdentity(driverNames: ["I.CA"], driverID: "secure_store")
        XCTAssertFalse(ica.usesProtectedAuthenticationPath)
        XCTAssertTrue(ica.requiresPIN)
        XCTAssertEqual(ica.issuerSummary, EngineBridgeSigningProvider.pinLoadCertificatesHint)

        let certificate = SigningCertificate(serialNumber: "42", displayName: "Marián Čuprík")
        let eidCertificate = EngineBridgeSigningProvider.identityInfo(from: certificate, driverID: "eid")
        XCTAssertTrue(eidCertificate.usesProtectedAuthenticationPath)
        XCTAssertFalse(eidCertificate.requiresPIN)
        let icaCertificate = EngineBridgeSigningProvider.identityInfo(from: certificate, driverID: "secure_store")
        XCTAssertFalse(icaCertificate.usesProtectedAuthenticationPath)
        XCTAssertTrue(icaCertificate.requiresPIN)
    }

    /// A portal looks for the original PDF by name inside the ASiC-E it gets back.
    func testAsicSourceKeepsThePortalFilename() {
        func request(_ format: SigningOutputFormat, _ filename: String?) -> SigningRequest {
            SigningRequest(pdfData: Data(), identityID: "x", includeTimestamp: false,
                           outputFormat: format, filename: filename)
        }
        XCTAssertEqual(EngineBridgeSigningProvider.pdfSourceName(for: request(.attachedASIC, "122085-Navrhasuhlas.pdf")),
                       "122085-Navrhasuhlas.pdf")
        XCTAssertEqual(EngineBridgeSigningProvider.pdfSourceName(for: request(.attachedASIC, "../../etc/zmluva.pdf")),
                       "zmluva.pdf")
        XCTAssertEqual(EngineBridgeSigningProvider.pdfSourceName(for: request(.attachedASIC, "formular.xml")), "document.pdf")
        XCTAssertEqual(EngineBridgeSigningProvider.pdfSourceName(for: request(.attachedASIC, nil)), "document.pdf")
        XCTAssertEqual(EngineBridgeSigningProvider.pdfSourceName(for: request(.embeddedPAdES, "zmluva.pdf")), "document.pdf")
    }

    func testCardKindNamesTheEIDAndICACards() {
        XCTAssertEqual(EngineBridgeSigningProvider.syntheticIdentity(driverNames: ["Občiansky preukaz (eID klient)"],
                                                                    driverID: "eid").cardKindLabel,
                       "Občiansky preukaz (eID)")
        XCTAssertEqual(EngineBridgeSigningProvider.syntheticIdentity(driverNames: ["I.CA SecureStore"],
                                                                    driverID: "secure_store").cardKindLabel,
                       "Karta I.CA")
        let ica = SigningIdentityInfo(id: "engine-cert:1", label: "Marián Čuprík OPRÁVNENIE 1042",
                                      issuerSummary: "I.CA EU Qualified CA-SK/RSA 10/2022", requiresPIN: true)
        XCTAssertEqual(ica.cardKindLabel, "Karta I.CA")
        let unknown = SigningIdentityInfo(id: "x", label: "Test", issuerSummary: "Neznáma CA")
        XCTAssertNil(unknown.cardKindLabel)
    }

    /// Each eID certificate read opens the BOK window, so a portal signature with the
    /// eID goes straight to signing, where the engine picks the card's signing key.
    func testOnlyAnEIDWithoutChosenCertificateOrStampSkipsDiscovery() {
        XCTAssertTrue(EngineBridgeSigningProvider.signsWithoutCertificateDiscovery(
            driverID: "eid", preferredSerial: nil, hasVisualStamp: false))
        XCTAssertFalse(EngineBridgeSigningProvider.signsWithoutCertificateDiscovery(
            driverID: "eid", preferredSerial: "42", hasVisualStamp: false))
        XCTAssertFalse(EngineBridgeSigningProvider.signsWithoutCertificateDiscovery(
            driverID: "eid", preferredSerial: nil, hasVisualStamp: true))
        XCTAssertFalse(EngineBridgeSigningProvider.signsWithoutCertificateDiscovery(
            driverID: "secure_store", preferredSerial: nil, hasVisualStamp: false))
        XCTAssertEqual(EngineBridgeSigningProvider.signingKeyOnToken, "*")
    }

    func testEnginePINUsesThePlaceholderOnlyForAnEmptyEIDEntry() {
        let placeholder = EngineBridgeSigningProvider.protectedAuthenticationPathPIN
        XCTAssertEqual(EngineBridgeSigningProvider.enginePIN(entered: "", driverID: "eid"), placeholder)
        XCTAssertEqual(EngineBridgeSigningProvider.enginePIN(entered: "123456", driverID: "eid"), "123456")
        XCTAssertNil(EngineBridgeSigningProvider.enginePIN(entered: "", driverID: "secure_store"))
        XCTAssertEqual(EngineBridgeSigningProvider.enginePIN(entered: "1234", driverID: "secure_store"), "1234")
    }

    func testTrustedListFailureIsSlovak() {
        let mapped = EngineBridgeSigningProvider.localizedEngineMessage(
            "The machine request could not be completed. [TRUSTED_LIST_UNAVAILABLE]")
        XCTAssertTrue(mapped.contains("dôveryhodných CA"))
        XCTAssertFalse(mapped.contains("machine request"))
    }

    /// tsl.belgium.be was down on 2026-10-02: a BOSA timestamp then cannot be shown
    /// qualified, and the person learns which country's list is missing and what to do.
    func testMissingNationalListNamesTheCountryAndAsksForAnotherAuthority() {
        let message = AutogramCLIEngine.fileFailureMessage(code: "TRUSTED_LIST_UNAVAILABLE", country: "BE")
        let mapped = EngineBridgeSigningProvider.localizedEngineMessage(message)
        XCTAssertTrue(mapped.contains("Belgicko"), mapped)
        XCTAssertTrue(mapped.contains("inú autoritu časovej pečiatky"), mapped)
        XCTAssertFalse(mapped.contains("dôveryhodných CA"), mapped)
        XCTAssertFalse(mapped.contains("\u{2014}"))
    }

    func testFileFailureCarriesACountryOnlyWhenTheEngineNamesOne() {
        XCTAssertEqual(AutogramCLIEngine.fileFailureMessage(code: "TRUSTED_LIST_UNAVAILABLE", country: nil),
                       "Signing failed. [TRUSTED_LIST_UNAVAILABLE]")
        XCTAssertEqual(AutogramCLIEngine.fileFailureMessage(code: "TRUSTED_LIST_UNAVAILABLE", country: "BE"),
                       "Signing failed. [TRUSTED_LIST_UNAVAILABLE] [country:BE]")
        XCTAssertEqual(AutogramCLIEngine.fileFailureMessage(code: "TRUSTED_LIST_UNAVAILABLE", country: "B]E"),
                       "Signing failed. [TRUSTED_LIST_UNAVAILABLE]")
    }

    func testUnknownCountryCodeIsShownAsItIs() {
        let mapped = EngineBridgeSigningProvider.localizedEngineMessage(
            "Signing failed. [TRUSTED_LIST_UNAVAILABLE] [country:XQ]")
        XCTAssertTrue(mapped.contains("XQ"), mapped)
    }

    /// The engine keeps the last good copy of every trusted list in the app's caches,
    /// never in the temporary directory, and a test names its own root.
    func testSigningHelperKeepsTrustedListsUnderTheCacheRoot() {
        let root = URL(fileURLWithPath: "/private/tmp/cache-root-\(UUID().uuidString)", isDirectory: true)
        let environment = ProcessConfiguration.signingHelperEnvironment(
            from: ["AUTOGRAM_TRUSTED_LIST_CACHE": "/elsewhere", "HOME": "/Users/test"], cacheRoot: root)
        XCTAssertEqual(environment["AUTOGRAM_TRUSTED_LIST_CACHE"],
                       root.appending(path: "Chevron7/Trusted Lists", directoryHint: .isDirectory).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// A timestamp authority that refuses the request (no contract, down) tells the person to
    /// pick another one instead of reporting a generic signing failure.
    func testRefusedTimestampAsksForAnotherAuthority() {
        let mapped = EngineBridgeSigningProvider.localizedEngineMessage(
            "A qualified timestamp could not be obtained. [TIMESTAMP_FAILED]")
        XCTAssertTrue(mapped.contains("Vyberte inú autoritu"))
        XCTAssertFalse(mapped.contains("\u{2014}"))
    }

    /// CA Disig's qualified service answers only under a contract, which the picker says.
    func testDisigSaysItNeedsAContract() throws {
        let disig = try XCTUnwrap(TimestampAuthority.builtIn.first { $0.url == "http://tsa.disig.sk/qts" })
        XCTAssertTrue(disig.name.contains("vyžaduje zmluvu s Disig"))
        XCTAssertTrue(disig.isQualified)
    }

    func testPrimaryDriverPrefersEIDLikeCertificateDiscovery() {
        XCTAssertEqual(EngineBridgeSigningProvider.primaryDriverID(fingerprint: "eid,secure_store"), "eid")
        XCTAssertEqual(EngineBridgeSigningProvider.primaryDriverID(fingerprint: "secure_store"), "secure_store")
        XCTAssertNil(EngineBridgeSigningProvider.primaryDriverID(fingerprint: ""))
    }

    func testMandateDetectionDistinguishesCards() {
        XCTAssertFalse(EngineBridgeSigningProvider.isMandateCertificate(
            issuer: "SVK eID ACA2", displayName: "Marián Čuprík"))
        XCTAssertFalse(EngineBridgeSigningProvider.isMandateCertificate(
            issuer: "I.CA Public CA/RSA 05/2022", displayName: "Marián Čuprík"))
        XCTAssertFalse(EngineBridgeSigningProvider.isQualifiedCertificate(
            issuer: "I.CA Public CA/RSA 05/2022", displayName: "Marián Čuprík", qualification: nil))
        XCTAssertTrue(EngineBridgeSigningProvider.isMandateCertificate(
            issuer: "I.CA EU Qualified CA-SK/RSA 10/2022",
            displayName: "Marián Čuprík OPRÁVNENIE 1042",
            qualification: "QESIG"))
        XCTAssertTrue(EngineBridgeSigningProvider.isQualifiedCertificate(
            issuer: "I.CA EU Qualified CA-SK/RSA 10/2022",
            displayName: "Marián Čuprík OPRÁVNENIE 1042",
            qualification: "QESIG"))
    }

    func testIdentityInfoMapsCertificateFields() {
        let info = EngineBridgeSigningProvider.identityInfo(
            from: certificate(serial: "42", qualification: "QESIG"), driverID: "eid")
        XCTAssertEqual(info.id, "engine-cert:42")
        XCTAssertEqual(info.label, "Cert 42")
        XCTAssertEqual(info.issuerSummary, "eID SR")
        XCTAssertTrue(info.isQualified)
        XCTAssertFalse(info.isMandateCertificate, "eID issuer → nie mandate")
    }
}

final class EngineBridgeContainerTests: XCTestCase {
    private func unzipAsice(_ data: Data) -> [String: Data] {
        var result: [String: Data] = [:]
        var offset = 0
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int {
            Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        while offset + 30 <= bytes.count, u32(offset) == 0x04034b50 {
            let nameLength = u16(offset + 26)
            let extraLength = u16(offset + 28)
            let compressedSize = u32(offset + 18)
            let nameStart = offset + 30
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            let dataStart = nameStart + nameLength + extraLength
            if u16(offset + 8) == 0 {
                result[name] = Data(bytes[dataStart..<dataStart + compressedSize])
            } else {
                result[name] = nil
            }
            offset = dataStart + compressedSize
        }
        return result
    }

    func testPackageContainerAddsMimetypeAndManifest() throws {
        let data = try EngineBridgeSigningProvider.packageContainer(entries: [
            ASiCEPackager.Entry(path: "dokument.pdf", data: Data("pdf".utf8)),
            ASiCEPackager.Entry(path: "dolozka.xml.xdcf", data: Data("xml".utf8))
        ])
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "ASiC-E musí byť ZIP")
        let zip = unzipAsice(data)
        XCTAssertEqual(String(decoding: zip["mimetype"] ?? Data(), as: UTF8.self),
                       ASiCEPackager.asicMimeType)
        XCTAssertNotNil(zip["META-INF/manifest.xml"])
        XCTAssertNotNil(zip["dokument.pdf"])
        XCTAssertNotNil(zip["dolozka.xml.xdcf"])
        let manifest = String(decoding: zip["META-INF/manifest.xml"] ?? Data(), as: UTF8.self)
        XCTAssertTrue(manifest.contains("dokument.pdf"))
        XCTAssertTrue(manifest.contains("dolozka.xml.xdcf"))
    }

    func testPackageContainerKeepsProvidedManifest() throws {
        let customManifest = "<manifest>custom</manifest>"
        let data = try EngineBridgeSigningProvider.packageContainer(entries: [
            ASiCEPackager.Entry(path: "mimetype",
                                data: Data(ASiCEPackager.asicMimeType.utf8),
                                storeUncompressed: true),
            ASiCEPackager.Entry(path: "META-INF/manifest.xml", data: Data(customManifest.utf8))
        ])
        let zip = unzipAsice(data)
        XCTAssertEqual(String(decoding: zip["META-INF/manifest.xml"] ?? Data(), as: UTF8.self),
                       customManifest)
    }
}

final class JavaEngineLocatorTests: XCTestCase {
    func testLocateFindsValidRootWithHelperPreference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-root-\(UUID().uuidString)", isDirectory: true)
        let java = root.appendingPathComponent("runtime/bin/java")
        let jar = root.appendingPathComponent("app/autogram.jar")
        let helper = root.appendingPathComponent("Helpers/AutogramCLI-arm64")
        for directory in [java.deletingLastPathComponent(), jar.deletingLastPathComponent(),
                          helper.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\n".utf8).write(to: java)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        try Data().write(to: jar)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = JavaEngineLocator(candidateRoots: [root.path])
        guard let installation = locator.locate() else {
            return XCTFail("Platný root nebol rozpoznaný.")
        }
        XCTAssertEqual(installation.helperURL.path, helper.path)
    }

    func testLocateReturnsNilWithoutJarOrExecutable() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-root-\(UUID().uuidString)", isDirectory: true)
        let locator = JavaEngineLocator(candidateRoots: [root.path])
        XCTAssertNil(locator.locate())
    }
}

final class MachineRequestEncodingTests: XCTestCase {
    private func request(format: EngineSigningOutputFormat, override: String?) -> EngineSigningRequest {
        EngineSigningRequest(sessionID: UUID(), driverID: "secure_store", certificateSerial: "1",
                             pin: Secret("1234"), files: [], outputFormat: format,
                             signatureLevelOverride: override)
    }

    /// A portal's XAdES Baseline B went out as Baseline T on the protocol v1 path,
    /// which ignored the override: with the timestamp switch off that failed with
    /// TSA_REQUIRED, with it on the portal got a timestamp it had not asked for.
    func testPortalBaselineBGoesOutWithoutATimestamp() {
        let payload = AutogramCLIEngine.levelAndTimestamp(for: request(format: .asiceXAdES, override: "XAdES_BASELINE_B"),
                                                          endpoints: [])

        XCTAssertEqual(payload.level, "XAdES_BASELINE_B")
        XCTAssertEqual(payload.timestamp, .object(["required": .bool(false), "servers": .array([])]))
    }

    /// A content timestamp names its authorities even at Baseline B, where no signature
    /// timestamp is asked for; the engine reads `content` on both protocol versions.
    func testAContentTimestampNamesItsServersAtBaselineB() {
        let request = EngineSigningRequest(sessionID: UUID(), driverID: "secure_store", certificateSerial: "1",
                                           pin: Secret("1234"), files: [], outputFormat: .pades,
                                           signatureLevelOverride: "PAdES_BASELINE_B", contentTimestamp: true)
        let payload = AutogramCLIEngine.levelAndTimestamp(for: request, endpoints: ["http://tsa.belgium.be/connect"])

        XCTAssertEqual(payload.level, "PAdES_BASELINE_B")
        XCTAssertEqual(payload.timestamp, .object([
            "required": .bool(false), "servers": .array([.string("http://tsa.belgium.be/connect")]),
            "content": .bool(true)]))
    }

    func testAContentTimestampRidesAlongWithTheSignatureTimestamp() {
        let request = EngineSigningRequest(sessionID: UUID(), driverID: "secure_store", certificateSerial: "1",
                                           pin: Secret("1234"), files: [], outputFormat: .asiceXAdES,
                                           contentTimestamp: true)
        let payload = AutogramCLIEngine.levelAndTimestamp(for: request, endpoints: ["http://tsa.belgium.be/connect"])

        XCTAssertEqual(payload.level, "XAdES_BASELINE_T")
        XCTAssertEqual(payload.timestamp, .object([
            "required": .bool(true), "servers": .array([.string("http://tsa.belgium.be/connect")]),
            "content": .bool(true)]))
    }

    func testAppFlowsKeepTheQualifiedTimestamp() {
        let payload = AutogramCLIEngine.levelAndTimestamp(for: request(format: .asiceXAdES, override: nil),
                                                          endpoints: ["https://tsa.example.test"])

        XCTAssertEqual(payload.level, "XAdES_BASELINE_T")
        XCTAssertEqual(payload.timestamp,
                       .object(["required": .bool(true), "servers": .array([.string("https://tsa.example.test")])]))
    }

    /// ZaKo hands the engine the PDF/A and the clause XDC as two data objects of one
    /// ASiC-E; the v1 SIGN file object gains an "attachments" array of canonical paths.
    func testV1SignFileIncludesAttachmentsWhenPresent() {
        let engine = AutogramCLIEngine()
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("dokument.pdf")
        let attachmentURL = FileManager.default.temporaryDirectory.appendingPathComponent("dokument.xml.xdcf")
        let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("out.asice")

        let file = engine.machineFile(id: "document", sourceURL: sourceURL, targetURL: targetURL,
                                      attachmentURLs: [attachmentURL])

        XCTAssertEqual(file, .object([
            "id": .string("document"),
            "source": .string(EnginePaths.canonical(sourceURL).path),
            "target": .string(EnginePaths.canonical(targetURL).path),
            "attachments": .array([.string(EnginePaths.canonical(attachmentURL).path)])
        ]))
    }

    /// The Java validator refuses an empty "attachments" array, so the key must be
    /// absent entirely when there are no attachments, exactly like it is today.
    func testV1SignFileOmitsAttachmentsKeyWhenEmpty() {
        let engine = AutogramCLIEngine()
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("dokument.pdf")
        let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("out.asice")

        let file = engine.machineFile(id: "document", sourceURL: sourceURL, targetURL: targetURL)

        XCTAssertEqual(file, .object([
            "id": .string("document"),
            "source": .string(EnginePaths.canonical(sourceURL).path),
            "target": .string(EnginePaths.canonical(targetURL).path)
        ]))
    }

    func testUnauthenticatedV1RequestKeepsDriversPayloadEmpty() throws {
        let request = MachineRequest(
            protocolVersion: 1,
            requestID: "drivers-test",
            operation: .drivers,
            payload: [:])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MachineRequestEncoder.encode(request)) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])

        XCTAssertTrue(payload.isEmpty)
    }

    func testUnauthenticatedV2RequestKeepsPayloadEmpty() throws {
        let request = SecureMachineV2Request(
            envelope: MachineV2Request.capabilities(requestID: "capabilities-test"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MachineV2RequestEncoder.encode(request)) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])

        XCTAssertTrue(payload.isEmpty)
    }

    /// A record's explicit timestamp servers must reach the v1 SIGN payload's
    /// "timestamp.servers" exactly, and unconfigured timestamp preferences never stop it.
    func testExplicitTimestampServersOverrideTheProviderInTheV1Payload() throws {
        let provider = FakeTimestampSourceProvider(configuration: .automatic)
        let engine = AutogramCLIEngine(timestampSourceProvider: provider)
        let overrideRequest = request(format: .asiceXAdES, override: nil)

        let timestamp = try engine.resolvedTimestamp(wantsTimestamp: true,
                                                      override: ["https://tsa.belgium.be/connect"])
        let payload = AutogramCLIEngine.levelAndTimestamp(for: overrideRequest, endpoints: timestamp.endpoints)

        XCTAssertEqual(payload.timestamp,
                       .object(["required": .bool(true), "servers": .array([.string("https://tsa.belgium.be/connect")])]))
        XCTAssertNil(timestamp.authentication)
    }

    /// A chosen authority that is the configured custom provider keeps its Basic credential.
    func testAnOverrideForTheCustomProviderCarriesItsBasicCredential() throws {
        let custom = CustomTimestampProviderConfiguration(
            displayName: "Firemná TSA", urls: ["https://tsa.example.test/qts"],
            authentication: TimestampAuthenticationPreference(kind: .basic, username: "advokat"))
        let provider = FakeTimestampSourceProvider(
            configuration: TimestampSourceConfiguration(source: .custom, customProvider: custom),
            credential: Secret("heslo"))
        let engine = AutogramCLIEngine(timestampSourceProvider: provider)

        let timestamp = try engine.resolvedTimestamp(wantsTimestamp: true, override: ["https://tsa.example.test/qts"])

        XCTAssertEqual(timestamp.endpoints, ["https://tsa.example.test/qts"])
        guard case .basic(let username, _)? = timestamp.authentication else {
            return XCTFail("Expected Basic authentication for the custom provider.")
        }
        XCTAssertEqual(username, "advokat")
    }

    func testAnOverrideForTheCustomProviderCarriesItsBearerToken() throws {
        let custom = CustomTimestampProviderConfiguration(
            urls: ["https://tsa.example.test/qts"],
            authentication: TimestampAuthenticationPreference(kind: .bearer, username: nil))
        let provider = FakeTimestampSourceProvider(
            configuration: TimestampSourceConfiguration(source: .custom, customProvider: custom),
            credential: Secret("token"))
        let engine = AutogramCLIEngine(timestampSourceProvider: provider)

        let timestamp = try engine.resolvedTimestamp(wantsTimestamp: true, override: ["https://tsa.example.test/qts"])

        guard case .bearer? = timestamp.authentication else {
            return XCTFail("Expected a bearer token for the custom provider.")
        }
    }

    /// Another authority never receives the custom provider's credential.
    func testAnOverrideForAnotherAuthorityCarriesNoCredential() throws {
        let custom = CustomTimestampProviderConfiguration(
            urls: ["https://tsa.example.test/qts"],
            authentication: TimestampAuthenticationPreference(kind: .basic, username: "advokat"))
        let provider = FakeTimestampSourceProvider(
            configuration: TimestampSourceConfiguration(source: .custom, customProvider: custom),
            credential: Secret("heslo"))
        let engine = AutogramCLIEngine(timestampSourceProvider: provider)

        let timestamp = try engine.resolvedTimestamp(wantsTimestamp: true, override: ["http://tsa.disig.sk/qts"])

        XCTAssertEqual(timestamp.endpoints, ["http://tsa.disig.sk/qts"])
        XCTAssertNil(timestamp.authentication)
    }

    /// Without an override, resolution keeps reading the provider's own endpoints,
    /// exactly as it did before the record path existed.
    func testWithoutOverrideTheV1PayloadKeepsTheProvidersEndpoints() throws {
        let provider = FakeTimestampSourceProvider(configuration: .automatic)
        let engine = AutogramCLIEngine(timestampSourceProvider: provider)
        let plainRequest = request(format: .asiceXAdES, override: nil)

        let timestamp = try engine.resolvedTimestamp(wantsTimestamp: true, override: nil)
        let payload = AutogramCLIEngine.levelAndTimestamp(for: plainRequest, endpoints: timestamp.endpoints)

        XCTAssertEqual(payload.timestamp,
                       .object(["required": .bool(true),
                                "servers": .array(TimestampSourceConfiguration.automatic.endpoints.map(JSONValue.string))]))
        XCTAssertEqual(provider.loadCallCount, 1)
    }
}

/// A `TimestampSourceProviding` test double: never touches `UserDefaults` or the
/// Keychain, just returns a fixed configuration and counts how often it was read.
private final class FakeTimestampSourceProvider: TimestampSourceProviding, @unchecked Sendable {
    private let configuration: TimestampSourceConfiguration
    private let storedCredential: Secret?
    private let lock = NSLock()
    private var _loadCallCount = 0

    var loadCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _loadCallCount
    }

    init(configuration: TimestampSourceConfiguration, credential: Secret? = nil) {
        self.configuration = configuration
        storedCredential = credential
    }

    func load() -> TimestampSourceConfiguration {
        lock.lock()
        _loadCallCount += 1
        lock.unlock()
        return configuration
    }

    func credential(for provider: CustomTimestampProviderConfiguration) throws -> Secret? { storedCredential }
}

/// A `SigningEngine` test double: never spawns the real helper process, just
/// captures the `EngineSigningRequest` the provider builds and reports success.
private final class RecordingSigningEngine: SigningEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _capturedRequest: EngineSigningRequest?
    private let signingDrivers: [SigningDriver]
    private let cardCertificates: [SigningCertificate]

    init(drivers: [SigningDriver] = [SigningDriver(id: "eid", displayName: "Fake eID", tokenPresent: true)],
         certificates: [SigningCertificate] = []) {
        signingDrivers = drivers
        cardCertificates = certificates
    }

    var capturedRequest: EngineSigningRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _capturedRequest
    }

    func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(protocolVersion: 1, supportsQualifiedTimestamp: true)
    }

    func drivers() async throws -> [SigningDriver] {
        signingDrivers
    }

    func certificates(driverID: String, pin: Secret?) async throws -> [SigningCertificate] {
        cardCertificates
    }

    func certificateDiscovery(driverID: String, pin: Secret?) async throws -> CertificateDiscovery {
        CertificateDiscovery(token: SigningToken(tokenKey: "fake", providerName: "Fake"), certificates: cardCertificates)
    }

    func inspect(files: [PDFItemDescriptor]) async throws -> [PDFInspection] {
        throw SigningFailure.engine("RecordingSigningEngine does not support inspect.")
    }

    func sign(request: EngineSigningRequest) -> AsyncThrowingStream<SigningEvent, Error> {
        lock.lock()
        _capturedRequest = request
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("recording-engine-\(UUID().uuidString).asice")
            try? Data("signed".utf8).write(to: outputURL)
            continuation.yield(.completed(request.files.first?.id ?? "document", outputURL: outputURL))
            continuation.finish()
        }
    }

    func cancel() async {}
}

final class EngineBridgeSignsExtraFilesAsDataObjectsTests: XCTestCase {
    private func zakoRequest(signsExtraFilesAsDataObjects: Bool) -> SigningRequest {
        let pdf = TestPDFBuilder.singlePageWhitePDF()
        let xdcf = Data("<XMLDataContainer/>".utf8)
        let entries = ASiCEPackager().zakoContainer(pdfData: pdf, pdfFileName: "dokument.pdf",
                                                    dolozkaXML: xdcf, dolozkaFileName: "dokument.xml.xdcf")
        return SigningRequest(pdfData: pdf, identityID: "engine:eid", includeTimestamp: false,
                              extraFiles: entries, filename: "dokument.pdf",
                              signsExtraFilesAsDataObjects: signsExtraFilesAsDataObjects)
    }

    /// ZaKo: the PDF/A and the clause XDC arrive at the engine as two data objects
    /// of one ASiC-E, not wrapped inside a packaged kontajner.asice.
    func testSignsExtraFilesAsDataObjectsSendsPDFAndXDCFAsAttachment() async throws {
        let engine = RecordingSigningEngine()
        let provider = EngineBridgeSigningProvider(engine: engine)

        _ = try await provider.sign(zakoRequest(signsExtraFilesAsDataObjects: true))

        let files = try XCTUnwrap(engine.capturedRequest?.files)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.sourceURL.lastPathComponent, "dokument.pdf")
        XCTAssertEqual(file.attachmentURLs.map(\.lastPathComponent), ["dokument.xml.xdcf"])
    }

    /// The main signing window's flag stays off: `extraFiles` keeps packaging a
    /// kontajner.asice as the source, exactly as it does today.
    func testFlagOffKeepsPackagingAKontajnerAsice() async throws {
        let engine = RecordingSigningEngine()
        let provider = EngineBridgeSigningProvider(engine: engine)

        _ = try await provider.sign(zakoRequest(signsExtraFilesAsDataObjects: false))

        let files = try XCTUnwrap(engine.capturedRequest?.files)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.sourceURL.lastPathComponent, "kontajner.asice")
        XCTAssertTrue(file.attachmentURLs.isEmpty)
    }
}

/// The main signing window: what the engine receives for one document.
final class EngineBridgeMainWindowSourceTests: XCTestCase {
    private func request(_ data: Data, filename: String) -> SigningRequest {
        SigningRequest(pdfData: data, identityID: "engine:eid", includeTimestamp: false,
                       outputFormat: .attachedASIC,
                       extraFiles: [ASiCEPackager.Entry(path: filename, data: data)],
                       filename: filename, signsExtraFilesAsDataObjects: true)
    }

    /// The PDF itself is the source, so the engine's ASiC-E holds it directly.
    func testPDFIsTheSourceUnderItsOwnName() async throws {
        let engine = RecordingSigningEngine()
        let provider = EngineBridgeSigningProvider(engine: engine)

        _ = try await provider.sign(request(TestPDFBuilder.singlePageWhitePDF(), filename: "zmluva.pdf"))

        let file = try XCTUnwrap(engine.capturedRequest?.files.first)
        XCTAssertEqual(file.sourceURL.lastPathComponent, "zmluva.pdf")
        XCTAssertTrue(file.attachmentURLs.isEmpty)
    }

    /// An `.asice` reaches the engine as it is, which then extends the container.
    func testContainerIsTheSourceUnderItsOwnName() async throws {
        let engine = RecordingSigningEngine()
        let provider = EngineBridgeSigningProvider(engine: engine)
        let container = try EngineBridgeSigningProvider.packageContainer(entries: [
            ASiCEPackager.Entry(path: "zmluva.pdf", data: TestPDFBuilder.singlePageWhitePDF())])

        _ = try await provider.sign(request(container, filename: "zmluva.asice"))

        let file = try XCTUnwrap(engine.capturedRequest?.files.first)
        XCTAssertEqual(file.sourceURL.lastPathComponent, "zmluva.asice")
        XCTAssertTrue(file.attachmentURLs.isEmpty)
        XCTAssertTrue(provider.addsSignatureToExistingContainer)
    }
}

final class MandateCertificateTests: XCTestCase {
    func testTheMandateTokenDecides() {
        XCTAssertTrue(MandateCertificate.matches(subject: "Marián Čuprík OPRÁVNENIE 1042",
                                                 issuer: "CN=I.CA EU Qualified CA-SK/RSA 10/2022"))
        XCTAssertTrue(MandateCertificate.matches(subject: "JUDr. X Y, mandátny certifikát"))
        XCTAssertFalse(MandateCertificate.matches(subject: "Marián Čuprík",
                                                  issuer: "CN=I.CA EU Qualified CA-SK/RSA 10/2022"))
        XCTAssertFalse(MandateCertificate.matches(subject: "X OPRÁVNENIE 1", issuer: "CN=I.CA Public CA"))
    }

    /// A qualified QESIG certificate without the token is not an MQC any more.
    func testEngineNoLongerTakesAnyQualifiedCertificateForAMandate() {
        XCTAssertFalse(EngineBridgeSigningProvider.isMandateCertificate(
            issuer: "I.CA EU Qualified CA-SK/RSA 10/2022", displayName: "Marián Čuprík", qualification: "QESIG"))
        XCTAssertTrue(EngineBridgeSigningProvider.isMandateCertificate(
            issuer: "I.CA EU Qualified CA-SK/RSA 10/2022", displayName: "Marián Čuprík OPRÁVNENIE 1042",
            qualification: "QESIG"))
    }

    func testCardState() {
        XCTAssertEqual(MandateCertificate.cardState(subjects: []), .noCard)
        XCTAssertEqual(MandateCertificate.cardState(subjects: [("Marián Čuprík", ""),
                                                               ("Marián Čuprík OPRÁVNENIE 1042", "")]),
                       .mandate(label: "Marián Čuprík OPRÁVNENIE 1042"))
        XCTAssertEqual(MandateCertificate.cardState(subjects: [("Marián Čuprík", "")]),
                       .noMandate(labels: ["Marián Čuprík"]))
    }
}

final class ExistingSignatureGuardTests: XCTestCase {
    func testClassifiesFromTheBytes() throws {
        let pdf = TestPDFBuilder.singlePageWhitePDF()
        var signed = pdf
        signed.append(Data("<</Type/Sig/ByteRange[0 10 20 30]>>".utf8))
        let container = try EngineBridgeSigningProvider.packageContainer(entries: [
            ASiCEPackager.Entry(path: "a.pdf", data: pdf)])

        XCTAssertEqual(ExistingSignatureGuard.classify(fileName: "a.pdf", data: pdf), .unsignedPDF)
        XCTAssertEqual(ExistingSignatureGuard.classify(fileName: "a.pdf", data: signed), .signedPDF)
        XCTAssertEqual(ExistingSignatureGuard.classify(fileName: "a.asice", data: container), .asicContainer)
        XCTAssertEqual(ExistingSignatureGuard.classify(fileName: "A.ASICE", data: container), .asicContainer)
        // A zip under a PDF name is not treated as a container.
        XCTAssertNotEqual(ExistingSignatureGuard.classify(fileName: "a.pdf", data: container), .asicContainer)
    }
}

final class EngineBridgeRecordSubmissionTests: XCTestCase {
    private func recordRequest(filename: String?, timestampServers: [String]? = nil) -> SigningRequest {
        SigningRequest(pdfData: Data("<XMLDataContainer/>".utf8), identityID: "engine:eid",
                      includeTimestamp: false, filename: filename,
                      timestampServers: timestampServers, signsAsRecordContainer: true)
    }

    /// EZZK's GetConversionRecord expects the signed record's data object under its
    /// own "<number>.record.xml.xdcf" name, not a generic name the ordinary signing
    /// path would pick for a bare XML payload.
    func testRecordContainerIsSentUnderItsXdcfName() async throws {
        let engine = RecordingSigningEngine()
        let provider = EngineBridgeSigningProvider(engine: engine)

        _ = try await provider.sign(recordRequest(filename: "260923-X.record.xml.xdcf"))

        let request = try XCTUnwrap(engine.capturedRequest)
        XCTAssertEqual(request.files.first?.sourceURL.lastPathComponent, "260923-X.record.xml.xdcf")
        XCTAssertEqual(request.files.first?.attachmentURLs, [])
        XCTAssertEqual(request.outputFormat, .asiceXAdES)
    }

    /// The extension is how the engine (and EZZK) recognise a record's XML Data
    /// Container; anything else must be refused rather than silently signed wrong.
    func testRecordNeedsAnXdcfName() async throws {
        let engine = RecordingSigningEngine()
        let provider = EngineBridgeSigningProvider(engine: engine)

        do {
            _ = try await provider.sign(recordRequest(filename: "x.pdf"))
            XCTFail("Expected signing to fail for a non-.xdcf record filename.")
        } catch SigningError.signingFailed(let message) {
            XCTAssertEqual(message, "Záznam musí mať príponu .xdcf.")
        }
    }

    /// A record's own timestamp servers (EZZK's TSA requirement) must reach the
    /// engine request even though the app's own timestamp preferences say something
    /// else, or say nothing at all.
    func testExplicitTimestampServersReachTheEngineRequest() async throws {
        let engine = RecordingSigningEngine()
        let provider = EngineBridgeSigningProvider(engine: engine)

        _ = try await provider.sign(recordRequest(filename: "260923-X.record.xml.xdcf",
                                                  timestampServers: ["https://tsa.belgium.be/connect"]))

        let request = try XCTUnwrap(engine.capturedRequest)
        XCTAssertEqual(request.timestampServersOverride, ["https://tsa.belgium.be/connect"])
    }
}

/// The timestamp authority picked in Settings, in the main window, the batch or the
/// browser panel arrives as `tsaURL`; the engine has to receive it.
final class EngineBridgeTimestampRoutingTests: XCTestCase {
    private func request(tsaURL: String?, timestampServers: [String]? = nil,
                         level: String? = nil) -> SigningRequest {
        SigningRequest(pdfData: TestPDFBuilder.singlePageWhitePDF(), identityID: "engine:eid",
                       includeTimestamp: tsaURL != nil, tsaURL: tsaURL, outputFormat: .attachedASIC,
                       signatureLevelOverride: level, filename: "zmluva.pdf",
                       signsExtraFilesAsDataObjects: true, timestampServers: timestampServers)
    }

    func testTheChosenAuthorityReachesTheEngine() async throws {
        let engine = RecordingSigningEngine()
        _ = try await EngineBridgeSigningProvider(engine: engine).sign(request(tsaURL: "http://tsa.disig.sk/qts"))

        XCTAssertEqual(engine.capturedRequest?.timestampServersOverride, ["http://tsa.disig.sk/qts"])
    }

    /// ZaKo outside Demo passes the built-in qualified list, which wins over its `tsaURL`.
    func testExplicitTimestampServersWinOverTheChosenAuthority() async throws {
        let engine = RecordingSigningEngine()
        _ = try await EngineBridgeSigningProvider(engine: engine).sign(request(
            tsaURL: "http://tsa.belgium.be/connect",
            timestampServers: ["http://tsa.belgium.be/connect", "http://time.certum.pl"]))

        XCTAssertEqual(engine.capturedRequest?.timestampServersOverride,
                       ["http://tsa.belgium.be/connect", "http://time.certum.pl"])
    }

    /// The switch reaches the engine for the app's own signature, with the chosen authority
    /// even when the signature timestamp is off.
    func testTheContentTimestampReachesTheEngineWithTheChosenAuthority() async throws {
        let engine = RecordingSigningEngine()
        var signing = request(tsaURL: nil)
        signing.tsaURL = "http://tsa.belgium.be/connect"
        signing.includeContentTimestamp = true
        _ = try await EngineBridgeSigningProvider(engine: engine).sign(signing)

        let captured = try XCTUnwrap(engine.capturedRequest)
        XCTAssertTrue(captured.contentTimestamp)
        XCTAssertEqual(captured.signatureLevelOverride, "XAdES_BASELINE_B")
        // BOSA chosen, but an XAdES content timestamp comes from Sectigo (slovensko.sk sees no BOSA in XAdES).
        XCTAssertEqual(captured.timestampServersOverride, [TimestampAuthority.sectigoQualifiedURL])
    }

    /// slovensko.sk does not see a BOSA (ECDSA) timestamp in XAdES: whoever sends BOSA for an
    /// ASiC-E (the panel, an older caller), the engine gets Sectigo; a PAdES keeps BOSA.
    func testAnXAdESNeverReachesTheEngineWithBOSA() async throws {
        let engine = RecordingSigningEngine()
        _ = try await EngineBridgeSigningProvider(engine: engine).sign(request(tsaURL: TimestampAuthority.bosaURL))
        XCTAssertEqual(engine.capturedRequest?.timestampServersOverride, [TimestampAuthority.sectigoQualifiedURL])

        var pades = request(tsaURL: TimestampAuthority.bosaURL)
        pades.outputFormat = .embeddedPAdES
        XCTAssertEqual(EngineBridgeSigningProvider.timestampServers(for: pades, signsXAdES: false),
                       [TimestampAuthority.bosaURL])
    }

    /// A portal decides its own format, so a content timestamp never reaches a portal request.
    func testAPortalRequestNeverCarriesAContentTimestamp() async throws {
        let engine = RecordingSigningEngine()
        var signing = request(tsaURL: nil, level: "XAdES_BASELINE_B")
        signing.includeContentTimestamp = true
        _ = try await EngineBridgeSigningProvider(engine: engine).sign(signing)

        XCTAssertEqual(engine.capturedRequest?.contentTimestamp, false)
    }

    func testABlankAuthorityIsNoOverride() async throws {
        let engine = RecordingSigningEngine()
        _ = try await EngineBridgeSigningProvider(engine: engine).sign(request(tsaURL: "  "))

        XCTAssertNil(engine.capturedRequest?.timestampServersOverride)
    }

    /// A portal's Baseline B (slovensko.sk, switch off) still goes out without a timestamp.
    func testAPortalBaselineBStillCarriesNoTimestamp() async throws {
        let engine = RecordingSigningEngine()
        _ = try await EngineBridgeSigningProvider(engine: engine).sign(request(tsaURL: nil, level: "XAdES_BASELINE_B"))

        let captured = try XCTUnwrap(engine.capturedRequest)
        XCTAssertNil(captured.timestampServersOverride)
        XCTAssertEqual(AutogramCLIEngine.levelAndTimestamp(for: captured, endpoints: []).timestamp,
                       .object(["required": .bool(false), "servers": .array([])]))
    }
}

private struct ResolveDispatchProbeProvider: QualifiedSigningProviding {
    func availableIdentities() async -> [SigningIdentityInfo] { [] }

    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? {
        [SigningIdentityInfo(id: "concrete", label: pin, issuerSummary: "test")]
    }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.identityUnavailable
    }

    func inspectSignatures(in fileURL: URL) async -> [DocumentSignatureInfo] { [] }
}

final class SigningProviderDispatchTests: XCTestCase {
    func testResolveIdentitiesDispatchesThroughProtocolExistential() async {
        let provider: any QualifiedSigningProviding = ResolveDispatchProbeProvider()

        let identity = await provider.resolveIdentities(pin: "dispatch-test")?.first

        XCTAssertEqual(identity?.id, "concrete")
        XCTAssertEqual(identity?.label, "dispatch-test")
    }
}

final class EngineInspectionContractTests: XCTestCase {
    func testIncompleteEngineInspectionCannotBeAcceptedAsCompleted() {
        let inspection = PDFInspection(files: [
            InspectedPDF(id: "inspect", isSignable: false)
        ])

        XCTAssertThrowsError(
            try EngineBridgeSigningProvider.requireInspectableFile(
                in: [inspection]))
    }
    func testBulkInputInspectionDeduplicatesDuplicateURLs() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-input-\(UUID().uuidString).pdf")

        let results = await EngineBridgeSigningProvider()
            .inspectInputSignatures(in: [url, url])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[EnginePaths.canonical(url)]?.state, .unavailable)
    }

}

final class JavaEngineLiveProcessTests: XCTestCase {
    private var liveTestEnabled: Bool {
        ProcessInfo.processInfo.environment["CHEVRON7_ENGINE_LIVE_TEST"] == "1"
    }

    func testCapabilitiesRoundtripAgainstRealEngineHelper() async throws {
        guard liveTestEnabled else {
            throw XCTSkip("Live test vyžaduje CHEVRON7_ENGINE_LIVE_TEST=1.")
        }
        guard JavaEngineLocator().locate() != nil else {
            throw XCTSkip("Java engine nie je nainštalovaný.")
        }
        let engine = AutogramCLIEngine()
        let capabilities = try await engine.capabilities()
        XCTAssertTrue(capabilities.supportsQualifiedTimestamp)
        let drivers = try await engine.drivers()
        _ = drivers
        await engine.cancel()
    }

}

final class EngineBridgeLiveSignTests: XCTestCase {
    private var liveTestEnabled: Bool {
        ProcessInfo.processInfo.environment["CHEVRON7_ENGINE_LIVE_TEST"] == "1"
    }

    func testV1SignRequestPassesProtocolValidation() async throws {
        guard liveTestEnabled else { throw XCTSkip("Vyžaduje CHEVRON7_ENGINE_LIVE_TEST=1.") }
        guard JavaEngineLocator().locate() != nil else { throw XCTSkip("Engine nie je nainštalovaný.") }

        // The timestamp source is read on signing; the default store reads UserDefaults.standard.
        let engine = AutogramCLIEngine(
            timestampSourceProvider: TimestampSourcePreferencesStore(defaults: MemoryUserDefaults()))
        let work = try EngineBridgeSigningProvider.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("document.pdf")
        try TestPDFBuilder.singlePageWhitePDF().write(to: source)

        let file = SigningFile(id: "document",
                               sourceURL: source.standardizedFileURL.resolvingSymlinksInPath())
        let request = EngineSigningRequest(sessionID: UUID(),
                                           driverID: "eid",
                                           certificateSerial: "123",
                                           pin: Secret("0000"),
                                           files: [file],
                                           outputFormat: .asiceXAdES)
        var events: [String] = []
        do {
            for try await event in engine.sign(request: request) {
                switch event {
                case .started: events.append("started")
                case .activity(let phase): events.append("activity:\(phase)")
                case .fileSigning(let id): events.append("signing:\(id)")
                case .completed(let id, let url, _): events.append("completed:\(id):\(url.lastPathComponent)")
                case .failed(let id, let failure): events.append("failed:\(id):\(failure)")
                case .cancelled: events.append("cancelled")
                }
            }
        } catch let failure as SigningFailure {
            events.append("throw:\(failure)")
        }
        print("V1 EVENTS: \(events)")
        let joined = events.joined(separator: "|")
        XCTAssertFalse(joined.contains("PROTOCOL_INVALID_REQUEST"), "V1 request musí prejsť validáciou: \(joined)")
        await engine.cancel()
    }

    func testV2VisibleSignRequestPassesProtocolValidation() async throws {
        guard liveTestEnabled else { throw XCTSkip("Vyžaduje CHEVRON7_ENGINE_LIVE_TEST=1.") }
        guard JavaEngineLocator().locate() != nil else { throw XCTSkip("Engine nie je nainštalovaný.") }

        // The timestamp source is read on signing; the default store reads UserDefaults.standard.
        let engine = AutogramCLIEngine(
            timestampSourceProvider: TimestampSourcePreferencesStore(defaults: MemoryUserDefaults()))
        let work = try EngineBridgeSigningProvider.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("document.pdf")
        try TestPDFBuilder.singlePageWhitePDF().write(to: source)

        let store = SignatureAssetStore(applicationSupportRoot: work)
        try FileManager.default.createDirectory(at: store.assetsDirectory, withIntermediateDirectories: true)
        let asset = SignatureAsset(id: UUID(), kind: .png, managedFilename: "art.png")
        try EngineBridgeSigningProvider.textArtworkPNG(fullName: "Test", timestamp: Date())
            .write(to: store.fileURL(for: asset))
        let rendered = try VisibleSignatureRenderer(assetStore: store, cacheRoot: work).render(
            asset: asset,
            content: VisibleSignatureCardContent(signerName: "Test", certificateQualification: nil),
            signingTime: Date(),
            rotationDegrees: 0)

        let placement = VisibleSignaturePlacement(pageIndex: 0,
                                                  pageRect: CGRect(x: 100, y: 600, width: 200, height: 120),
                                                  rotationDegrees: 0)
        guard let page = PDFDocument(url: source)?.page(at: 0) else { return XCTFail("PDF") }
        let field = PDFCoordinateConverter().dssField(placement,
                                                      cropBox: page.bounds(for: .cropBox),
                                                      pageRotation: Int(page.rotation))
        let appearance = VisibleSignatureRequest(renderedPNGURL: rendered,
                                                 page: field.page,
                                                 originX: Double(field.originX),
                                                 originY: Double(field.originY),
                                                 width: Double(field.width),
                                                 height: Double(field.height),
                                                 signingTime: Date())

        let file = SigningFile(id: "document",
                               sourceURL: source.standardizedFileURL.resolvingSymlinksInPath(),
                               visibleAppearance: appearance)
        let request = EngineSigningRequest(sessionID: UUID(),
                                           driverID: "eid",
                                           certificateSerial: "123",
                                           pin: Secret("0000"),
                                           files: [file],
                                           outputFormat: .pades)
        var events: [String] = []
        do {
            for try await event in engine.sign(request: request) {
                switch event {
                case .started: events.append("started")
                case .activity(let phase): events.append("activity:\(phase)")
                case .fileSigning(let id): events.append("signing:\(id)")
                case .completed(let id, _, _): events.append("completed:\(id)")
                case .failed(let id, let failure): events.append("failed:\(id):\(failure)")
                case .cancelled: events.append("cancelled")
                }
            }
        } catch {
            events.append("throw:\(error)")
        }
        print("V2 EVENTS: \(events)")
        let joined = events.joined(separator: "|")
        XCTAssertFalse(joined.contains("PROTOCOL_INVALID_REQUEST"), "V2 request musí prejsť validáciou: \(joined)")
        XCTAssertFalse(joined.contains("MachineSessionProcessFailure"), "V2 session nesmie zlyhať na protokole: \(joined)")
        await engine.cancel()
    }
}

/// A portal reads `issuedBy` from the signed result: the issuer of the certificate the
/// engine actually signed with, never the prompt a synthetic card identity carries.
final class EngineBridgeSignerIssuerTests: XCTestCase {
    private let mandate = SigningCertificate(serialNumber: "1042",
                                             displayName: "Marián Čuprík OPRÁVNENIE 1042",
                                             issuer: "I.CA EU Qualified CA-SK/RSA 10/2022",
                                             validFrom: .distantPast,
                                             validUntil: .distantFuture,
                                             certificateKey: "v1:key-1042",
                                             holderKey: "holder-1042",
                                             certificateQualification: "QESIG")

    /// A card selected from the reader poll (synthetic identity) reads its certificates
    /// while signing, so the result names the signing certificate's issuer.
    func testCardReadWhileSigningCarriesTheCertificateIssuer() async throws {
        let engine = RecordingSigningEngine(
            drivers: [SigningDriver(id: "ica", displayName: "I.CA", tokenPresent: true)],
            certificates: [mandate])
        let provider = EngineBridgeSigningProvider(engine: engine)

        let signed = try await provider.sign(SigningRequest(
            pdfData: TestPDFBuilder.singlePageWhitePDF(), identityID: "engine:ica",
            includeTimestamp: false, pin: "1234", filename: "zmluva.pdf"))

        XCTAssertEqual(engine.capturedRequest?.certificateSerial, "1042")
        XCTAssertEqual(signed.signatureLabel, "Marián Čuprík OPRÁVNENIE 1042")
        XCTAssertEqual(signed.signerIssuer, "I.CA EU Qualified CA-SK/RSA 10/2022")
    }

    /// An eID signs with the token's only key without reading its certificate, so the
    /// result knows no issuer and says so instead of inventing one.
    func testEIDSigningWithoutDiscoveryLeavesTheIssuerUnknown() async throws {
        let engine = RecordingSigningEngine()
        let provider = EngineBridgeSigningProvider(engine: engine)

        let signed = try await provider.sign(SigningRequest(
            pdfData: TestPDFBuilder.singlePageWhitePDF(), identityID: "engine:eid",
            includeTimestamp: false, filename: "zmluva.pdf"))

        XCTAssertEqual(engine.capturedRequest?.certificateSerial, EngineBridgeSigningProvider.signingKeyOnToken)
        XCTAssertNil(signed.signerIssuer)
    }
}
