// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Foundation
import Security

public enum KeychainStore {
    static let service = ProductIdentity.bundleIdentifier

    public static func save(secret: String, account: String) -> Bool {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public struct AppSettings: Codable, Sendable {
    public enum AIMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case builtInOnDevice = "Interný (on-device Vision)"
        case omlxLocal = "Lokálny model (oMLX - Apple Silicon)"
        case ollamaLocal = "Lokálny model (Ollama)"
        case customAPIKey = "Vlastný API kľúč (OpenAI-compatible)"
        case disabled = "Vypnuté"

        public var id: String { rawValue }

        /// The prompt is sent only to an explicitly selected external LLM.
        public var supportsPromptOverride: Bool {
            switch self {
            case .omlxLocal, .ollamaLocal, .customAPIKey:
                return true
            case .builtInOnDevice, .disabled:
                return false
            }
        }
    }

    public enum EZZKMode: String, Codable, CaseIterable, Sendable {
        case demo
        case test
        case production

        public var environment: EZZKEnvironment? {
            switch self {
            case .demo: nil
            case .test: .sandbox
            case .production: .production
            }
        }

        public var label: String {
            switch self {
            case .demo: "Demo (lokálne)"
            case .test: "Test"
            case .production: "Produkcia"
            }
        }
    }

    /// How a batch signed as ASiC-E is packaged.
    public enum BatchASiCPackaging: String, Codable, CaseIterable, Sendable {
        /// Every PDF in its own `<name>_podpisane.asice`.
        case perDocument
        /// Every PDF as a data object of one shared container.
        case combined
    }

    public var aiMode: AIMode
    public var aiPrompt: String?
    public var omlxURL: String
    public var omlxModel: String
    public var ollamaURL: String
    public var ollamaModel: String
    public var openAICompatibleBaseURL: String
    public var openAICompatibleModel: String
    public var customTSAServers: [String]
    public var selectedTSAURL: String
    public var pdfaMode: PDFAConversionMode
    public var profiles: [AdvocateProfile]
    public var activeProfileID: UUID?
    public var ezzkICO: String
    public var ezzkUsername: String
    public var ezzkNotificationEmail: String
    public var ezzkEdeskAddress: String
    public var ezzkMode: EZZKMode
    /// Name of the person performing conversions exactly as EZZK registered it.
    public var ezzkPersonName: String
    public var retainRecentDocuments: Bool
    /// Use the on-device Foundation Model to classify uncertain candidates.
    public var useFoundationModelClassifier: Bool
    /// Record confirmed and rejected elements into the local example bank.
    public var learnFromReviews: Bool
    /// Offer detector training once enough pages are reviewed. The workflow
    /// stays reachable from Settings when offers are off.
    public var detectorTrainingOffersEnabled: Bool
    /// Show "Podpísať mobilom" and allow signing through Autogram v mobile.
    public var mobileSigningEnabled: Bool
    /// AVM server base URL. Only the public host works with the App Store app; kept configurable for testing.
    public var avmBaseURL: String
    /// Autogram Portal base URL for eIdentita signing. Production by default; staging for testing.
    public var agpBaseURL: String
    /// Portal user id: the `sub` claim of the self-signed API JWT. Not secret.
    public var agpUserID: String
    /// Keep a copy of documents signed from the browser. A browser signature has
    /// no original file to sit next to, the way an in-app signature does, so
    /// without this there is no local trace of what was signed.
    public var webSigningSavesLocally: Bool
    /// Folder for those copies. Empty means the app's own output folder.
    public var webSigningOutputPath: String
    /// Days after which those copies move to the Trash. Zero keeps them.
    public var webSigningRetentionDays: Int
    /// The last packaging chosen for an ASiC-E batch.
    public var batchASiCPackaging: BatchASiCPackaging

    public var avmBaseURLValue: URL {
        let trimmed = avmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            return AVMClient.publicBaseURL
        }
        return url
    }

