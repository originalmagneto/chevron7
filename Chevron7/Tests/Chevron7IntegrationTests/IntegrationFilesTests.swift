import Foundation
import Darwin
import XCTest
@testable import Chevron7Integration

final class IntegrationFilesTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chevron7-integration-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        root = root.resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSnapshotsUnicodeFilenameAndHashesActualBytes() throws {
        let input = root.appendingPathComponent("Žiadosť.pdf")
        try Data("abc".utf8).write(to: input)
        let scope = try IntegrationFileScope(roots: [root])
        let snapshot = try scope.snapshot(path: input.path, in: root)
        XCTAssertEqual(snapshot.name, "Žiadosť.pdf")
        XCTAssertEqual(snapshot.byteCount, 3)
        XCTAssertEqual(snapshot.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data("changed".utf8).write(to: input)
        XCTAssertEqual(try Data(contentsOf: snapshot.url), Data("abc".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: snapshot.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testEmptyRootsDenyAndPrefixSiblingDoesNotMatch() throws {
        let permitted = root.appendingPathComponent("client")
        let sibling = root.appendingPathComponent("client-other")
        try FileManager.default.createDirectory(at: permitted, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let input = sibling.appendingPathComponent("file.pdf")
        try Data("x".utf8).write(to: input)
        assertCode("ACCESS_DENIED") { _ = try IntegrationFileScope(roots: []).read(path: input.path) }
        assertCode("ACCESS_DENIED") { _ = try IntegrationFileScope(roots: [permitted]).read(path: input.path) }
        XCTAssertEqual(try IntegrationFileScope().read(path: input.path), Data("x".utf8))
    }

    func testSymlinkInputAndEscapedParentAreRefused() throws {
        let permitted = root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at: permitted, withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("outside.pdf")
        try Data("secret".utf8).write(to: outside)
        let link = permitted.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let scope = try IntegrationFileScope(roots: [permitted])
        assertCode("FILE_ACCESS") { _ = try scope.read(path: link.path) }
        let directoryLink = permitted.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        assertCode("ACCESS_DENIED") { _ = try scope.read(path: directoryLink.appendingPathComponent("outside.pdf").path) }
        assertCode("ACCESS_DENIED") { _ = try scope.reserveOutput(path: directoryLink.appendingPathComponent("new.pdf").path) }
    }

    func testSizeLimitAndSpecialFilesAreRejectedBeforeRead() throws {
        let input = root.appendingPathComponent("large.pdf")
        try Data(repeating: 1, count: 1024).write(to: input)
        let scope = try IntegrationFileScope(roots: [root])
        assertCode("FILE_TOO_LARGE") { _ = try scope.read(path: input.path, maxBytes: 10) }
        assertCode("FILE_ACCESS") { _ = try scope.read(path: root.path) }
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        assertCode("FILE_ACCESS") { _ = try scope.read(path: fifo.path) }
    }

    func testOutputPublicationIsExclusiveAndRepeatable() throws {
        let output = root.appendingPathComponent("signed.pdf")
        let reservation = try IntegrationFileScope(roots: [root]).reserveOutput(path: output.path)
        try reservation.write(Data("signed".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let delivered = try reservation.publish()
        XCTAssertEqual(try reservation.publish(), delivered)
        XCTAssertEqual(delivered.byteCount, 6)
        XCTAssertEqual(try Data(contentsOf: output), Data("signed".utf8))
        assertCode("OUTPUT_EXISTS") { _ = try IntegrationFileScope().reserveOutput(path: output.path) }
        reservation.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testConcurrentOutputDoesNotGetReplaced() throws {
        let output = root.appendingPathComponent("signed.pdf")
        let reservation = try IntegrationFileScope().reserveOutput(path: output.path)
        try reservation.write(Data("signature".utf8))
        try Data("someone else's file".utf8).write(to: output)
        assertCode("OUTPUT_EXISTS") { _ = try reservation.publish() }
        reservation.discard()
        XCTAssertEqual(try Data(contentsOf: output), Data("someone else's file".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["signed.pdf"])
    }

    func testReplacedOutputDirectoryDoesNotRedirectDelivery() throws {
        let parent = root.appendingPathComponent("parent")
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let reservation = try IntegrationFileScope(roots: [parent]).reserveOutput(path: parent.appendingPathComponent("signed.pdf").path)
        try reservation.write(Data("signature".utf8))
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        assertCode("OUTPUT_DELIVERY_FAILED") { _ = try reservation.publish() }
        reservation.discard()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
    }

    func testExistingSymlinkAndHardLinkCannotBeOutput() throws {
        let input = root.appendingPathComponent("input.pdf")
        try Data("original".utf8).write(to: input)
        let symbolic = root.appendingPathComponent("symlink.pdf")
        let hard = root.appendingPathComponent("hardlink.pdf")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: input)
        try FileManager.default.linkItem(at: input, to: hard)
        for path in [input.path, symbolic.path, hard.path] {
            assertCode("OUTPUT_EXISTS") { _ = try IntegrationFileScope().reserveOutput(path: path) }
        }
        XCTAssertEqual(try Data(contentsOf: input), Data("original".utf8))
    }

    func testSubstitutedTemporaryFileCannotBePublishedAsSignedBytes() throws {
        let output = root.appendingPathComponent("signed.pdf")
        let reservation = try IntegrationFileScope().reserveOutput(path: output.path)
        try reservation.write(Data("signature".utf8))
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasPrefix(".chevron7-") })
        let temporary = root.appendingPathComponent(name)
        try FileManager.default.removeItem(at: temporary)
        try Data("substitution".utf8).write(to: temporary)
        assertCode("OUTPUT_DELIVERY_FAILED") { _ = try reservation.publish() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        reservation.discard()
    }

    func testRootSymlinkSubstitutionCannotChangeConfiguredAuthority() throws {
        let client = root.appendingPathComponent("client")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let scope = try IntegrationFileScope(roots: [client])
        try FileManager.default.removeItem(at: client)
        try FileManager.default.createSymbolicLink(at: client, withDestinationURL: outside)
        let input = outside.appendingPathComponent("secret.pdf")
        try Data("secret".utf8).write(to: input)
        assertCode("ACCESS_DENIED") { _ = try scope.read(path: client.appendingPathComponent("secret.pdf").path) }
        assertCode("FILE_ACCESS") { _ = try IntegrationFileScope(roots: [client]) }
        // A substituted ancestor must fail as well, even though O_NOFOLLOW only
        // protects the final component passed to open().
        let nested = outside.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        assertCode("ACCESS_DENIED") { _ = try IntegrationFileScope(roots: [client.appendingPathComponent("nested")]) }
    }
}
