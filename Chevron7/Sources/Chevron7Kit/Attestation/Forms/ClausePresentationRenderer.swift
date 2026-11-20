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
    ///
    /// The rest is layout only, never text or order: the form lays out at fixed widths (`.layoutMain`
    /// 900 px, labels with inline widths up to 870 px, value boxes such as `.sirokyTextBox665px`), so
    /// `horizontalPagination = .fit` shrank it to about 0.567 and body text (12 px) printed at 6.8 pt.
    /// Here the page box takes the printable width, no element is wider than its container, and value
    /// boxes shrink to their text, so a value sits beside its label when both fit and below it
    /// otherwise; WebKit then prints at its own minimum shrink (0.8), body text at 9.6 pt.
    public static let printStyle = "<style>@page{size:A4} body{-webkit-print-color-adjust:exact}"
        + " .layoutMain{width:auto !important} .layoutMain *{max-width:100% !important}"
        + " .layoutMain .fieldContent,.layoutMain .fieldContent div{width:auto !important}</style>"

    /// ISO A4 in points.
    static let paperSize = NSSize(width: 595.2756, height: 841.8898)
    static let margin: CGFloat = 36

    /// How long loading the HTML and printing it may each take before the render gives up.
    static let defaultTimeout: Duration = .seconds(60)

    private let xsltproc: URL
    private let loadTimeout: Duration
    private let printTimeout: Duration
    private let stages: ClausePrintStages

    public init(xsltproc: URL = URL(fileURLWithPath: "/usr/bin/xsltproc")) {
        self.init(xsltproc: xsltproc, loadTimeout: Self.defaultTimeout, printTimeout: Self.defaultTimeout,
                  stages: .webKit)
    }

    init(xsltproc: URL = URL(fileURLWithPath: "/usr/bin/xsltproc"),
         loadTimeout: Duration = Self.defaultTimeout, printTimeout: Duration = Self.defaultTimeout,
         stages: ClausePrintStages = .webKit) {
        self.xsltproc = xsltproc
        self.loadTimeout = loadTimeout
        self.printTimeout = printTimeout
        self.stages = stages
    }

    @MainActor
    public func render(clauseXML: Data, form: OfficialForm) async throws -> Data {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("clause-pages-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw ClausePresentationError.transformFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: work) }

        let html = try await Task.detached { [self] in
            try transform(clauseXML: clauseXML, stylesheet: form.presentation, in: work)
        }.value
        let output = work.appendingPathComponent("clause.pdf")
        do {
            try await ClausePagePrinter(loadTimeout: loadTimeout, printTimeout: printTimeout, stages: stages)
                .print(html: Self.injectingPrintStyle(into: html), to: output,
                       ruleStore: work.appendingPathComponent("rules", isDirectory: true))
        } catch {
            // WebKit's and the file system's own errors are English and say nothing to the advocate.
            throw ClausePresentationError.printFailed
        }
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
        let logHandle: FileHandle
        do {
            try clauseXML.write(to: xml)
            try stylesheet.write(to: xslt)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: log)
        } catch {
            throw ClausePresentationError.transformFailed(error.localizedDescription)
        }
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

/// The two steps of printing that wait on WebKit and AppKit; tests replace them with steps that
/// never finish to exercise the timeout.
struct ClausePrintStages: Sendable {
    var load: @MainActor @Sendable (WKWebView, String) -> Void
    var print: @MainActor @Sendable (NSPrintOperation, NSWindow, PrintCompletion) -> Void

    static let webKit = ClausePrintStages(
        load: { webView, html in webView.loadHTMLString(html, baseURL: nil) },
        print: { operation, window, completion in
            // Without panels AppKit finishes the modal operation on a thread of its own.
            operation.runModal(for: window, delegate: completion,
                               didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: nil)
        })
}

/// Loads the HTML into an offscreen `WKWebView` that can reach no URL and prints it to a PDF file.
@MainActor
private final class ClausePagePrinter: NSObject, WKNavigationDelegate {
    private let loadTimeout: Duration
    private let printTimeout: Duration
    private let stages: ClausePrintStages
    private var loaded: OneShot<Void>?

    init(loadTimeout: Duration, printTimeout: Duration, stages: ClausePrintStages) {
        self.loadTimeout = loadTimeout
        self.printTimeout = printTimeout
        self.stages = stages
    }

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
        let held = HeldPrint(webView: webView, window: window)
        // Until the print starts the printer owns the window; from then on the print callback does.
        var handedOver = false
        defer { if !handedOver { held.tearDown() } }

        let load = OneShot<Void>()
        loaded = load
        stages.load(webView, html)
        try await load.value(within: loadTimeout)

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
        completion.hold(held, operation: operation)
        handedOver = true
        stages.print(operation, window, completion)
        guard try await completion.result.value(within: printTimeout) else {
            throw ClausePresentationError.printFailed
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the HTML string itself (about:blank) may load; no link or redirect leaves the page.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(with: .failure(ClausePresentationError.printFailed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(with: .failure(ClausePresentationError.printFailed))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded?.resume(with: .failure(ClausePresentationError.printFailed))
    }
}

/// The offscreen window and web view of one render.
struct HeldPrint: @unchecked Sendable {
    let webView: WKWebView
    let window: NSWindow

    @MainActor
    func tearDown() {
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
    }
}

/// Receives `runModal(for:delegate:didRun:contextInfo:)`'s callback, which AppKit sends from the
/// print operation's own thread when no panel is shown. AppKit does not retain the delegate, and a
/// render that timed out has already returned, so the completion keeps itself, the operation, the
/// web view and the window alive until the callback arrives and only then closes the window.
final class PrintCompletion: NSObject, @unchecked Sendable {
    let result = OneShot<Bool>()
    private let lock = NSLock()
    private var held: HeldPrint?
    private var operation: NSPrintOperation?
    private var keepAlive: PrintCompletion?

    func hold(_ print: HeldPrint, operation: NSPrintOperation) {
        lock.withLock {
            held = print
            self.operation = operation
            keepAlive = self
        }
    }

    /// Whether a print (its operation, web view and window) is still waiting for its callback.
    var holdsPrint: Bool { lock.withLock { held != nil && operation != nil && keepAlive != nil } }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                    contextInfo: UnsafeMutableRawPointer?) {
        result.resume(with: .success(success))
        let released = lock.withLock { () -> (HeldPrint?, NSPrintOperation?, PrintCompletion?) in
            defer { held = nil; self.operation = nil; keepAlive = nil }
            return (held, self.operation, keepAlive)
        }
        guard let print = released.0 else { return }
        let rest = UncheckedSendable((released.1, released.2))
        // The callback runs on the print thread; the window belongs to the main thread.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { print.tearDown() }
            _ = rest
        }
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A value delivered at most once, from any thread, before or after someone waits for it; later
/// deliveries (a callback after the timeout) are ignored.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Value, Error>?
    private var waiter: CheckedContinuation<Value, Error>?

    func resume(with result: Result<Value, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(with: result)
    }

    /// Waits for the value; after `timeout` it fails with `.printFailed` instead.
    func value(within timeout: Duration) async throws -> Value {
        let timer = Task { [self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            resume(with: .failure(ClausePresentationError.printFailed))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<Value, Error>? in
                if outcome == nil { waiter = continuation }
                return outcome
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
