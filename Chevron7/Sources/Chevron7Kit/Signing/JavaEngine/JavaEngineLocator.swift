// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Identity

public struct JavaEngineInstallation: Sendable, Equatable {
    public let javaExecutableURL: URL
    public let jarFileURL: URL
    public let helperURL: URL

    public init(javaExecutableURL: URL, jarFileURL: URL, helperURL: URL? = nil) {
        self.javaExecutableURL = javaExecutableURL
        self.jarFileURL = jarFileURL
        let fallbackHelper = URL(fileURLWithPath: javaExecutableURL.path)
            .deletingLastPathComponent() // runtime/bin
            .deletingLastPathComponent() // runtime
            .appendingPathComponent("Helpers")
            .appendingPathComponent("AutogramCLI-arm64")
        self.helperURL = helperURL ?? fallbackHelper
    }
}

public struct JavaEngineLocator: Sendable {
    public static let environmentKey = "CHEVRON7_JAVA_ENGINE_ROOT"
    public static let defaultRoots = [
        ProductIdentity.installedAppURL.appendingPathComponent("Contents").path
    ]

    public let candidateRoots: [String]

    public init(candidateRoots: [String]? = nil) {
        if let candidateRoots {
            self.candidateRoots = candidateRoots
            return
        }
        var roots: [String] = []
        if let override = ProcessInfo.processInfo.environment[Self.environmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            roots.append(override)
        }
        let bundledRoot = Bundle.main.bundleURL.appending(path: "Contents").path
        for root in [bundledRoot] + Self.defaultRoots where !roots.contains(root) {
            roots.append(root)
        }
        self.candidateRoots = roots

    }
    public func locate(fileManager: FileManager = .default) -> JavaEngineInstallation? {
        for root in candidateRoots {
            if let installation = Self.installation(root: root, fileManager: fileManager) {
                return installation
            }
        }
        return nil
    }

    static func installation(root: String, fileManager: FileManager) -> JavaEngineInstallation? {
        guard root.hasPrefix("/") else { return nil }
        let contents = URL(fileURLWithPath: root, isDirectory: true)
        let java = contents.appendingPathComponent("runtime/bin/java")
        let jar = contents.appendingPathComponent("app/autogram.jar")
        guard fileManager.fileExists(atPath: jar.path) else { return nil }
        let helper = contents.appendingPathComponent("Helpers/AutogramCLI-arm64")
        if fileManager.isExecutableFile(atPath: helper.path) {
            return JavaEngineInstallation(javaExecutableURL: java,
                                          jarFileURL: jar,
                                          helperURL: helper)
        }
        guard fileManager.isExecutableFile(atPath: java.path) else { return nil }
        return JavaEngineInstallation(javaExecutableURL: java, jarFileURL: jar)
    }
}
