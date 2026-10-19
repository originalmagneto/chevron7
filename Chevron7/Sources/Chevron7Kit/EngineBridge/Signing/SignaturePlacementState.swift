// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Identity
import PDFKit
import Foundation
import Observation

/// Stav grafického podpisu – port logiky WorkspaceModel z Autogram macOS 2.
@MainActor
@Observable
public final class SignaturePlacementState {
    @ObservationIgnored public private(set) var assets: [SignatureAsset] = []
    public private(set) var selectedAsset: SignatureAsset?
    public private(set) var layout: VisibleSignatureLayout = .detailed
    public var isEnabled = false
    public var placement: VisibleSignaturePlacement?
    public private(set) var pageCount = 0
    public private(set) var cardContent: VisibleSignatureCardContent?
    public private(set) var cardPreview: NSImage?
    public private(set) weak var document: PDFDocument?

    public let assetStore: SignatureAssetStore
    private let defaults: UserDefaults
    private let cacheRoot: URL?

    public init(assetStore: SignatureAssetStore = SignatureAssetStore(),
                document: PDFDocument? = nil,
                defaults: UserDefaults = .standard,
                cacheRoot: URL? = nil) {
        self.assetStore = assetStore
        self.defaults = defaults
        self.cacheRoot = cacheRoot
        self.document = document
        refreshAssets()
        restorePreferences()
        updateDocument(document)
    }

    // MARK: - Document

    public func updateDocument(_ document: PDFDocument?) {
        self.document = document
        pageCount = document?.pageCount ?? 0
        guard var current = placement, pageCount > 0 else { return }
        let clamped = min(max(current.pageIndex, 0), pageCount - 1)
        guard current.pageIndex != clamped else { return }
        current.pageIndex = clamped
        placement = current
    }

    public var pageIndices: [Int] { Array(0..<max(pageCount, 0)) }

    public func artworkURL(for asset: SignatureAsset) -> URL {
        assetStore.fileURL(for: asset)
    }

    // MARK: - Selection & editing

    public func importArtwork(from sourceURL: URL, pdfPageIndex: Int = 0) throws {
        let asset: SignatureAsset
        if sourceURL.pathExtension.lowercased() == "pdf" {
            asset = try assetStore.importPDF(sourceURL, pageIndex: pdfPageIndex)
        } else {
            asset = try assetStore.importPNG(sourceURL)
        }
        refreshAssets()
        select(asset)
    }

    public func select(_ asset: SignatureAsset) {
        guard assets.contains(where: { $0.id == asset.id }) else { return }
        selectedAsset = asset
        isEnabled = true
        refreshPreview()
        placement = defaultPlacement()
        persistPreferences()
    }

    public func delete(_ asset: SignatureAsset) throws {
        try assetStore.delete(asset)
        refreshAssets()
        guard selectedAsset?.id == asset.id else { return }
        clearComposition()
        persistPreferences()
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled, placement == nil {
            placement = defaultPlacement()
        }
        persistPreferences()
    }

    public func update(placement newValue: VisibleSignaturePlacement?) {
        placement = newValue
        persistPreferences()
    }

    public func selectPage(_ pageIndex: Int) {
        guard var current = placement, pageCount > 0 else { return }
        current.pageIndex = min(max(pageIndex, 0), pageCount - 1)
        update(placement: current)
    }

    public func resetRotation() {
        guard var current = placement else { return }
        current.rotationDegrees = 0
        update(placement: current)
    }

    /// Sets the signer, certificate, and timestamp content shown in the card.
    public func setContent(
        signerName: String,
        certificateName: String? = nil,
        qualification: String? = nil,
        timestampAuthorityName: String? = nil
    ) {
        cardContent = VisibleSignatureCardContent(
            signerName: signerName,
            certificateName: certificateName,
            certificateQualification: qualification,
            timestampAuthorityName: timestampAuthorityName)
        refreshPreview()
    }

    public func setLayout(_ layout: VisibleSignatureLayout) {
        guard self.layout != layout else { return }
        self.layout = layout
        refreshPreview()
        if placement != nil {
            placement = refittedPlacement() ?? placement
        }
        persistPreferences()
    }

