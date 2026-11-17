// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Foundation
import WebKit

public enum ClausePresentationError: LocalizedError, Equatable, Sendable {
    case transformFailed(String)
    case printFailed

    public var errorDescription: String? {
        switch self {
        case .transformFailed(let detail):
            return "Osvedčovaciu doložku sa nepodarilo vykresliť: \(detail)"
        case .printFailed:
            return "Osvedčovaciu doložku sa nepodarilo vykresliť: tlač do PDF zlyhala."
        }
    }
}

/// Turns the clause XML into readable A4 pages with the form's own HTML presentation
/// (`OfficialForm.presentation`), so the pages always show exactly the XML they are rendered from.
/// The XSLT runs in `xsltproc --nonet`; WebKit prints the HTML offscreen with every URL blocked,
/// because the official presentation carries its fonts and images inline.
public struct ClausePresentationRenderer: Sendable {
    /// A content rule list that blocks every load the page could start.
    public static let blockEverythingRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    /// Print CSS added to the presentation: A4 pages whose margins come from the print info, and
    /// backgrounds printed as the form draws them. No `@page` margin: WebKit lets a CSS `margin:0`
    /// override the print info's 36 pt and then prints up to about 4 pt from the paper edge.
    public static let printStyle = "<style>@page{size:A4} body{-webkit-print-color-adjust:exact}</style>"

    /// ISO A4 in points.
    static let paperSize = NSSize(width: 595.2756, height: 841.8898)
    static let margin: CGFloat = 36

    private let xsltproc: URL

    public init(xsltproc: URL = URL(fileURLWithPath: "/usr/bin/xsltproc")) {
        self.xsltproc = xsltproc
    }

    @MainActor
    public func render(clauseXML: Data, form: OfficialForm) async throws -> Data {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("clause-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let html = try await Task.detached { [self] in
            try transform(clauseXML: clauseXML, stylesheet: form.presentation, in: work)
        }.value
        let output = work.appendingPathComponent("clause.pdf")
        try await ClausePagePrinter().print(html: Self.injectingPrintStyle(into: html), to: output,
                                            ruleStore: work.appendingPathComponent("rules", isDirectory: true))
        guard let pdf = try? Data(contentsOf: output), !pdf.isEmpty else {
            throw ClausePresentationError.printFailed
        }
        return pdf
    }

    /// Runs the form's XSLT over the clause XML; xsltproc's own message on failure.
    func transform(clauseXML: Data, stylesheet: Data, in directory: URL) throws -> String {
        let xml = directory.appendingPathComponent("clause.xml")
        let xslt = directory.appendingPathComponent("form.xslt")
        let html = directory.appendingPathComponent("clause.html")
        let log = directory.appendingPathComponent("xsltproc.log")
        try clauseXML.write(to: xml)
        try stylesheet.write(to: xslt)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = xsltproc
        process.arguments = ["--nonet", "-o", html.path, xslt.path, xml.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            throw ClausePresentationError.transformFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let message = (try? String(contentsOf: log, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: html), !data.isEmpty else {
            throw ClausePresentationError.transformFailed(
                message.isEmpty ? "xsltproc skončil s kódom \(process.terminationStatus)." : message)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func injectingPrintStyle(into html: String) -> String {
        if let head = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: head.lowerBound..<head.lowerBound, with: printStyle)
        }
        return printStyle + html
    }
}

/// Loads the HTML into an offscreen `WKWebView` that can reach no URL and prints it to a PDF file.
@MainActor
private final class ClausePagePrinter: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?

    func print(html: String, to output: URL, ruleStore storeURL: URL) async throws {
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: storeURL),
              let rules = try await store.compileContentRuleList(
                forIdentifier: "block-everything",
                encodedContentRuleList: ClausePresentationRenderer.blockEverythingRules) else {
            throw ClausePresentationError.printFailed
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        let frame = NSRect(origin: .zero, size: ClausePresentationRenderer.paperSize)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.contentView = webView
        defer {
            webView.navigationDelegate = nil
            window.contentView = nil
            window.close()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }

        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: output
        ])
        info.paperSize = ClausePresentationRenderer.paperSize
        info.orientation = .portrait
        info.topMargin = ClausePresentationRenderer.margin
        info.bottomMargin = ClausePresentationRenderer.margin
        info.leftMargin = ClausePresentationRenderer.margin
        info.rightMargin = ClausePresentationRenderer.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        let completion = PrintCompletion()
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            completion.continuation = continuation
            // Without panels AppKit finishes the modal operation on a thread of its own.
            operation.runModal(for: window, delegate: completion,
                               didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: nil)
        }
        guard success else { throw ClausePresentationError.printFailed }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the HTML string itself (about:blank) may load; no link or redirect leaves the page.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: ClausePresentationError.printFailed)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: ClausePresentationError.printFailed)
        loaded = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded?.resume(throwing: ClausePresentationError.printFailed)
        loaded = nil
    }
}

/// Receives `runModal(for:delegate:didRun:contextInfo:)`'s callback, which AppKit sends from the
/// print operation's own thread when no panel is shown.
private final class PrintCompletion: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Bool, Never>?

    var continuation: CheckedContinuation<Bool, Never>? {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                    contextInfo: UnsafeMutableRawPointer?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { pending = nil }
            return pending
        }
        continuation?.resume(returning: success)
    }
}