    public var agpBaseURLValue: URL {
        let trimmed = agpBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              url.host != nil else {
            return AGPClient.productionBaseURL
        }
        return url
    }
    private enum CodingKeys: String, CodingKey {
        case aiMode, aiPrompt
        case omlxURL, omlxModel
        case ollamaURL, ollamaModel
        case openAICompatibleBaseURL, openAICompatibleModel
        case customTSAServers, selectedTSAURL, legacyTSAURL = "tsaURL"
        case pdfaMode, profiles, activeProfileID
        case ezzkICO, ezzkUsername, ezzkNotificationEmail, ezzkEdeskAddress, ezzkMode, ezzkPersonName
        case retainRecentDocuments
        case useFoundationModelClassifier, learnFromReviews, detectorTrainingOffersEnabled
        case mobileSigningEnabled, avmBaseURL
        case agpBaseURL, agpUserID
        case webSigningSavesLocally, webSigningOutputPath, webSigningRetentionDays
        case batchASiCPackaging
    }

    public init(aiMode: AIMode = .builtInOnDevice,
                aiPrompt: String? = nil,
                omlxURL: String = "http://localhost:8000/v1",
                omlxModel: String = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
                ollamaURL: String = "http://localhost:11434",
                ollamaModel: String = "llava",
                openAICompatibleBaseURL: String = "https://api.openai.com/v1",
                openAICompatibleModel: String = "gpt-4o-mini",
                customTSAServers: [String] = [],
                selectedTSAURL: String = TimestampAuthority.legacyDefaultURL,
                pdfaMode: PDFAConversionMode = .vectorPreserving,
                profiles: [AdvocateProfile] = [],
                activeProfileID: UUID? = nil,
                ezzkICO: String = "",
                ezzkUsername: String = "",
                ezzkNotificationEmail: String = "",
                ezzkEdeskAddress: String = "",
                ezzkMode: EZZKMode = .demo,
                ezzkPersonName: String = "",
                retainRecentDocuments: Bool = false,
                useFoundationModelClassifier: Bool = true,
                learnFromReviews: Bool = true,
                detectorTrainingOffersEnabled: Bool = true,
                mobileSigningEnabled: Bool = true,
                avmBaseURL: String = AVMClient.publicBaseURL.absoluteString,
                agpBaseURL: String = AGPClient.productionBaseURL.absoluteString,
                agpUserID: String = "",
                webSigningSavesLocally: Bool = true,
                webSigningOutputPath: String = "",
                webSigningRetentionDays: Int = 0,
                batchASiCPackaging: BatchASiCPackaging = .perDocument) {
        self.aiMode = aiMode
        self.aiPrompt = aiPrompt
        self.omlxURL = omlxURL
        self.omlxModel = omlxModel
        self.ollamaURL = ollamaURL
        self.ollamaModel = ollamaModel
        self.openAICompatibleBaseURL = openAICompatibleBaseURL
        self.openAICompatibleModel = openAICompatibleModel
        self.customTSAServers = customTSAServers
        self.selectedTSAURL = selectedTSAURL
        self.pdfaMode = pdfaMode
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.ezzkICO = ezzkICO
        self.ezzkUsername = ezzkUsername
        self.ezzkNotificationEmail = ezzkNotificationEmail
        self.ezzkEdeskAddress = ezzkEdeskAddress
        self.ezzkMode = ezzkMode
        self.ezzkPersonName = ezzkPersonName
        self.retainRecentDocuments = retainRecentDocuments
        self.useFoundationModelClassifier = useFoundationModelClassifier
        self.learnFromReviews = learnFromReviews
        self.detectorTrainingOffersEnabled = detectorTrainingOffersEnabled
        self.mobileSigningEnabled = mobileSigningEnabled
        self.avmBaseURL = avmBaseURL
        self.agpBaseURL = agpBaseURL
        self.agpUserID = agpUserID
        self.webSigningSavesLocally = webSigningSavesLocally
        self.webSigningOutputPath = webSigningOutputPath
        self.webSigningRetentionDays = webSigningRetentionDays
        self.batchASiCPackaging = batchASiCPackaging
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.aiMode = try container.decodeIfPresent(AIMode.self, forKey: .aiMode) ?? .builtInOnDevice
        self.aiPrompt = try container.decodeIfPresent(String.self, forKey: .aiPrompt)
        self.omlxURL = try container.decodeIfPresent(String.self, forKey: .omlxURL) ?? "http://localhost:8000/v1"
        self.omlxModel = try container.decodeIfPresent(String.self, forKey: .omlxModel)
            ?? "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"
        self.ollamaURL = try container.decodeIfPresent(String.self, forKey: .ollamaURL) ?? "http://localhost:11434"
        self.ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? "llava"
        self.openAICompatibleBaseURL = try container.decodeIfPresent(String.self, forKey: .openAICompatibleBaseURL)
            ?? "https://api.openai.com/v1"
        self.openAICompatibleModel = try container.decodeIfPresent(String.self, forKey: .openAICompatibleModel) ?? "gpt-4o-mini"

        let legacy = try container.decodeIfPresent(String.self, forKey: .legacyTSAURL)
        var customs = try container.decodeIfPresent([String].self, forKey: .customTSAServers) ?? []
        if let legacy, !legacy.isEmpty,
           !TimestampAuthority.builtIn.contains(where: { $0.url.caseInsensitiveCompare(legacy) == .orderedSame }),
           !customs.contains(where: { $0.caseInsensitiveCompare(legacy) == .orderedSame }) {
            customs.append(legacy)
        }
        self.customTSAServers = customs

        let storedSelection = try container.decodeIfPresent(String.self, forKey: .selectedTSAURL)
        if let storedSelection, !storedSelection.isEmpty {
            self.selectedTSAURL = storedSelection
        } else if let legacy, !legacy.isEmpty {
            self.selectedTSAURL = legacy
        } else {
            self.selectedTSAURL = TimestampAuthority.legacyDefaultURL
        }

        self.pdfaMode = try container.decodeIfPresent(PDFAConversionMode.self, forKey: .pdfaMode) ?? .vectorPreserving
        self.profiles = try container.decodeIfPresent([AdvocateProfile].self, forKey: .profiles) ?? []
        self.activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        self.ezzkICO = try container.decodeIfPresent(String.self, forKey: .ezzkICO) ?? ""
        self.ezzkUsername = try container.decodeIfPresent(String.self, forKey: .ezzkUsername) ?? ""
        self.ezzkNotificationEmail = try container.decodeIfPresent(String.self, forKey: .ezzkNotificationEmail) ?? ""
        self.ezzkEdeskAddress = try container.decodeIfPresent(String.self, forKey: .ezzkEdeskAddress) ?? ""
        self.ezzkMode = try container.decodeIfPresent(EZZKMode.self, forKey: .ezzkMode) ?? .demo
        self.ezzkPersonName = try container.decodeIfPresent(String.self, forKey: .ezzkPersonName) ?? ""
        self.retainRecentDocuments = try container.decodeIfPresent(Bool.self, forKey: .retainRecentDocuments) ?? false
        self.useFoundationModelClassifier = try container.decodeIfPresent(Bool.self, forKey: .useFoundationModelClassifier) ?? true
        self.learnFromReviews = try container.decodeIfPresent(Bool.self, forKey: .learnFromReviews) ?? true
        self.detectorTrainingOffersEnabled = try container.decodeIfPresent(Bool.self, forKey: .detectorTrainingOffersEnabled) ?? true
        self.mobileSigningEnabled = try container.decodeIfPresent(Bool.self, forKey: .mobileSigningEnabled) ?? true
        self.avmBaseURL = try container.decodeIfPresent(String.self, forKey: .avmBaseURL) ?? AVMClient.publicBaseURL.absoluteString
        self.agpBaseURL = try container.decodeIfPresent(String.self, forKey: .agpBaseURL) ?? AGPClient.productionBaseURL.absoluteString
        self.agpUserID = try container.decodeIfPresent(String.self, forKey: .agpUserID) ?? ""
        self.webSigningSavesLocally = try container.decodeIfPresent(Bool.self, forKey: .webSigningSavesLocally) ?? true
        self.webSigningOutputPath = try container.decodeIfPresent(String.self, forKey: .webSigningOutputPath) ?? ""
        self.webSigningRetentionDays = try container.decodeIfPresent(Int.self, forKey: .webSigningRetentionDays) ?? 0
        self.batchASiCPackaging = (try? container.decodeIfPresent(
            BatchASiCPackaging.self, forKey: .batchASiCPackaging)) ?? .perDocument
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aiMode, forKey: .aiMode)
        try container.encodeIfPresent(aiPrompt, forKey: .aiPrompt)
        try container.encode(omlxURL, forKey: .omlxURL)
        try container.encode(omlxModel, forKey: .omlxModel)
        try container.encode(ollamaURL, forKey: .ollamaURL)
        try container.encode(ollamaModel, forKey: .ollamaModel)
        try container.encode(openAICompatibleBaseURL, forKey: .openAICompatibleBaseURL)
        try container.encode(openAICompatibleModel, forKey: .openAICompatibleModel)
        try container.encode(customTSAServers, forKey: .customTSAServers)
        try container.encode(selectedTSAURL, forKey: .selectedTSAURL)
        try container.encode(pdfaMode, forKey: .pdfaMode)
        try container.encode(profiles, forKey: .profiles)
        try container.encodeIfPresent(activeProfileID, forKey: .activeProfileID)
        try container.encode(ezzkICO, forKey: .ezzkICO)
        try container.encode(ezzkUsername, forKey: .ezzkUsername)
        try container.encode(ezzkNotificationEmail, forKey: .ezzkNotificationEmail)
        try container.encode(ezzkEdeskAddress, forKey: .ezzkEdeskAddress)
        try container.encode(ezzkMode, forKey: .ezzkMode)
        try container.encode(ezzkPersonName, forKey: .ezzkPersonName)
        try container.encode(retainRecentDocuments, forKey: .retainRecentDocuments)
        try container.encode(useFoundationModelClassifier, forKey: .useFoundationModelClassifier)
        try container.encode(learnFromReviews, forKey: .learnFromReviews)
        try container.encode(detectorTrainingOffersEnabled, forKey: .detectorTrainingOffersEnabled)
        try container.encode(mobileSigningEnabled, forKey: .mobileSigningEnabled)
        try container.encode(avmBaseURL, forKey: .avmBaseURL)
        try container.encode(agpBaseURL, forKey: .agpBaseURL)
        try container.encode(agpUserID, forKey: .agpUserID)
        try container.encode(webSigningSavesLocally, forKey: .webSigningSavesLocally)
        try container.encode(webSigningOutputPath, forKey: .webSigningOutputPath)
        try container.encode(webSigningRetentionDays, forKey: .webSigningRetentionDays)
        try container.encode(batchASiCPackaging, forKey: .batchASiCPackaging)
    }

    public var availableTSAServers: [TimestampAuthority] {
        TimestampAuthority.resolveSelected(customServers: customTSAServers,
                                           selectedTSAURL: selectedTSAURL)
    }

    public var activeTSA: TimestampAuthority {
        availableTSAServers.first { $0.url == selectedTSAURL }
            ?? availableTSAServers.first
            ?? TimestampAuthority.builtIn[0]
    }

    public static let standard = AppSettings()

    public static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .standard
        }
        return settings
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static let storageKey = "\(ProductIdentity.bundleIdentifier).settings.v1"
}