    /// Keep the baseline the person placed. Only the height follows the new card.
    private func refittedPlacement() -> VisibleSignaturePlacement? {
        guard var current = placement,
              let page = document?.page(at: min(max(current.pageIndex, 0), max(pageCount - 1, 0))) else {
            return nil
        }
        let cropBox = page.bounds(for: .cropBox)
        guard cropBox.width > 0, cropBox.height > 0 else { return nil }
        let size = cardPreview?.size ?? VisibleSignatureRenderer.cardSize(for: layout)
        let aspect = size.width / max(size.height, 1)
        var width = min(current.pageRect.width, cropBox.width)
        var height = width / aspect
        if height > cropBox.height {
            height = cropBox.height
            width = height * aspect
        }
        var x = current.pageRect.midX - width / 2
        var y = current.pageRect.minY
        x = min(max(x, cropBox.minX), cropBox.maxX - width)
        y = min(max(y, cropBox.minY), cropBox.maxY - height)
        current.pageRect = CGRect(x: x, y: y, width: width, height: height)
        return current
    }


    public func clearComposition() {
        isEnabled = false
        placement = nil
        cardContent = nil
        cardPreview = nil
    }

    // MARK: - Rendering

    public func defaultPlacement() -> VisibleSignaturePlacement? {
        guard pageCount > 0, let page = document?.page(at: pageCount - 1) else { return nil }
        let cropBox = page.bounds(for: .cropBox)
        guard cropBox.width > 0, cropBox.height > 0 else { return nil }
        let aspectRatio = (cardPreview?.size ?? selectedAsset.flatMap {
            NSImage(contentsOf: assetStore.fileURL(for: $0))?.size
        }).map { max($0.width / max($0.height, 1), 1) } ?? (VisibleSignatureRenderer.cardSize(for: layout).width / VisibleSignatureRenderer.cardSize(for: layout).height)
        let maxWidth = min(cropBox.width, 420)
        let maxHeight = min(cropBox.height, 180)
        let width = min(maxWidth, maxHeight * aspectRatio)
        let height = width / aspectRatio
        return VisibleSignaturePlacement(
            pageIndex: pageCount - 1,
            pageRect: CGRect(x: (cropBox.width - width) / 2,
                             y: (cropBox.height - height) / 2,
                             width: width,
                             height: height),
            rotationDegrees: 0)
    }

    @discardableResult
    public func refreshPreview() -> Bool {
        guard let asset = selectedAsset else {
            cardContent = nil
            cardPreview = nil
            return false
        }
        if cardContent == nil {
            cardContent = VisibleSignatureCardContent(
                signerName: "Certificate details pending")
        }
        guard let content = cardContent,
              let previewURL = try? VisibleSignatureRenderer(assetStore: assetStore,
                                                            cacheRoot: cacheRoot).render(
                asset: asset, content: content, signingTime: .now, rotationDegrees: 0,
                isPreview: true, layout: layout) else {
            cardPreview = nil
            return false
        }
        defer { try? FileManager.default.removeItem(at: previewURL) }
        cardPreview = NSImage(contentsOf: previewURL)
        return cardPreview != nil
    }

    // MARK: - Persistence

    public func refreshAssets() {
        assets = (try? assetStore.listAssets()) ?? []
    }

    func restorePreferences() {
        guard let data = defaults.data(forKey: Self.preferencesKey),
              let preferences = try? JSONDecoder().decode(StoredPreferences.self, from: data) else { return }
        layout = preferences.layout
        selectedAsset = preferences.assetID.flatMap { id in assets.first { $0.id == id } }
        isEnabled = false
        refreshPreview()
    }

    func persistPreferences() {
        let preferences = StoredPreferences(assetID: selectedAsset?.id, layout: layout)
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
    }

    struct StoredPreferences: Codable {
        var assetID: UUID?
        var layout: VisibleSignatureLayout

        init(assetID: UUID?, layout: VisibleSignatureLayout) {
            self.assetID = assetID
            self.layout = layout
        }

        private enum CodingKeys: String, CodingKey {
            case assetID
            case layout
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            assetID = try container.decodeIfPresent(UUID.self, forKey: .assetID)
            layout = try container.decodeIfPresent(VisibleSignatureLayout.self, forKey: .layout) ?? .detailed
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(assetID, forKey: .assetID)
            try container.encode(layout, forKey: .layout)
        }
    }

    static let preferencesKey = "\(ProductIdentity.bundleIdentifier).visibleSignature"
}
