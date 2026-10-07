// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit

@MainActor
final class SignatureTreeLoaderTests: XCTestCase {
    private static let structural = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .indeterminate)])
    private static let validated = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .valid)])

    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7\n%%EOF".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLoadShowsStructuralThenValidated() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let loader = SignatureTreeLoader(provider: provider)
        await loader.load(try file())
        XCTAssertEqual(loader.state.phase, .structural)
        await provider.releaseValidation()
        await loader.validationTask?.value
        XCTAssertEqual(loader.state, SignatureTreeState(tree: Self.validated, phase: .validated))
    }

    func testResetDropsALateValidation() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let loader = SignatureTreeLoader(provider: provider)
        await loader.load(try file())
        let task = try XCTUnwrap(loader.validationTask)
        loader.reset()
        XCTAssertTrue(task.isCancelled)
        await provider.releaseValidation()
        await task.value
        XCTAssertEqual(loader.state, SignatureTreeState())
        XCTAssertNil(loader.validationTask)
    }
}
